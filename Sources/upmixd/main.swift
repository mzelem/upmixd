import CoreAudio
import Foundation
import UpmixCore

setvbuf(stdout, nil, _IOLBF, 0) // line-buffer logs under launchd

let defaultCaptureUID = "BlackHole2ch_UID"
let defaultPlaybackName = "USB Sound Device"
let sampleRate = 48_000.0

func usage() -> Never {
    print("""
        usage: upmixd [options]

        Reads system audio from a 2ch virtual device (BlackHole) and plays it
        upmixed to 5.1 on a multichannel output device. Stays resident: when
        the playback device disappears it falls the default output back to the
        built-in speakers and reattaches the moment the device returns.

        options:
          --capture-uid <uid>    capture device UID (default: \(defaultCaptureUID))
          --playback-uid <uid>   playback device UID (default: find by name)
          --playback-name <name> playback device name (default: \(defaultPlaybackName))
          --set-default          manage the system default output: point it at
                                 the capture device while upmixing, restore it
                                 on shutdown/disconnect
          --rear-gain <0..1>     rear speaker level (default \(UpmixConfig().rearGain))
          --rear-delay-ms <1..100> rear delay; longer = more spacious (default \(Int(UpmixConfig().rearDelayMs)))
          --center-gain <0..0.5> center level applied to L+R (default \(UpmixConfig().centerGain))
          --lfe-gain <0..0.45>   subwoofer level applied to L+R (default \(UpmixConfig().lfeGain))
          --config <path>        settings file, reloaded live on change
                                 (default: ~/.config/upmixd.conf; created with
                                 current settings if missing). File values
                                 override flag values.
          --list                 list audio devices and exit

        Gain upper bounds are the no-clipping limits for full-scale input.
        """)
    exit(64)
}

func parseNumber(_ raw: String?, flag: String, min: Double, max: Double) -> Double {
    guard let raw, let value = Double(raw), value >= min, value <= max else {
        FileHandle.standardError.write(
            "upmixd: \(flag) requires a number in [\(min), \(max)]\n".data(using: .utf8)!)
        exit(64)
    }
    return value
}

/// Owns the daemon lifecycle: waits for the playback device, runs the engine
/// while it exists, tears down and falls back when it goes away. All state is
/// confined to the main queue.
final class Supervisor {
    private let captureUID: String
    private let playbackUID: String?
    private let playbackName: String
    private let manageDefault: Bool
    private let configPath: String
    /// Settings derived from CLI flags; the config file is parsed on top of
    /// these, so the file wins where it speaks and flags fill the gaps.
    private let seedSettings: DaemonSettings
    private var currentSettings: DaemonSettings
    private var configTimer: DispatchSourceTimer?
    private var configMissingLogged = false
    private var lastConfigMtime: Date?

    private var capture: AudioDeviceID = 0
    private var playback: AudioDeviceID = 0
    private var activePlaybackUID: String?
    private var playbackAliveBlock: AudioObjectPropertyListenerBlock?
    private var engine: Engine?
    private var healthTimer: DispatchSourceTimer?
    private var pendingActivation: DispatchWorkItem?
    private var pendingDeadline: DispatchTime = .distantFuture
    private var waitingLogged = false

    init(
        captureUID: String, playbackUID: String?, playbackName: String,
        manageDefault: Bool, configTemplate: UpmixConfig, configPath: String
    ) {
        self.captureUID = captureUID
        self.playbackUID = playbackUID
        self.playbackName = playbackName
        self.manageDefault = manageDefault
        self.configPath = configPath
        var seed = DaemonSettings()
        seed.upmix = configTemplate
        seedSettings = seed
        currentSettings = seed
    }

    func run() throws {
        setupConfig()
        capture = try findDevice(uid: captureUID)

        // Capture is a virtual driver device; it only disappears if BlackHole
        // is uninstalled. Exit and let launchd sort it out.
        var aliveAddr = aliveAddress()
        try check(
            AudioObjectAddPropertyListenerBlock(capture, &aliveAddr, .main) { [weak self] _, _ in
                guard let self, !isDeviceAlive(self.capture) else { return }
                print("upmixd: capture device disappeared, exiting")
                self.teardownEngine()
                exit(2)
            },
            "install capture device-alive listener")

        // Fires on any device arrival/removal — this is what makes re-dock
        // reattachment near-instant instead of a polling loop.
        var listAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        try check(
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &listAddr, .main
            ) { [weak self] _, _ in
                // Small delay so the device finishes publishing its streams.
                self?.scheduleActivation(after: 1.0)
            },
            "install device-list listener")

