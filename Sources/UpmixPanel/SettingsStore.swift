import AppKit
import Combine
import CoreAudio
import Foundation
import UpmixCore
import UpmixDevices

/// Owns the panel's view of ~/.config/upmixd.conf: loads it, exposes slider
/// state, and writes changes back (debounced, atomically). The daemon watches
/// the file; this store never talks to the daemon directly.
@MainActor
final class SettingsStore: ObservableObject {
    /// Mirrors the daemon's default capture; the picker filters it out.
    static let captureUID = "BlackHole2ch_UID"

    @Published var graphicEQ: GraphicEQ
    /// nil name = automatic selection.
    @Published var outputName: String?
    @Published var outputUid: String?
    @Published var preampAuto: Bool
    /// Manual preamp in dB, used when preampAuto is off.
    @Published var preampDb: Float
    @Published var rearGain: Float
    @Published var rearDelayMs: Double
    @Published var centerGain: Float
    @Published var lfeGain: Float
    /// Read problem: blocks writes (never write over a file we couldn't read).
    @Published private(set) var fileError: String?
    /// Write problem: surfaced in the UI but writes keep retrying, so one
    /// transient failure (disk full, permissions blip) can't mute the panel.
    @Published private(set) var writeError: String?

    /// Real output devices for the picker, refreshed whenever the hardware
    /// changes. Published so the menu re-renders live — SwiftUI never re-runs
    /// `body` for a hardware change on its own, so a plain per-render
    /// enumeration would go stale on plug/unplug/wake.
    @Published private(set) var outputCandidates: [OutputCandidate] = []
    /// The device automatic mode (or the current explicit choice) resolves to
    /// right now, and whether the pipeline runs 5.1 there. Kept in lockstep
    /// with `outputCandidates` and the user's selection.
    @Published private(set) var resolvedOutput: (candidate: OutputCandidate?, surround: Bool) = (nil, false)

    let configPath: String

    /// Carries everything the sliders don't own (custom bands, preamp mode).
    private var baseSettings: DaemonSettings
    private var writeDebounce: DispatchWorkItem?
    private var lastKnownMtime: Date?

    /// Device enumeration seam: the real CoreAudio scan by default, a stub in
    /// tests. Takes the capture UID (so the scan can flag/exclude it).
    private let enumerate: (String) -> [OutputCandidate]
    /// The last full (unfiltered) scan, kept so `resolvedOutput` can be
    /// recomputed on a selection change without re-hitting CoreAudio.
    private var lastScan: [OutputCandidate] = []
    /// CoreAudio system-object listeners, retained so they can be removed.
    private var systemListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var wakeObserver: NSObjectProtocol?
    /// Coalesces bursts of device notifications (a re-enumerating adapter fires
    /// one per stream) into a single refresh.
    private var refreshDebounce: DispatchWorkItem?

    init(
        configPath: String = SettingsStore.defaultConfigPath,
        enumerate: @escaping (String) -> [OutputCandidate] = { listOutputCandidates(captureUID: $0) },
        // Off in unit tests: registering real CoreAudio/NSWorkspace listeners
        // would make a nominally-pure store touch live system state.
        monitorHardware: Bool = true
    ) {
        self.configPath = configPath
        self.enumerate = enumerate
        let settings = DaemonSettings()
        baseSettings = settings
        graphicEQ = GraphicEQ(from: settings)
        outputName = settings.outputName
        outputUid = settings.outputUid
        preampAuto = settings.eqPreampDb == nil
        preampDb = settings.eqPreampDb ?? -6
        rearGain = settings.upmix.rearGain
        rearDelayMs = settings.upmix.rearDelayMs
        centerGain = settings.upmix.centerGain
        lfeGain = settings.upmix.lfeGain
        reload()
        refreshDevices()
        if monitorHardware {
            startDeviceMonitoring()
        }
    }

