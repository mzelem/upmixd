import CoreAudio
import Foundation
import UpmixCore

enum RenderHealth: Int32 {
    case unknown = 0
    case ok = 1
    case noStereoInput = 2
    case noSixChannelOutput = 3

    var description: String {
        switch self {
        case .unknown: return "IOProc has not run"
        case .ok: return "ok"
        case .noStereoInput: return "no 2ch input buffer in aggregate"
        case .noSixChannelOutput: return "no 6ch output buffer in aggregate"
        }
    }
}

/// Owns the aggregate device and its IOProc; bridges interleaved HAL buffers
/// to the deinterleaved Upmixer.
final class Engine {
    private static let maxFrames = 16384

    // Written from the render thread, read from the main thread. A plain
    // aligned 32-bit store/load; the race is benign (monitoring only).
    private let healthStorage: UnsafeMutablePointer<Int32>

    var health: RenderHealth {
        RenderHealth(rawValue: healthStorage.pointee) ?? .unknown
    }

    /// Re-arm the probe after reading: the render thread rewrites it every
    /// callback, so a probe still `.unknown` at the next read means the
    /// IOProc has stopped running entirely.
    func resetHealthProbe() {
        healthStorage.pointee = RenderHealth.unknown.rawValue
    }

    private let upmixer: Upmixer
    private var aggregate: AudioDeviceID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var running = false

    // Preallocated deinterleaved scratch: [L, R, FL, FR, C, LFE, RL, RR].
    private let scratch: [UnsafeMutablePointer<Float>]
    private let channelOutputs: [UnsafeMutablePointer<Float>]

    init(config: UpmixConfig) {
        upmixer = Upmixer(config: config)
        scratch = (0..<8).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: Engine.maxFrames)
            p.initialize(repeating: 0, count: Engine.maxFrames)
            return p
        }
        channelOutputs = Array(scratch[2...7])
        healthStorage = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        healthStorage.initialize(to: RenderHealth.unknown.rawValue)
    }

    deinit {
        stop()
        scratch.forEach { $0.deallocate() }
        healthStorage.deallocate()
    }

    func start(captureUID: String, playbackUID: String) throws {
        aggregate = try createAggregate(captureUID: captureUID, playbackUID: playbackUID)

        var frameSizeAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var frames = UInt32(512)
        _ = AudioObjectSetPropertyData(
            aggregate, &frameSizeAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)

        let context = Unmanaged.passUnretained(self).toOpaque()
        do {
            try check(
                AudioDeviceCreateIOProcID(aggregate, engineIOProc, context, &ioProcID),
                "create IOProc")
            try check(AudioDeviceStart(aggregate, ioProcID), "start audio device")
        } catch {
            if let procID = ioProcID {
                AudioDeviceDestroyIOProcID(aggregate, procID)
                ioProcID = nil
            }
            destroyAggregate(aggregate)
            throw error
        }
        running = true
    }

    func stop() {
        guard running, let procID = ioProcID else { return }
        AudioDeviceStop(aggregate, procID)
        AudioDeviceDestroyIOProcID(aggregate, procID)
        destroyAggregate(aggregate)
        ioProcID = nil
        running = false
    }

    /// Real-time render path. No allocation, no locks, no ObjC.
    func render(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>
    ) {
        // Zero every output buffer first: the BlackHole output stream must
        // stay silent (anything written there loops back into our input),
        // and the 6ch buffer gets fully overwritten below anyway.
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        for buffer in outputs {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }

        // First 2-channel input stream is BlackHole (subdevice list order puts
        // the capture device first; the adapter's mic stream comes after).
        let inputs = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: input))
        guard let inBuffer = inputs.first(where: { $0.mNumberChannels == 2 }),
              let inData = inBuffer.mData?.assumingMemoryBound(to: Float.self)
        else {
            healthStorage.pointee = RenderHealth.noStereoInput.rawValue
            return
        }
        guard let outBuffer = outputs.first(where: { $0.mNumberChannels == 6 }),
              let outData = outBuffer.mData?.assumingMemoryBound(to: Float.self)
        else {
            healthStorage.pointee = RenderHealth.noSixChannelOutput.rawValue
            return
        }
        healthStorage.pointee = RenderHealth.ok.rawValue

        let frames = min(
            Int(inBuffer.mDataByteSize) / (2 * MemoryLayout<Float>.size),
            Int(outBuffer.mDataByteSize) / (6 * MemoryLayout<Float>.size),
            Engine.maxFrames)
        guard frames > 0 else { return }

        let left = scratch[0]
        let right = scratch[1]
        for i in 0..<frames {
            left[i] = inData[2 * i]
            right[i] = inData[2 * i + 1]
        }

        upmixer.process(left: left, right: right, frames: frames, outputs: channelOutputs)

        for i in 0..<frames {
            for ch in 0..<6 {
                outData[6 * i + ch] = channelOutputs[ch][i]
            }
        }
    }
}

private func engineIOProc(
    _ device: AudioObjectID,
    _ now: UnsafePointer<AudioTimeStamp>,
    _ inputData: UnsafePointer<AudioBufferList>,
    _ inputTime: UnsafePointer<AudioTimeStamp>,
    _ outputData: UnsafeMutablePointer<AudioBufferList>,
    _ outputTime: UnsafePointer<AudioTimeStamp>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    let engine = Unmanaged<Engine>.fromOpaque(clientData).takeUnretainedValue()
    engine.render(input: inputData, output: outputData)
    return noErr
}
