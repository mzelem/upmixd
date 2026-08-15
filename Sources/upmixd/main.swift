import CoreAudio
import Foundation
import UpmixCore

setvbuf(stdout, nil, _IOLBF, 0) // line-buffer logs under launchd

let defaultCaptureUID = "BlackHole2ch_UID"
let defaultPlaybackName = "USB Sound Device"

func usage() -> Never {
    print("""
        usage: upmixd [options]

        Reads system audio from a 2ch virtual device (BlackHole) and plays it
        upmixed to 5.1 on a multichannel output device.

        options:
          --capture-uid <uid>    capture device UID (default: \(defaultCaptureUID))
          --playback-uid <uid>   playback device UID (default: find by name)
          --playback-name <name> playback device name (default: \(defaultPlaybackName))
          --set-default          make the capture device the system default output
          --list                 list audio devices and exit
        """)
    exit(64)
}

var captureUID = defaultCaptureUID
var playbackUID: String?
var playbackName = defaultPlaybackName
var setDefault = false

var args = ArraySlice(CommandLine.arguments.dropFirst())
while let arg = args.popFirst() {
    switch arg {
    case "--capture-uid": captureUID = args.popFirst() ?? { usage() }()
    case "--playback-uid": playbackUID = args.popFirst() ?? { usage() }()
    case "--playback-name": playbackName = args.popFirst() ?? { usage() }()
    case "--set-default": setDefault = true
    case "--list":
        for device in (try? allDeviceIDs()) ?? [] {
            print("\(device)\t\(deviceName(device) ?? "?")\t\(deviceUID(device) ?? "?")")
        }
        exit(0)
    default: usage()
    }
}

do {
    let capture = try findDevice(uid: captureUID)
    let playback = try playbackUID.map { try findDevice(uid: $0) }
        ?? findPlaybackDevice(name: playbackName)
    guard let resolvedPlaybackUID = deviceUID(playback) else {
        throw CoreAudioError.notFound("UID for playback device")
    }

    let sampleRate = 48_000.0
    try ensurePhysicalFormat(device: playback, channels: 6, bits: 16, sampleRate: sampleRate)
    try setNominalSampleRate(capture, sampleRate)
    try setNominalSampleRate(playback, sampleRate)

    // The format switch is an asynchronous USB alt-setting change; give it a
    // moment to settle before building the aggregate on top of it.
    let formatDeadline = Date(timeIntervalSinceNow: 2)
    while currentOutputChannels(playback) != 6 {
        guard Date() < formatDeadline else {
            throw CoreAudioError.notFound("6ch format on playback device (did not settle)")
        }
        usleep(100_000)
    }

    let engine = Engine(config: UpmixConfig(sampleRate: sampleRate))
    try engine.start(captureUID: captureUID, playbackUID: resolvedPlaybackUID)
    print("upmixd: \(deviceName(capture) ?? captureUID) → \(deviceName(playback) ?? "?") (5.1) @ \(Int(sampleRate))Hz")

    // Exit (and let launchd restart us) if either device goes away. Installed
    // before --set-default so no throwing call can strand the default output
    // on BlackHole without the revert logic below in place.
    var aliveAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsAlive,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    for (device, role) in [(playback, "playback"), (capture, "capture")] {
        try check(
            AudioObjectAddPropertyListenerBlock(device, &aliveAddr, DispatchQueue.main) { _, _ in
                guard !isDeviceAlive(device) else { return }
                print("upmixd: \(role) device disappeared, exiting")
                engine.stop()
                exit(2)
            },
            "install \(role) device-alive listener")
    }

    if setDefault {
        try setDefaultOutputDevice(capture)
        print("upmixd: default output set to \(deviceName(capture) ?? captureUID)")
    }

    // Every deliberate exit goes through here so the system default output is
    // never left pointing at a consumer-less BlackHole.
    let shutdown: (Int32) -> Never = { code in
        engine.stop()
        if setDefault, defaultOutputDevice() == capture, isDeviceAlive(playback) {
            try? setDefaultOutputDevice(playback) // stereo on the fronts beats silence
        }
        exit(code)
    }

    // If the pipeline is ever unhealthy (e.g. something flips the adapter
    // back to 2ch and the aggregate republishes its buffers), log and exit so
    // launchd can retry — silence must never look like success. The probe is
    // re-armed after each read so a stopped IOProc also reads as unhealthy.
    let healthTimer = DispatchSource.makeTimerSource(queue: .main)
    healthTimer.schedule(deadline: .now() + 3, repeating: 3)
    healthTimer.setEventHandler {
        let health = engine.health
        guard health == .ok else {
            print("upmixd: pipeline unhealthy (\(health.description)), exiting")
            shutdown(3)
        }
        engine.resetHealthProbe()
    }
    healthTimer.resume()

    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    for sig in [SIGINT, SIGTERM] {
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler { shutdown(0) }
        source.resume()
        _ = Unmanaged.passRetained(source) // keep alive for process lifetime
    }

    RunLoop.main.run()
} catch {
    FileHandle.standardError.write("upmixd: \(error)\n".data(using: .utf8)!)
    exit(1)
}
