import CoreAudio
import Foundation
import UpmixCore

public enum CoreAudioError: Error, CustomStringConvertible {
    case osStatus(String, OSStatus)
    case notFound(String)

    public var description: String {
        switch self {
        case let .osStatus(what, status):
            return "\(what) failed (OSStatus \(status)\(fourCC(status)))"
        case let .notFound(what): return "\(what) not found"
        }
    }

    /// CoreAudio statuses are usually four printable ASCII bytes ('nope',
    /// 'what' …); rendering them makes user bug reports actionable.
    private func fourCC(_ status: OSStatus) -> String {
        let bytes = withUnsafeBytes(of: status.bigEndian) { Array($0) }
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return "" }
        return " '\(String(bytes: bytes, encoding: .ascii)!)'"
    }
}

public func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw CoreAudioError.osStatus(what, status) }
}

private func address(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

public func allDeviceIDs() throws -> [AudioDeviceID] {
    var addr = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    try check(
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size),
        "get device list size")
    var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    try check(
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices),
        "get device list")
    return devices
}

public func stringProperty(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    var str: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let status = withUnsafeMutablePointer(to: &str) {
        AudioObjectGetPropertyData(device, &addr, 0, nil, &size, $0)
    }
    return status == noErr ? (str as String) : nil
}

public func deviceUID(_ device: AudioDeviceID) -> String? {
    stringProperty(device, kAudioDevicePropertyDeviceUID)
}

/// Strip control characters before logging externally-sourced strings (USB
/// device names come from the device's own descriptor): a hostile name must
/// not be able to forge log lines or emit terminal escapes.
public func logSafe(_ string: String) -> String {
    String(String.UnicodeScalarView(
        string.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
}

public func deviceName(_ device: AudioDeviceID) -> String? {
    stringProperty(device, kAudioObjectPropertyName)
}

public func findDevice(uid: String) throws -> AudioDeviceID {
    for device in try allDeviceIDs() where deviceUID(device) == uid {
        return device
    }
    throw CoreAudioError.notFound("audio device with UID \"\(uid)\"")
}

public func outputStreams(_ device: AudioDeviceID) throws -> [AudioStreamID] {
    var addr = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
    var size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size), "get output stream list size")
    var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
    try check(AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &streams), "get output stream list")
    return streams
}

public func setNominalSampleRate(_ device: AudioDeviceID, _ rate: Double) throws {
    var addr = address(kAudioDevicePropertyNominalSampleRate)
    var value = rate
    try check(
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Double>.size), &value),
        "set nominal sample rate \(rate)")
}

/// Ensure the device's first output stream runs the given physical format,
/// picking it from the stream's advertised formats.
public func ensurePhysicalFormat(
    device: AudioDeviceID, channels: UInt32, bits: UInt32, sampleRate: Double
) throws {
    guard let stream = try outputStreams(device).first else {
        throw CoreAudioError.notFound("output stream on device \(device)")
    }

    var formatAddr = address(kAudioStreamPropertyPhysicalFormat)
    var current = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    try check(
        AudioObjectGetPropertyData(stream, &formatAddr, 0, nil, &size, &current),
        "get current physical format")
    if current.mChannelsPerFrame == channels && current.mSampleRate == sampleRate
        && current.mBitsPerChannel == bits {
        return
    }

    var availAddr = address(kAudioStreamPropertyAvailablePhysicalFormats)
    var availSize: UInt32 = 0
    try check(
        AudioObjectGetPropertyDataSize(stream, &availAddr, 0, nil, &availSize),
        "get available formats size")
    var formats = [AudioStreamRangedDescription](
        repeating: AudioStreamRangedDescription(),
        count: Int(availSize) / MemoryLayout<AudioStreamRangedDescription>.size)
    try check(
        AudioObjectGetPropertyData(stream, &availAddr, 0, nil, &availSize, &formats),
        "get available formats")

    guard var target = formats.first(where: {
        $0.mFormat.mFormatID == kAudioFormatLinearPCM
            && $0.mFormat.mChannelsPerFrame == channels && $0.mFormat.mBitsPerChannel == bits
            && $0.mFormat.mSampleRate == sampleRate
    })?.mFormat else {
        throw CoreAudioError.notFound("\(channels)ch/\(bits)bit/\(Int(sampleRate))Hz physical format")
    }
    try check(
        AudioObjectSetPropertyData(
            stream, &formatAddr, 0, nil,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &target),
        "set physical format")
}

public func currentOutputChannels(_ device: AudioDeviceID) -> UInt32? {
    guard let stream = try? outputStreams(device).first else { return nil }
    var addr = address(kAudioStreamPropertyPhysicalFormat)
    var format = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    guard AudioObjectGetPropertyData(stream, &addr, 0, nil, &size, &format) == noErr else {
        return nil
    }
    return format.mChannelsPerFrame
}

public func isDeviceAlive(_ device: AudioDeviceID) -> Bool {
    var addr = address(kAudioDevicePropertyDeviceIsAlive)
    var alive: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &alive) == noErr else {
        return false
    }
    return alive != 0
}

