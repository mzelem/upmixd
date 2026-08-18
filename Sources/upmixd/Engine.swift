import CoreAudio
import Foundation
import UpmixCore
import UpmixDevices

enum RenderHealth: Int32 {
    case unknown = 0
    case ok = 1
    case noStereoInput = 2
    case noMatchingOutput = 3

    var description: String {
        switch self {
        case .unknown: return "IOProc has not run"
        case .ok: return "ok"
        case .noStereoInput: return "no 2ch input buffer in aggregate"
        case .noMatchingOutput: return "no matching output buffer in aggregate"
        }
    }
}

/// Owns the aggregate device and its IOProc; bridges interleaved HAL buffers
/// to the deinterleaved EQ + Upmixer chain.
final class Engine {
    private static let maxFrames = 16384

    // Written from the render thread, read from the main thread. A plain
    // aligned 32-bit store/load; the race is benign (monitoring only).
    private let healthStorage: UnsafeMutablePointer<Int32>

    // Settings handoff: main thread writes under the lock; the render thread
    // only ever try-locks (never blocks) and applies any pending snapshot.
    private let settingsLock: UnsafeMutablePointer<os_unfair_lock>
    private var pendingSettings: DaemonSettings?

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
    private let equalizer: Equalizer
    /// 6 = upmix to 5.1; 2 = EQ-only stereo passthrough.
    private let outputChannels: Int
    /// How many output buffers at the head of the ABL belong to the capture
    /// device's own loopback streams (aggregate buffers follow sub-device
    /// order, capture first). Those are zeroed and skipped; matching a plain
    /// 2ch target by channel count alone would otherwise find the loopback.
    private let captureOutputStreams: Int
    private var aggregate: AudioDeviceID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var running = false

    // Preallocated deinterleaved scratch: [L, R, FL, FR, C, LFE, RL, RR].
    private let scratch: [UnsafeMutablePointer<Float>]
    private let channelOutputs: [UnsafeMutablePointer<Float>]

    private let sampleRate: Double

    init(
        settings: DaemonSettings, sampleRate: Double,
        outputChannels: Int, captureOutputStreams: Int
    ) {
        self.sampleRate = sampleRate
        self.outputChannels = outputChannels
        self.captureOutputStreams = captureOutputStreams
        // Fallbacks below are unreachable while config validation and the
        // pipeline share DaemonSettings.nominalSampleRate; the logs are the
        // tripwire in case that invariant ever breaks.
        var upmixConfig = settings.upmix
        upmixConfig.sampleRate = sampleRate
        if let valid = upmixConfig.validated() {
            upmixer = Upmixer(config: valid)
        } else {
            print("upmixd: warning: upmix settings invalid at \(Int(sampleRate))Hz; using defaults")
            upmixer = Upmixer(config: UpmixConfig(sampleRate: sampleRate))
        }
        if let eq = Equalizer(
            bands: settings.eqBands, sampleRate: sampleRate, preampDb: settings.eqPreampDb) {
            equalizer = eq
        } else {
            print("upmixd: warning: EQ settings invalid at \(Int(sampleRate))Hz; EQ disabled")
            equalizer = Equalizer(bands: [], sampleRate: sampleRate)!
        }
        scratch = (0..<8).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: Engine.maxFrames)
            p.initialize(repeating: 0, count: Engine.maxFrames)
            return p
        }
        channelOutputs = Array(scratch[2...7])
        healthStorage = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        healthStorage.initialize(to: RenderHealth.unknown.rawValue)
        settingsLock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        settingsLock.initialize(to: os_unfair_lock())
    }

    deinit {
        stop()
        scratch.forEach { $0.deallocate() }
        healthStorage.deallocate()
        settingsLock.deallocate()
    }

    /// Hand new settings to the render thread; applied at the start of the
    /// next IO cycle. Safe to call any time from the main thread.
    ///
    /// The auto preamp is resolved HERE, on the main thread: the cascade
    /// measurement allocates, so the render thread must only ever see an
    /// explicit preamp (whose apply path is allocation-free).
    func submit(_ settings: DaemonSettings) {
        var resolved = settings
        let preamp = settings.eqPreampDb
            ?? -Equalizer.cascadeMaxBoostDb(bands: settings.eqBands, sampleRate: sampleRate)
        resolved.eqPreampDb = max(-60, min(0, preamp))
        os_unfair_lock_lock(settingsLock)
        pendingSettings = resolved
        os_unfair_lock_unlock(settingsLock)
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

    /// Real-time render path. No allocation, no blocking (the settings lock
    /// is try-only here), no ObjC.
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
        // Skip the capture device's own loopback buffers at the head of the
        // ABL, then match the playback buffer by channel count. In stereo
        // mode both sides are 2ch, so the skip is what disambiguates.
        var outBufferFound: AudioBuffer?
        for (index, buffer) in outputs.enumerated()
        where index >= captureOutputStreams && buffer.mNumberChannels == UInt32(outputChannels) {
            outBufferFound = buffer
            break
        }
        guard let outBuffer = outBufferFound,
              let outData = outBuffer.mData?.assumingMemoryBound(to: Float.self)
        else {
            healthStorage.pointee = RenderHealth.noMatchingOutput.rawValue
            return
        }
        healthStorage.pointee = RenderHealth.ok.rawValue

        let frames = min(
            Int(inBuffer.mDataByteSize) / (2 * MemoryLayout<Float>.size),
            Int(outBuffer.mDataByteSize) / (outputChannels * MemoryLayout<Float>.size),
            Engine.maxFrames)
        guard frames > 0 else { return }

        // Apply any settings the main thread handed over. If the lock is
        // momentarily held by a submit, we simply pick the change up next
        // cycle — never block the render thread.
        if os_unfair_lock_trylock(settingsLock) {
            if let settings = pendingSettings {
                pendingSettings = nil
                _ = upmixer.apply(settings.upmix)
                _ = equalizer.apply(bands: settings.eqBands, preampDb: settings.eqPreampDb)
            }
            os_unfair_lock_unlock(settingsLock)
        }

        let left = scratch[0]
        let right = scratch[1]
        for i in 0..<frames {
            left[i] = inData[2 * i]
            right[i] = inData[2 * i + 1]
        }

        equalizer.process(left: left, right: right, frames: frames)

        if outputChannels == 6 {
            upmixer.process(left: left, right: right, frames: frames, outputs: channelOutputs)
            for i in 0..<frames {
                for ch in 0..<6 {
                    outData[6 * i + ch] = channelOutputs[ch][i]
                }
            }
        } else {
            // EQ-only stereo passthrough.
            for i in 0..<frames {
                outData[2 * i] = left[i]
                outData[2 * i + 1] = right[i]
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
