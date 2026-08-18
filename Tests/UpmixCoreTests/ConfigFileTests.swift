import XCTest
@testable import UpmixCore

final class ConfigFileTests: XCTestCase {
    func testEmptyTextYieldsDefaults() {
        let result = DaemonSettings.parse("")
        XCTAssertEqual(result.settings, DaemonSettings())
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testParsesFullConfig() {
        let text = """
        # upmix section
        rear_gain = 0.8
        rear_delay_ms = 30
        center_gain = 0.4
        lfe_gain = 0.3

        eq_preamp_db = -3
        # 3-band EQ; third band overrides Q
        eq_band = 60 +4
        eq_band = 1000 -2
        eq_band = 8000 3.5 2.0
        """
        let result = DaemonSettings.parse(text)
        XCTAssertTrue(result.warnings.isEmpty, "unexpected warnings: \(result.warnings)")
        let s = result.settings
        XCTAssertEqual(s.upmix.rearGain, 0.8, accuracy: 1e-6)
        XCTAssertEqual(s.upmix.rearDelayMs, 30, accuracy: 1e-9)
        XCTAssertEqual(s.upmix.centerGain, 0.4, accuracy: 1e-6)
        XCTAssertEqual(s.upmix.lfeGain, 0.3, accuracy: 1e-6)
        XCTAssertEqual(s.eqPreampDb, -3)
        XCTAssertEqual(s.eqBands.count, 3)
        XCTAssertEqual(s.eqBands[0].freqHz, 60)
        XCTAssertEqual(s.eqBands[0].gainDb, 4)
        XCTAssertEqual(s.eqBands[1].gainDb, -2)
        XCTAssertEqual(s.eqBands[2].q, 2.0)
        XCTAssertEqual(s.eqBands[0].q, 1.41, "default Q expected when omitted")
    }

    func testDefaultPreampIsMinusSix() {
        // Fixed -6 dB headroom by default: sliding one band must not change
        // the level of everything else (auto re-measures per change and
        // reads as a global volume shift). Auto remains opt-in.
        XCTAssertEqual(DaemonSettings().eqPreampDb, -6)
        XCTAssertEqual(DaemonSettings.parse("").settings.eqPreampDb, -6)
    }

    func testPreampAutoKeyword() {
        let result = DaemonSettings.parse("eq_preamp_db = auto")
        XCTAssertNil(result.settings.eqPreampDb)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testUnknownKeyWarnsAndContinues() {
        let result = DaemonSettings.parse("""
        bogus_key = 1
        rear_gain = 0.5
        """)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("bogus_key"))
        XCTAssertEqual(result.settings.upmix.rearGain, 0.5, accuracy: 1e-6)
    }

    func testInvalidValueWarnsAndKeepsDefault() {
        let defaults = DaemonSettings()
        for bad in [
            "rear_gain = loud",
            "rear_gain = 1.5",       // out of no-clip bounds
            "rear_gain = nan",
            "rear_delay_ms = 0",
            "center_gain = -1",
            "lfe_gain = 0.9",
            "eq_preamp_db = 5",      // positive preamp would clip
            "eq_band = 1000",        // missing gain
            "eq_band = 0 3",         // freq out of range
            "eq_band = 1000 30",     // gain out of range
            "eq_band = abc def",
        ] {
            let result = DaemonSettings.parse(bad)
            XCTAssertEqual(result.warnings.count, 1, "expected warning for: \(bad)")
            XCTAssertEqual(result.settings, defaults, "defaults should survive: \(bad)")
        }
    }

    func testMalformedLineWarns() {
        let result = DaemonSettings.parse("this is not a key value line")
        XCTAssertEqual(result.warnings.count, 1)
    }

    func testWhitespaceAndCommentsTolerated() {
        let result = DaemonSettings.parse("""
           rear_gain=0.6
        rear_delay_ms   =   20   # trailing comment
        """)
        XCTAssertTrue(result.warnings.isEmpty, "unexpected: \(result.warnings)")
        XCTAssertEqual(result.settings.upmix.rearGain, 0.6, accuracy: 1e-6)
        XCTAssertEqual(result.settings.upmix.rearDelayMs, 20, accuracy: 1e-9)
    }

    func testCrlfLineEndingsParse() {
        // Editors configured for CRLF (or files round-tripped through
        // Windows) must parse identically to LF files.
        let text = "rear_gain = 0.8\r\nlfe_gain = 0.3\r\n\r\neq_band = 60 4\r\n"
        let result = DaemonSettings.parse(text)
        XCTAssertTrue(result.warnings.isEmpty, "unexpected: \(result.warnings)")
        XCTAssertEqual(result.settings.upmix.rearGain, 0.8, accuracy: 1e-6)
        XCTAssertEqual(result.settings.upmix.lfeGain, 0.3, accuracy: 1e-6)
        XCTAssertEqual(result.settings.eqBands.count, 1)
    }

    func testLoneCarriageReturnLineEndingsParse() {
        let result = DaemonSettings.parse("rear_gain = 0.8\rlfe_gain = 0.3\r")
        XCTAssertTrue(result.warnings.isEmpty, "unexpected: \(result.warnings)")
        XCTAssertEqual(result.settings.upmix.rearGain, 0.8, accuracy: 1e-6)
        XCTAssertEqual(result.settings.upmix.lfeGain, 0.3, accuracy: 1e-6)
    }

    func testTabSeparatedEqBandParses() {
        let result = DaemonSettings.parse("eq_band =\t1000\t-2.5\t3.0")
        XCTAssertTrue(result.warnings.isEmpty, "unexpected: \(result.warnings)")
        XCTAssertEqual(result.settings.eqBands.count, 1)
        XCTAssertEqual(result.settings.eqBands[0].gainDb, -2.5)
        XCTAssertEqual(result.settings.eqBands[0].q, 3.0)
    }

    func testLastValueWinsForScalars() {
        let result = DaemonSettings.parse("""
        rear_gain = 0.4
        rear_gain = 0.9
        """)
        XCTAssertEqual(result.settings.upmix.rearGain, 0.9, accuracy: 1e-6)
    }

    func testTooManyBandsWarnsAndTruncates() {
        let lines = (0..<20).map { "eq_band = \(100 + $0 * 500) 1" }.joined(separator: "\n")
        let result = DaemonSettings.parse(lines)
        XCTAssertEqual(result.settings.eqBands.count, DaemonSettings.maxEqBands)
        XCTAssertEqual(result.warnings.count, 20 - DaemonSettings.maxEqBands)
    }

    func testOutputDeviceDefaultsToAutomatic() {
        XCTAssertEqual(DaemonSettings().outputSelection, .automatic)
        XCTAssertEqual(DaemonSettings.parse("").settings.outputSelection, .automatic)
    }

    func testOutputDeviceParsesNameAndUid() {
        let byName = DaemonSettings.parse("output_device = Nice DAC")
        XCTAssertTrue(byName.warnings.isEmpty)
        XCTAssertEqual(byName.settings.outputSelection, .explicit(uid: nil, name: "Nice DAC"))

        let both = DaemonSettings.parse("""
        output_device = USB Sound Device
        output_device_uid = AppleUSBAudioEngine:X:1
        """)
        XCTAssertTrue(both.warnings.isEmpty)
        XCTAssertEqual(
            both.settings.outputSelection,
            .explicit(uid: "AppleUSBAudioEngine:X:1", name: "USB Sound Device"))
    }

    func testOutputDeviceAutoKeywordResets() {
        var settings = DaemonSettings()
        settings.outputName = "Old"
        settings.outputUid = "old-uid"
        let parsed = DaemonSettings.parse("output_device = auto", defaults: settings)
        XCTAssertEqual(parsed.settings.outputSelection, .automatic)
        XCTAssertNil(parsed.settings.outputUid, "auto must clear a stale uid too")
    }

    func testOutputDeviceNameWithHashRoundTrips() {
        // Device names come from USB descriptors and can contain '#'; the
        // escaped form must survive the comment stripper.
        var settings = DaemonSettings()
        settings.outputName = "Speakers #2"
        settings.outputUid = "AppleUSBAudioEngine:V:Speakers #2:20:1"
        let result = DaemonSettings.parse(settings.render())
        XCTAssertTrue(result.warnings.isEmpty, "unexpected: \(result.warnings)")
        XCTAssertEqual(result.settings, settings)
    }

    func testRenderSanitizesControlCharactersInDeviceNames() {
        // A hostile descriptor string must not be able to inject config lines.
        var settings = DaemonSettings()
        settings.outputName = "Evil\nrear_gain = 0.0\nSpeakers"
        let parsed = DaemonSettings.parse(settings.render())
        XCTAssertEqual(parsed.settings.upmix.rearGain, DaemonSettings().upmix.rearGain,
                       "injected key must not take effect")
        XCTAssertTrue(parsed.settings.outputName?.contains("\n") != true)
    }

    func testNameLineClearsStaleUid() {
        // Hand-editing the name must win over a leftover uid line above it.
        var stale = DaemonSettings()
        stale.outputUid = "old-uid"
        let parsed = DaemonSettings.parse("output_device = Device B", defaults: stale)
        XCTAssertEqual(parsed.settings.outputSelection, .explicit(uid: nil, name: "Device B"))
    }

    func testUidOnlySelectionRendersWithoutAutoLine() {
        var settings = DaemonSettings()
        settings.outputUid = "some-uid"
        let text = settings.render()
        XCTAssertFalse(text.split(separator: "\n").contains("output_device = auto"),
                       "uid-only selection must not claim to be automatic")
        let parsed = DaemonSettings.parse(text)
        XCTAssertEqual(parsed.settings, settings)
    }

    func testOutputDeviceRoundTrips() {
        var settings = DaemonSettings()
        settings.outputName = "USB Sound Device"
        settings.outputUid = "AppleUSBAudioEngine:X:1"
        var result = DaemonSettings.parse(settings.render())
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(result.settings, settings)

        result = DaemonSettings.parse(DaemonSettings().render())
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(result.settings.outputSelection, .automatic)
    }

    func testAutoPreampRoundTrips() {
        var settings = DaemonSettings()
        settings.eqPreampDb = nil // auto
        let parsed = DaemonSettings.parse(settings.render())
        XCTAssertTrue(parsed.warnings.isEmpty)
        XCTAssertNil(parsed.settings.eqPreampDb)
        XCTAssertEqual(parsed.settings, settings)
    }

    func testDefaultQIsSingleSourced() {
        // Slider adoption relies on exact equality between the EqBand default,
        // the parser's fallback, and GraphicEQ's slider Q.
        let fromInit = EqBand(freqHz: 1000, gainDb: 1).q
        let fromParse = DaemonSettings.parse("eq_band = 1000 1").settings.eqBands[0].q
        XCTAssertEqual(fromInit, EqBand.defaultQ)
        XCTAssertEqual(fromParse, EqBand.defaultQ)
        XCTAssertEqual(GraphicEQ.sliderQ, EqBand.defaultQ)
    }

    func testRoundTripThroughRender() {
        var settings = DaemonSettings()
        settings.upmix.rearGain = 0.75
        settings.eqPreampDb = -2
        settings.eqBands = [EqBand(freqHz: 250, gainDb: -1.5, q: 3)]
        let parsed = DaemonSettings.parse(settings.render())
        XCTAssertTrue(parsed.warnings.isEmpty, "unexpected: \(parsed.warnings)")
        XCTAssertEqual(parsed.settings, settings)
    }
}
