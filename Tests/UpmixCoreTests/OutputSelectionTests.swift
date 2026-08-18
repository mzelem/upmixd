import XCTest
@testable import UpmixCore

final class OutputSelectionTests: XCTestCase {
    private func candidate(
        uid: String, name: String, channels: Int,
        isCurrentDefault: Bool = false, isVirtual: Bool = false
    ) -> OutputCandidate {
        OutputCandidate(
            uid: uid, name: name, maxOutputChannels: channels,
            isCurrentDefault: isCurrentDefault, isVirtual: isVirtual)
    }

    func testAutoPicksMostChannels() {
        let chosen = chooseOutput(
            candidates: [
                candidate(uid: "hdmi", name: "Monitor", channels: 2),
                candidate(uid: "usb", name: "USB Sound Device", channels: 8),
                candidate(uid: "builtin", name: "MacBook Pro Speakers", channels: 2),
            ],
            selection: .automatic, captureUID: "BlackHole2ch_UID")
        XCTAssertEqual(chosen?.uid, "usb")
    }

    func testAutoPrefersFeasibleSurroundOverInfeasibleCapability() {
        // An 8ch-capable HDMI sink without the pipeline's exact format is
        // effectively a stereo device; a feasible 6ch adapter must win.
        let chosen = chooseOutput(
            candidates: [
                candidate(uid: "hdmi8", name: "AVR", channels: 8)
                    .with(surround: false),
                candidate(uid: "usb", name: "USB Sound Device", channels: 6),
            ],
            selection: .automatic, captureUID: "cap")
        XCTAssertEqual(chosen?.uid, "usb")
    }

    func testAutoExcludesVirtualAndCapture() {
        let chosen = chooseOutput(
            candidates: [
                candidate(uid: "BlackHole2ch_UID", name: "BlackHole 2ch", channels: 2),
                candidate(uid: "bh16", name: "BlackHole 16ch", channels: 16, isVirtual: true),
                candidate(uid: "teams", name: "Teams Audio", channels: 2, isVirtual: true),
                candidate(uid: "builtin", name: "MacBook Pro Speakers", channels: 2),
            ],
            selection: .automatic, captureUID: "BlackHole2ch_UID")
        XCTAssertEqual(chosen?.uid, "builtin",
                       "virtual devices and the capture device must never be chosen")
    }

    func testAutoTieBreaksTowardCurrentDefault() {
        let chosen = chooseOutput(
            candidates: [
                candidate(uid: "hdmi", name: "Monitor", channels: 2),
                candidate(uid: "dac", name: "Nice DAC", channels: 2, isCurrentDefault: true),
            ],
            selection: .automatic, captureUID: "cap")
        XCTAssertEqual(chosen?.uid, "dac")
    }

    func testAutoTieBreakIsDeterministicWithoutDefault() {
        let candidates = [
            candidate(uid: "b", name: "Bravo", channels: 2),
            candidate(uid: "a", name: "Alpha", channels: 2),
        ]
        XCTAssertEqual(
            chooseOutput(candidates: candidates, selection: .automatic, captureUID: "cap")?.uid,
            chooseOutput(candidates: candidates.reversed(), selection: .automatic, captureUID: "cap")?.uid,
            "same set must choose the same device regardless of enumeration order")
    }

    func testExplicitSelectionMayChooseVirtualDevices() {
        // Chaining is legitimate: a user may deliberately route into another
        // virtual device. Only the capture itself stays off-limits (feedback).
        let virtualOut = candidate(uid: "bh16", name: "BlackHole 16ch", channels: 16, isVirtual: true)
        XCTAssertEqual(
            chooseOutput(
                candidates: [virtualOut], selection: .explicit(uid: nil, name: "BlackHole 16ch"),
                captureUID: "cap")?.uid,
            "bh16")
        XCTAssertNil(
            chooseOutput(
                candidates: [candidate(uid: "cap", name: "BlackHole 2ch", channels: 2)],
                selection: .explicit(uid: "cap", name: "BlackHole 2ch"), captureUID: "cap"),
            "explicitly selecting the capture would build a feedback loop")
    }

    func testExplicitUidWinsOverName() {
        let chosen = chooseOutput(
            candidates: [
                candidate(uid: "u1", name: "Duplicate", channels: 2),
                candidate(uid: "u2", name: "Duplicate", channels: 6),
            ],
            selection: .explicit(uid: "u1", name: "Duplicate"), captureUID: "cap")
        XCTAssertEqual(chosen?.uid, "u1")
    }

    func testExplicitFallsBackToNameWhenUidGone() {
        // USB UIDs embed the port location, so a replug changes the UID but
        // keeps the name — name match must rescue the selection.
        let chosen = chooseOutput(
            candidates: [candidate(uid: "newport", name: "USB Sound Device", channels: 8)],
            selection: .explicit(uid: "oldport", name: "USB Sound Device"), captureUID: "cap")
        XCTAssertEqual(chosen?.uid, "newport")
    }

    func testExplicitMissingDeviceReturnsNilNotAuto() {
        let chosen = chooseOutput(
            candidates: [candidate(uid: "builtin", name: "MacBook Pro Speakers", channels: 2)],
            selection: .explicit(uid: "gone", name: "Gone Device"), captureUID: "cap")
        XCTAssertNil(chosen, "an explicit selection must wait for its device, not silently switch")
    }

    func testAutoReturnsNilWhenOnlyVirtualDevicesExist() {
        let chosen = chooseOutput(
            candidates: [candidate(uid: "bh", name: "BlackHole 2ch", channels: 2, isVirtual: true)],
            selection: .automatic, captureUID: "cap")
        XCTAssertNil(chosen)
    }

    func testPipelineChannelsForDevice() {
        XCTAssertEqual(candidate(uid: "a", name: "a", channels: 8).pipelineChannels, 6)
        XCTAssertEqual(candidate(uid: "a", name: "a", channels: 6).pipelineChannels, 6)
        XCTAssertEqual(candidate(uid: "a", name: "a", channels: 4).pipelineChannels, 2,
                       "no 4ch mode; EQ-only stereo")
        XCTAssertEqual(candidate(uid: "a", name: "a", channels: 2).pipelineChannels, 2)
        XCTAssertEqual(
            candidate(uid: "a", name: "a", channels: 8).with(surround: false).pipelineChannels, 2,
            "capability without pipeline-format feasibility is stereo")
    }
}

private extension OutputCandidate {
    func with(surround: Bool) -> OutputCandidate {
        var copy = self
        copy.supportsSurroundPipeline = surround
        return copy
    }
}
