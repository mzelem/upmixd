import Combine
import Foundation
import UpmixCore

/// Owns the panel's view of ~/.config/upmixd.conf: loads it, exposes slider
/// state, and writes changes back (debounced, atomically). The daemon watches
/// the file; this store never talks to the daemon directly.
@MainActor
final class SettingsStore: ObservableObject {
    @Published var graphicEQ: GraphicEQ
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

    let configPath: String

    /// Carries everything the sliders don't own (custom bands, preamp mode).
    private var baseSettings: DaemonSettings
    private var writeDebounce: DispatchWorkItem?
    private var lastKnownMtime: Date?

    init(configPath: String = SettingsStore.defaultConfigPath) {
        self.configPath = configPath
        let settings = DaemonSettings()
        baseSettings = settings
        graphicEQ = GraphicEQ(from: settings)
        preampAuto = settings.eqPreampDb == nil
        preampDb = settings.eqPreampDb ?? 0
        rearGain = settings.upmix.rearGain
        rearDelayMs = settings.upmix.rearDelayMs
        centerGain = settings.upmix.centerGain
        lfeGain = settings.upmix.lfeGain
        reload()
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
        preampAuto = settings.eqPreampDb == nil
        // 0 dB (full loudness) is the natural starting point when leaving auto.
        preampDb = settings.eqPreampDb ?? 0
        rearGain = settings.upmix.rearGain
        rearDelayMs = settings.upmix.rearDelayMs
        centerGain = settings.upmix.centerGain
        lfeGain = settings.upmix.lfeGain
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
        var settings = baseSettings
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
