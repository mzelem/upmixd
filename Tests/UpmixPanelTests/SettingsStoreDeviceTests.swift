import XCTest

import UpmixCore
import UpmixDevices
@testable import UpmixPanel

/// The panel's device list must track hardware changes: SwiftUI never re-runs
/// `body` for a plug/unplug/wake on its own, so `SettingsStore` has to publish
/// a fresh enumeration itself. These tests drive that through the injected
/// enumeration seam (no real CoreAudio scan).
@MainActor
final class SettingsStoreDeviceTests: XCTestCase {
    /// A config path that does not exist — the store runs on defaults and never
    /// touches the user's real config.
    private var tempConfigPath: String {
        NSTemporaryDirectory() + "upmixd-tests-\(UUID().uuidString).conf"
    }

    private func candidate(
        uid: String, name: String, channels: Int, virtual: Bool = false, isDefault: Bool = false
    ) -> OutputCandidate {
        OutputCandidate(
            uid: uid, name: name, maxOutputChannels: channels,
            isCurrentDefault: isDefault, isVirtual: virtual)
    }

    func testPickerExcludesCaptureAndVirtualAndSortsByName() {
        let scan = [
            candidate(uid: "z-uid", name: "Zeta Speakers", channels: 2),
            candidate(uid: SettingsStore.captureUID, name: "BlackHole 2ch", channels: 2),
            candidate(uid: "agg-uid", name: "Aggregate", channels: 6, virtual: true),
            candidate(uid: "a-uid", name: "Alpha Surround", channels: 6),
        ]
        let store = SettingsStore(configPath: tempConfigPath, enumerate: { _ in scan }, monitorHardware: false)

        XCTAssertEqual(store.outputCandidates.map(\.name), ["Alpha Surround", "Zeta Speakers"])
    }

    func testResolvedOutputTracksAutomaticSelection() {
        let scan = [
            candidate(uid: "stereo", name: "Stereo Dock", channels: 2),
            candidate(uid: "surround", name: "Surround Rig", channels: 6),
        ]
        let store = SettingsStore(configPath: tempConfigPath, enumerate: { _ in scan }, monitorHardware: false)

        // Automatic (no explicit selection) picks the most capable real device.
        XCTAssertEqual(store.resolvedOutput.candidate?.uid, "surround")
        XCTAssertTrue(store.resolvedOutput.surround)
    }

    func testRefreshReflectsHotPluggedDevice() {
        // The enumerator reads a mutable snapshot, standing in for the hardware
        // set changing under the store between refreshes.
        var current = [candidate(uid: "builtin", name: "Built-in", channels: 2)]
        let store = SettingsStore(configPath: tempConfigPath, enumerate: { _ in current }, monitorHardware: false)

        XCTAssertEqual(store.outputCandidates.map(\.uid), ["builtin"])
        XCTAssertFalse(store.resolvedOutput.surround)

        // Dock a surround adapter, then refresh as the listeners would.
        current.append(candidate(uid: "surround", name: "Surround Rig", channels: 6))
        store.refreshDevices()

        XCTAssertEqual(store.outputCandidates.map(\.uid).sorted(), ["builtin", "surround"])
        XCTAssertEqual(store.resolvedOutput.candidate?.uid, "surround")
        XCTAssertTrue(store.resolvedOutput.surround)

        // Undock it: the picker and the resolved auto choice fall back.
        current.removeAll { $0.uid == "surround" }
        store.refreshDevices()

        XCTAssertEqual(store.outputCandidates.map(\.uid), ["builtin"])
        XCTAssertEqual(store.resolvedOutput.candidate?.uid, "builtin")
        XCTAssertFalse(store.resolvedOutput.surround)
    }

    func testSelectOutputReresolvesWithoutRescan() {
        var scanCount = 0
        let scan = [
            candidate(uid: "stereo", name: "Stereo Dock", channels: 2),
            candidate(uid: "surround", name: "Surround Rig", channels: 6),
        ]
        let store = SettingsStore(configPath: tempConfigPath, enumerate: { _ in
            scanCount += 1
            return scan
        }, monitorHardware: false)
        let scansAfterInit = scanCount

        // Explicitly pick the stereo device; resolved output follows the choice
        // and does not re-scan the hardware.
        store.selectOutput(scan[0])

        XCTAssertEqual(store.resolvedOutput.candidate?.uid, "stereo")
        XCTAssertFalse(store.resolvedOutput.surround)
        XCTAssertEqual(scanCount, scansAfterInit, "selecting must not re-enumerate CoreAudio")
    }
}