        activate()
    }

    func shutdown(_ code: Int32) -> Never {
        // Validate the playback id by UID before trusting it: CoreAudio can
        // reuse AudioDeviceIDs after a replug.
        let playbackStillOurs = activePlaybackUID != nil
            && deviceUID(playback) == activePlaybackUID && isDeviceAlive(playback)
        teardownEngine()
        if manageDefault, defaultOutputDevice() == capture {
            if playbackStillOurs {
                try? setDefaultOutputDevice(playback) // stereo on the fronts beats silence
            } else if let builtIn = findBuiltInOutputDevice() {
                try? setDefaultOutputDevice(builtIn)
            }
        }
        exit(code)
    }

    // MARK: - Config file

    private func setupConfig() {
        if let loaded = loadConfigFromDisk() {
            currentSettings = loaded
        } else {
            writeDefaultConfig()
        }
        lastConfigMtime = configMtime()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.pollConfig() }
        timer.resume()
        configTimer = timer
    }

    private func configMtime() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: configPath))?[.modificationDate] as? Date
    }

    private func loadConfigFromDisk() -> DaemonSettings? {
        guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return nil
        }
        let result = DaemonSettings.parse(text, defaults: seedSettings)
        for warning in result.warnings {
            print("upmixd: config: \(warning)")
        }
        return result.settings
    }

    private func writeDefaultConfig() {
        let directory = (configPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true)
            try currentSettings.render().write(toFile: configPath, atomically: true, encoding: .utf8)
            print("upmixd: wrote default config to \(configPath)")
        } catch {
            print("upmixd: warning: could not write default config to \(configPath): \(error)")
        }
    }

    private func pollConfig() {
        guard let mtime = configMtime() else {
            if !configMissingLogged {
                print("upmixd: config file \(configPath) disappeared; keeping current settings")
                configMissingLogged = true
            }
            return
        }
        configMissingLogged = false
        guard mtime != lastConfigMtime else { return }
        lastConfigMtime = mtime
        guard let loaded = loadConfigFromDisk(), loaded != currentSettings else { return }
        currentSettings = loaded
        print("upmixd: config reloaded")
        engine?.submit(loaded)
    }

    private func aliveAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// Single pending activation at a time (no stacked retry chains), but a
    /// sooner request replaces a later pending one so a device-arrival event
    /// still beats the slow backstop that is always pending during downtime.
    private func scheduleActivation(after delay: TimeInterval) {
        guard engine == nil else { return }
        let deadline = DispatchTime.now() + delay
        if let pending = pendingActivation {
            guard deadline < pendingDeadline else { return }
            pending.cancel()
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.clearPendingActivation()
            self.activate()
        }
        pendingActivation = item
        pendingDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: deadline, execute: item)
    }

    private func clearPendingActivation() {
        pendingActivation?.cancel()
        pendingActivation = nil
        pendingDeadline = .distantFuture
    }

    private func activate() {
        guard engine == nil else { return }
        do {
            playback = try playbackUID.map { try findDevice(uid: $0) }
                ?? findPlaybackDevice(name: playbackName)
            guard let resolvedPlaybackUID = deviceUID(playback) else {
                throw CoreAudioError.notFound("UID for playback device")
            }

            try ensurePhysicalFormat(device: playback, channels: 6, bits: 16, sampleRate: sampleRate)
            try setNominalSampleRate(capture, sampleRate)
            try setNominalSampleRate(playback, sampleRate)

            // The format switch is an asynchronous USB alt-setting change;
            // give it a moment to settle before building the aggregate.
            let formatDeadline = Date(timeIntervalSinceNow: 2)
            while currentOutputChannels(playback) != 6 {
                guard Date() < formatDeadline else {
                    throw CoreAudioError.notFound("6ch format on playback device (did not settle)")
                }
                usleep(100_000)
            }

            let newEngine = Engine(settings: currentSettings, sampleRate: sampleRate)
            try newEngine.start(captureUID: captureUID, playbackUID: resolvedPlaybackUID)
            engine = newEngine
            activePlaybackUID = resolvedPlaybackUID
            clearPendingActivation()
            waitingLogged = false
            print("upmixd: \(deviceName(capture) ?? captureUID) → \(deviceName(playback) ?? "?") (5.1) @ \(Int(sampleRate))Hz")

            if manageDefault {
                try? setDefaultOutputDevice(capture)
                print("upmixd: default output set to \(deviceName(capture) ?? captureUID)")
            }

            installPlaybackAliveListener(on: playback)
            startHealthTimer(for: newEngine)
        } catch {
            if !waitingLogged {
                print("upmixd: waiting for devices (\(error))")
                waitingLogged = true
            }
            // Backstop in case no device-list notification ever fires again
            // (e.g. the failure wasn't a missing device).
            scheduleActivation(after: 10.0)
        }
    }

    private func installPlaybackAliveListener(on device: AudioDeviceID) {
        var aliveAddr = aliveAddress()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // The id check makes listeners from previous attach cycles inert.
            guard let self, self.playback == device, !isDeviceAlive(device) else { return }
            self.handlePlaybackGone()
        }
        let status = AudioObjectAddPropertyListenerBlock(device, &aliveAddr, .main, block)
        if status == noErr {
            playbackAliveBlock = block
        } else {
            // Non-fatal: the health timer notices a dead pipeline within 3s.
            print("upmixd: warning: playback device-alive listener failed (\(status))")
        }
    }

    private func handlePlaybackGone() {
        guard engine != nil else { return }
        print("upmixd: playback device disappeared")
        activePlaybackUID = nil
        teardownEngine()
        fallBackDefaultOutput()
        // The device-list listener reattaches when the adapter returns; the
        // backstop covers a replug whose notification raced the teardown.
        scheduleActivation(after: 10.0)
    }

    private func startHealthTimer(for engine: Engine) {
        // If the pipeline is ever unhealthy (e.g. something flips the adapter
        // back to 2ch and the aggregate republishes its buffers), tear down
        // and reattach — silence must never look like success. The probe is
        // re-armed after each read so a stopped IOProc also reads as unhealthy.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let health = engine.health
            guard health == .ok else {
                print("upmixd: pipeline unhealthy (\(health.description)), reattaching")
                self.teardownEngine()
                self.fallBackDefaultOutput()
                self.scheduleActivation(after: 3.0)
                return
            }
            engine.resetHealthProbe()
        }
        timer.resume()
        healthTimer = timer
    }

    private func teardownEngine() {
        healthTimer?.cancel()
        healthTimer = nil
        if let block = playbackAliveBlock {
            var aliveAddr = aliveAddress()
            // Best effort — fails harmlessly when the device is already gone.
            AudioObjectRemovePropertyListenerBlock(playback, &aliveAddr, .main, block)
            playbackAliveBlock = nil
        }
        engine?.stop()
        engine = nil
    }

    /// Audio routed to BlackHole with no consumer is silence; put the default
    /// somewhere audible until the pipeline is back. Only when this daemon
    /// manages the default — a manually configured default is not ours to move.
    private func fallBackDefaultOutput() {
        guard manageDefault, defaultOutputDevice() == capture else { return }
        guard let builtIn = findBuiltInOutputDevice(),
              (try? setDefaultOutputDevice(builtIn)) != nil else {
            print("upmixd: warning: no built-in output to fall back to; default output is still \(deviceName(capture) ?? "the capture device")")
            return
        }
        print("upmixd: default output fell back to \(deviceName(builtIn) ?? "built-in speakers")")
    }
}

