import CoreAudio
import Foundation

enum CoreAudioError: Error, CustomStringConvertible {
    case osStatus(String, OSStatus)
    case notFound(String)

    var description: String {
        switch self {
        case let .osStatus(what, status): return "\(what) failed (OSStatus \(status))"
        case let .notFound(what): return "\(what) not found"
        }
    }
}

func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw CoreAudioError.osStatus(what, status) }
}

private func address(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func allDeviceIDs() throws -> [AudioDeviceID] {
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

func stringProperty(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    var str: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let status = withUnsafeMutablePointer(to: &str) {
        AudioObjectGetPropertyData(device, &addr, 0, nil, &size, $0)
    }
    return status == noErr ? (str as String) : nil
}

func deviceUID(_ device: AudioDeviceID) -> String? {
    stringProperty(device, kAudioDevicePropertyDeviceUID)
}

func deviceName(_ device: AudioDeviceID) -> String? {
    stringProperty(device, kAudioObjectPropertyName)
}

func findDevice(uid: String) throws -> AudioDeviceID {
    for device in try allDeviceIDs() where deviceUID(device) == uid {
        return device
    }
    throw CoreAudioError.notFound("audio device with UID \"\(uid)\"")
}

/// Find a device by name that actually has output streams (devices like the
/// CM6206 enumerate their output and input sides under the same name).
func findPlaybackDevice(name: String) throws -> AudioDeviceID {
    for device in try allDeviceIDs() where deviceName(device) == name {
        if let streams = try? outputStreams(device), !streams.isEmpty {
            return device
        }
    }
    throw CoreAudioError.notFound("playback device named \"\(name)\"")
}

func outputStreams(_ device: AudioDeviceID) throws -> [AudioStreamID] {
    var addr = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
    var size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size), "get output stream list size")
    var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
    try check(AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &streams), "get output stream list")
    return streams
}

func setNominalSampleRate(_ device: AudioDeviceID, _ rate: Double) throws {
    var addr = address(kAudioDevicePropertyNominalSampleRate)
    var value = rate
    try check(
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Double>.size), &value),
        "set nominal sample rate \(rate)")
}

/// Ensure the device's first output stream runs the given physical format,
/// picking it from the stream's advertised formats.
func ensurePhysicalFormat(
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

func currentOutputChannels(_ device: AudioDeviceID) -> UInt32? {
    guard let stream = try? outputStreams(device).first else { return nil }
    var addr = address(kAudioStreamPropertyPhysicalFormat)
    var format = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    guard AudioObjectGetPropertyData(stream, &addr, 0, nil, &size, &format) == noErr else {
        return nil
    }
    return format.mChannelsPerFrame
}

func isDeviceAlive(_ device: AudioDeviceID) -> Bool {
    var addr = address(kAudioDevicePropertyDeviceIsAlive)
    var alive: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &alive) == noErr else {
        return false
    }
    return alive != 0
}

func defaultOutputDevice() -> AudioDeviceID? {
    var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr
    else { return nil }
    return device
}

func setDefaultOutputDevice(_ device: AudioDeviceID) throws {
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
func createAggregate(captureUID: String, playbackUID: String) throws -> AudioDeviceID {
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

func destroyAggregate(_ device: AudioDeviceID) {
    _ = AudioHardwareDestroyAggregateDevice(device)
}
