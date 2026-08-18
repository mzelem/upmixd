import CoreAudio
import Foundation
import UpmixCore
import UpmixDevices

setvbuf(stdout, nil, _IOLBF, 0) // line-buffer logs under launchd

let defaultCaptureUID = "BlackHole2ch_UID"
// Single source of truth shared with config validation, so bands the parser
// accepts are always applicable to the running pipeline.
let sampleRate = DaemonSettings.nominalSampleRate

func usage() -> Never {
    print("""
        usage: upmixd [options]

        Reads system audio from a 2ch virtual device (BlackHole) and plays it
        upmixed to 5.1 on a multichannel output device. Stays resident,
        reattaching the moment a disappeared playback device returns; with
        --set-default it also keeps the system default output pointed at the
        right place through those transitions.

        options:
          --capture-uid <uid>    capture device UID (default: \(defaultCaptureUID))
          --playback-uid <uid>   select the output device by UID
          --playback-name <name> select the output device by name
                                 (default: automatic — the most capable real
                                 device; the config file's output_device
                                 setting overrides these flags)
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
                                 override flag values; note the panel writes
                                 every key, so flag values persist only until
                                 the panel's first write.
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
    private let manageDefault: Bool
    private let configPath: String
    /// Settings derived from CLI flags; the config file is parsed on top of
    /// these, so the file wins where it speaks and flags fill the gaps.
    private let seedSettings: DaemonSettings
    private var currentSettings: DaemonSettings
    private var configTimer: DispatchSourceTimer?
    private var configDirWatcher: DispatchSourceFileSystemObject?
    private var configMissingLogged = false
    private var lastConfigMtime: Date?
    private var lastWaitMessage: String?

    private var capture: AudioDeviceID = 0
    private var playback: AudioDeviceID = 0
    private var activePlaybackUID: String?
    private var activeChannels = 0
    private var playbackAliveBlock: AudioObjectPropertyListenerBlock?
    private var engine: Engine?
    private var healthTimer: DispatchSourceTimer?
    private var pendingActivation: DispatchWorkItem?
    private var pendingDeadline: DispatchTime = .distantFuture

    init(
        captureUID: String, playbackUID: String?, playbackName: String?,
        manageDefault: Bool, configTemplate: UpmixConfig, configPath: String
    ) {
        self.captureUID = captureUID
        self.manageDefault = manageDefault
        self.configPath = configPath
        var seed = DaemonSettings()
        seed.upmix = configTemplate
        seed.outputName = playbackName
        seed.outputUid = playbackUID
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
                self?.scheduleReevaluation()
            },
            "install device-list listener")

        activate()
    }

    /// Device arrivals can change what automatic selection would pick (dock
    /// the surround adapter while running on the built-in speakers); if the
    /// best choice differs from the active device, reattach to it.
    private func scheduleReevaluation() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.engine != nil else { return }
            let candidates = listOutputCandidates(captureUID: self.captureUID)
            guard let best = chooseOutput(
                candidates: candidates, selection: self.currentSettings.outputSelection,
                captureUID: self.captureUID),
                best.uid != self.activePlaybackUID
            else { return }
            print("upmixd: switching output to \(logSafe(best.name))")
            self.teardownEngine()
            self.activate()
        }
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
            } else if let fallback = findFallbackOutputDevice(excluding: capture) {
                try? setDefaultOutputDevice(fallback)
            }
        }
        exit(code)
    }

    // MARK: - Config file

    private func setupConfig() {
        if !FileManager.default.fileExists(atPath: configPath) {
            writeDefaultConfig()
            lastConfigMtime = configMtime()
        } else if let loaded = loadConfigFromDisk() {
            currentSettings = loaded
            lastConfigMtime = configMtime()
        } else {
            // Existing but unreadable (permissions, encoding): never
            // overwrite the user's file; run on flag/default settings.
            // lastConfigMtime stays nil so the poll keeps retrying the read
            // even if the mtime never changes (e.g. a chmod fix).
            print("upmixd: warning: \(configPath) exists but is unreadable; keeping it untouched and using default settings")
        }

        startConfigDirWatcher()

        // Backstop only: the directory watcher delivers changes within
        // milliseconds; the timer covers watcher-less fallback and any
        // missed vnode edge cases.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in self?.pollConfig() }
        timer.resume()
        configTimer = timer
    }

    /// Watch the config's parent directory, not the file: atomic saves
    /// replace the file's inode on every write (a file watch would go stale
    /// after the first save), while the directory event fires for each
    /// rename. pollConfig()'s mtime/equality gates make unrelated directory
    /// events no-ops.
    private func startConfigDirWatcher() {
        let directory = (configPath as NSString).deletingLastPathComponent
        let fd = open(directory, O_EVTONLY)
        guard fd >= 0 else {
            print("upmixd: warning: cannot watch \(directory); config changes apply on the 10 s poll")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.pollConfig() }
        source.setCancelHandler { close(fd) }
        source.resume()
        configDirWatcher = source
    }

    private func configMtime() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: configPath))?[.modificationDate] as? Date
    }

    private func loadConfigFromDisk() -> DaemonSettings? {
        // A real config is a few hundred bytes; refuse pathological files
        // rather than reading them into memory (audio must survive anything
        // another same-user process does to this file).
        if let size = (try? FileManager.default.attributesOfItem(atPath: configPath))?[.size]
            as? UInt64, size > 1_000_000 {
            print("upmixd: warning: \(configPath) is \(size) bytes; ignoring (limit 1MB)")
            return nil
        }
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
        // Consume the mtime only after a successful read, so a transiently
        // unreadable file (mid-save) is retried on the next poll.
        guard let loaded = loadConfigFromDisk() else { return }
        lastConfigMtime = mtime
        guard loaded != currentSettings else { return }
        let selectionChanged = loaded.outputSelection != currentSettings.outputSelection
        currentSettings = loaded
        print("upmixd: config reloaded")
        if selectionChanged, engine != nil {
            print("upmixd: output selection changed; reattaching")
            teardownEngine()
            activate()
        } else {
            engine?.submit(loaded)
        }
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
            let candidates = listOutputCandidates(captureUID: captureUID)
            guard let chosen = chooseOutput(
                candidates: candidates, selection: currentSettings.outputSelection,
                captureUID: captureUID)
            else {
                throw CoreAudioError.notFound(
                    "output device for selection \(currentSettings.outputName ?? "auto")")
            }
            playback = try findDevice(uid: chosen.uid)
            let resolvedPlaybackUID = chosen.uid
            let channels = pipelineChannels(deviceMaxChannels: chosen.maxOutputChannels)

            try setNominalSampleRate(capture, sampleRate)
            if channels == 6 {
                try ensurePhysicalFormat(
                    device: playback, channels: 6, bits: 16, sampleRate: sampleRate)
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
            } else {
                // Stereo passthrough: nudge the device toward the pipeline
                // rate but respect whatever it actually runs — the DSP is
                // built for the real rate below.
                try? setNominalSampleRate(playback, sampleRate)
            }
            let engineRate = channels == 6
                ? sampleRate
                : (deviceNominalSampleRate(playback) ?? sampleRate)

            let captureStreams = (try? outputStreams(capture).count) ?? 1
            let newEngine = Engine(
                settings: currentSettings, sampleRate: engineRate,
                outputChannels: channels, captureOutputStreams: captureStreams)
            try newEngine.start(captureUID: captureUID, playbackUID: resolvedPlaybackUID)
            engine = newEngine
            activePlaybackUID = resolvedPlaybackUID
            activeChannels = channels
            clearPendingActivation()
            lastWaitMessage = nil
            let mode = channels == 6 ? "5.1" : "stereo EQ"
            print("upmixd: \(logSafe(deviceName(capture) ?? captureUID)) → \(logSafe(chosen.name)) (\(mode)) @ \(Int(engineRate))Hz")

            if manageDefault {
                try? setDefaultOutputDevice(capture)
                print("upmixd: default output set to \(logSafe(deviceName(capture) ?? captureUID))")
            }

            installPlaybackAliveListener(on: playback)
            startHealthTimer(for: newEngine)
        } catch {
            // Log once per distinct failure, so a changed diagnosis (device
            // missing → format won't settle) still reaches the log.
            let message = "upmixd: waiting for devices (\(error))"
            if message != lastWaitMessage {
                print(message)
                lastWaitMessage = message
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
        guard let fallback = findFallbackOutputDevice(excluding: capture),
              (try? setDefaultOutputDevice(fallback)) != nil else {
            print("upmixd: warning: no built-in output to fall back to; default output is still \(logSafe(deviceName(capture) ?? "the capture device"))")
            return
        }
        print("upmixd: default output fell back to \(logSafe(deviceName(fallback) ?? "built-in speakers"))")
    }
}

var captureUID = defaultCaptureUID
var playbackUID: String?
var playbackName: String?
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
            print("\(device)\t\(logSafe(deviceName(device) ?? "?"))\t\(logSafe(deviceUID(device) ?? "?"))")
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