    deinit {
        // The store is a process-lifetime singleton, so this rarely runs, but
        // leaving CoreAudio/workspace listeners dangling on a fresh store (e.g.
        // per-test) would fire callbacks into a deallocated object.
        for (address, block) in systemListeners {
            var addr = address
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    nonisolated static var defaultConfigPath: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.config/upmixd.conf"
    }

    private func fileMtime() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: configPath))?[.modificationDate] as? Date
    }

    /// Re-read the file if someone else changed it since we last saw it.
    func reloadIfExternallyChanged() {
        guard fileMtime() != lastKnownMtime else { return }
        reload()
    }

    func reload() {
        // A pending debounced write captured pre-reload state; drop it.
        writeDebounce?.cancel()
        writeDebounce = nil
        lastKnownMtime = fileMtime()
        guard FileManager.default.fileExists(atPath: configPath) else {
            fileError = "\(configPath) not found — is upmixd installed?"
            return
        }
        guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            fileError = "\(configPath) is unreadable"
            return
        }
        fileError = nil
        let settings = DaemonSettings.parse(text).settings
        baseSettings = settings
        graphicEQ = GraphicEQ(from: settings)
        outputName = settings.outputName
        outputUid = settings.outputUid
        preampAuto = settings.eqPreampDb == nil
        // -6 dB (the fixed-headroom default) is where leaving auto lands.
        preampDb = settings.eqPreampDb ?? -6
        rearGain = settings.upmix.rearGain
        rearDelayMs = settings.upmix.rearDelayMs
        centerGain = settings.upmix.centerGain
        lfeGain = settings.upmix.lfeGain
        // An external edit can change the output selection; re-resolve against
        // the devices we already know about (no need to re-scan hardware).
        recomputeResolved()
    }

    /// Call after any slider mutation; coalesces bursts into one write.
    func scheduleWrite() {
        writeDebounce?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.writeNow() }
        }
        writeDebounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    /// Write any pending change immediately (e.g. before quitting).
    func flushPendingWrite() {
        guard writeDebounce != nil else { return }
        writeDebounce?.cancel()
        writeDebounce = nil
        writeNow()
    }

    /// Re-scan the audio hardware and republish the picker list and resolved
    /// output. Cheap and idempotent — safe to call on every panel open as well
    /// as from the device-change listeners.
    func refreshDevices() {
        lastScan = enumerate(Self.captureUID)
        // Virtual devices and the capture are plumbing, not places sound comes
        // out; keep them out of the picker (chooseOutput still sees the full
        // scan via lastScan, so an explicit virtual pick keeps resolving).
        outputCandidates = lastScan
            .filter { !$0.isVirtual && $0.uid != Self.captureUID }
            .sorted { $0.name < $1.name }
        recomputeResolved()
    }

    /// Resolve the current selection against the last hardware scan. Split out
    /// so a selection change (no hardware change) needn't re-scan CoreAudio.
    private func recomputeResolved() {
        let selection: OutputSelection = outputName == nil && outputUid == nil
            ? .automatic : .explicit(uid: outputUid, name: outputName)
        let chosen = chooseOutput(
            candidates: lastScan, selection: selection, captureUID: Self.captureUID)
        resolvedOutput = (chosen, (chosen?.pipelineChannels ?? 2) == 6)
    }

    func selectOutput(_ candidate: OutputCandidate?) {
        outputName = candidate?.name
        outputUid = candidate?.uid
        recomputeResolved() // reflect the new "Auto (…)" / surround state at once
        scheduleWrite()
    }

    /// Watch for anything that can change what the picker should show: devices
    /// arriving/leaving, the system default moving (it breaks auto's tie-break),
    /// and wake from sleep (adapters re-enumerate, and a device-list event does
    /// not always fire when the set is unchanged but a format reset).
    private func startDeviceMonitoring() {
        for selector in [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultOutputDevice,
        ] {
            var addr = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                // Delivered on the main queue, but the closure is not statically
                // main-actor isolated; hop explicitly.
                Task { @MainActor in self?.scheduleDeviceRefresh() }
            }
            if AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, .main, block) == noErr {
                systemListeners.append((addr, block))
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleDeviceRefresh() }
        }
    }

    /// Coalesce a burst of device notifications into one refresh a beat later,
    /// by which time a re-enumerating device has finished publishing streams.
    private func scheduleDeviceRefresh() {
        refreshDebounce?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.refreshDevices() }
        }
        refreshDebounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    /// What the daemon will actually apply, for display: the manual value, or
    /// the measured worst-case cascade boost when on auto.
    var effectivePreampDb: Float {
        if preampAuto {
            let bands = graphicEQ.applied(to: baseSettings).eqBands
            return max(-60, -Equalizer.cascadeMaxBoostDb(
                bands: bands, sampleRate: DaemonSettings.nominalSampleRate))
        }
        return preampDb
    }

    private func writeNow() {
        writeDebounce = nil
        guard fileError == nil else { return } // never write over a file we couldn't read
        // If the file changed externally while the panel was open, re-read it
        // as the base so the write preserves hand-edited custom bands. Knobs
        // the panel owns (sliders, preamp, upmix values) keep the panel's
        // values — they are the user's latest gesture.
        if fileMtime() != lastKnownMtime,
           let text = try? String(contentsOfFile: configPath, encoding: .utf8) {
            let fresh = DaemonSettings.parse(text).settings
            baseSettings = fresh
            var merged = GraphicEQ(from: fresh)
            merged.gainsDb = graphicEQ.gainsDb // sliders are the user's latest intent
            graphicEQ = merged
        }
        var settings = baseSettings
        settings.outputName = outputName
        settings.outputUid = outputUid
        settings.eqPreampDb = preampAuto ? nil : preampDb
        settings.upmix.rearGain = rearGain
        settings.upmix.rearDelayMs = rearDelayMs
        settings.upmix.centerGain = centerGain
        settings.upmix.lfeGain = lfeGain
        settings = graphicEQ.applied(to: settings)
        do {
            try settings.render().write(toFile: configPath, atomically: true, encoding: .utf8)
            baseSettings = settings
            lastKnownMtime = fileMtime()
            writeError = nil
        } catch {
            writeError = "could not write \(configPath): \(error.localizedDescription)"
        }
    }
}