public func transportType(_ device: AudioDeviceID) -> UInt32? {
    var addr = address(kAudioDevicePropertyTransportType)
    var transport: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &transport) == noErr else {
        return nil
    }
    return transport
}

/// Built-in output found by transport type, not by UID: the speaker UID
/// differs across Mac generations ("BuiltInSpeakerDevice" vs AppleHDA forms).
public func findBuiltInOutputDevice() -> AudioDeviceID? {
    guard let devices = try? allDeviceIDs() else { return nil }
    for device in devices {
        guard transportType(device) == kAudioDeviceTransportTypeBuiltIn,
              let streams = try? outputStreams(device), !streams.isEmpty
        else { continue }
        return device
    }
    return nil
}

/// Somewhere audible to point the default output when we let go of it:
/// built-in speakers if the Mac has them, otherwise the first real
/// (non-virtual) output device — covers Mac minis/Studios on HDMI or
/// DisplayPort monitors. Virtual devices are skipped so the fallback can
/// never land on another loopback and stay silent.
public func findFallbackOutputDevice(excluding: AudioDeviceID) -> AudioDeviceID? {
    if let builtIn = findBuiltInOutputDevice() { return builtIn }
    guard let devices = try? allDeviceIDs() else { return nil }
    for device in devices where device != excluding {
        guard transportType(device) != kAudioDeviceTransportTypeVirtual,
              let streams = try? outputStreams(device), !streams.isEmpty
        else { continue }
        return device
    }
    return nil
}

public func defaultOutputDevice() -> AudioDeviceID? {
    var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr
    else { return nil }
    return device
}

public func setDefaultOutputDevice(_ device: AudioDeviceID) throws {
    var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
    var value = device
    try check(
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &value),
        "set default output device")
}

/// Create a private (invisible in UI) aggregate of the capture and playback
/// devices. The playback device is the clock master; the capture side gets
/// drift compensation.
public func createAggregate(captureUID: String, playbackUID: String) throws -> AudioDeviceID {
    let description: [String: Any] = [
        kAudioAggregateDeviceUIDKey: "com.utw.upmixd.aggregate",
        kAudioAggregateDeviceNameKey: "upmixd aggregate",
        kAudioAggregateDeviceIsPrivateKey: 1,
        kAudioAggregateDeviceMainSubDeviceKey: playbackUID,
        kAudioAggregateDeviceSubDeviceListKey: [
            [
                kAudioSubDeviceUIDKey: captureUID,
                kAudioSubDeviceDriftCompensationKey: 1,
            ],
            [
                kAudioSubDeviceUIDKey: playbackUID,
            ],
        ],
    ]
    var aggregate = AudioDeviceID(0)
    try check(
        AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate),
        "create aggregate device")
    return aggregate
}

public func destroyAggregate(_ device: AudioDeviceID) {
    _ = AudioHardwareDestroyAggregateDevice(device)
}

// MARK: - Candidate enumeration for the selection policy

/// Upper bound on a device's output channel capability: the sum over its
/// output streams of each stream's widest available physical format. Uses
/// capability, not the currently-selected format — a surround adapter parked
/// on its stereo alt setting still ranks as surround.
public func maxOutputChannels(_ device: AudioDeviceID) -> Int {
    guard let streams = try? outputStreams(device) else { return 0 }
    var total = 0
    for stream in streams {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyAvailablePhysicalFormats,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(stream, &addr, 0, nil, &size) == noErr else { continue }
        var formats = [AudioStreamRangedDescription](
            repeating: AudioStreamRangedDescription(),
            count: Int(size) / MemoryLayout<AudioStreamRangedDescription>.size)
        guard AudioObjectGetPropertyData(stream, &addr, 0, nil, &size, &formats) == noErr else { continue }
        total += Int(formats.map { $0.mFormat.mChannelsPerFrame }.max() ?? 0)
    }
    return total
}

/// Snapshot of every output-capable device as policy candidates. Virtual
/// devices and the capture are included WITH their flags set — filtering is
/// the policy's job, and the panel wants the full picture too.
public func listOutputCandidates(captureUID: String) -> [OutputCandidate] {
    guard let devices = try? allDeviceIDs() else { return [] }
    let currentDefault = defaultOutputDevice()
    var candidates: [OutputCandidate] = []
    for device in devices {
        guard let streams = try? outputStreams(device), !streams.isEmpty,
              let uid = deviceUID(device)
        else { continue }
        let transport = transportType(device)
        candidates.append(OutputCandidate(
            uid: uid,
            name: deviceName(device) ?? uid,
            maxOutputChannels: maxOutputChannels(device),
            isCurrentDefault: device == currentDefault,
            isVirtual: transport == kAudioDeviceTransportTypeVirtual
                || transport == kAudioDeviceTransportTypeAggregate))
    }
    return candidates
}

public func deviceNominalSampleRate(_ device: AudioDeviceID) -> Double? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var rate = 0.0
    var size = UInt32(MemoryLayout<Double>.size)
    guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &rate) == noErr, rate > 0
    else { return nil }
    return rate
}