var captureUID = defaultCaptureUID
var playbackUID: String?
var playbackName = defaultPlaybackName
var setDefault = false
var config = UpmixConfig()
var configPath = FileManager.default.homeDirectoryForCurrentUser.path + "/.config/upmixd.conf"

var args = ArraySlice(CommandLine.arguments.dropFirst())
while let arg = args.popFirst() {
    switch arg {
    case "--capture-uid": captureUID = args.popFirst() ?? { usage() }()
    case "--playback-uid": playbackUID = args.popFirst() ?? { usage() }()
    case "--playback-name": playbackName = args.popFirst() ?? { usage() }()
    case "--set-default": setDefault = true
    case "--rear-gain":
        config.rearGain = Float(parseNumber(args.popFirst(), flag: arg, min: 0, max: 1))
    case "--rear-delay-ms":
        config.rearDelayMs = parseNumber(args.popFirst(), flag: arg, min: 1, max: 100)
    case "--center-gain":
        config.centerGain = Float(parseNumber(args.popFirst(), flag: arg, min: 0, max: 0.5))
    case "--lfe-gain":
        config.lfeGain = Float(parseNumber(args.popFirst(), flag: arg, min: 0, max: 0.45))
    case "--config": configPath = args.popFirst() ?? { usage() }()
    case "--list":
        for device in (try? allDeviceIDs()) ?? [] {
            print("\(device)\t\(deviceName(device) ?? "?")\t\(deviceUID(device) ?? "?")")
        }
        exit(0)
    default: usage()
    }
}

do {
    let supervisor = Supervisor(
        captureUID: captureUID, playbackUID: playbackUID,
        playbackName: playbackName, manageDefault: setDefault,
        configTemplate: config, configPath: configPath)

    // Signal handling is armed before run(): activation can block for seconds
    // and may already have re-pointed the default output, so a SIGTERM in
    // that window must still shut down in an orderly way (queued behind the
    // in-flight activation on the main queue).
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    for sig in [SIGINT, SIGTERM] {
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler { supervisor.shutdown(0) }
        source.resume()
        _ = Unmanaged.passRetained(source) // keep alive for process lifetime
    }

    try supervisor.run()
    RunLoop.main.run()
} catch {
    FileHandle.standardError.write("upmixd: \(error)\n".data(using: .utf8)!)
    exit(1)
}
