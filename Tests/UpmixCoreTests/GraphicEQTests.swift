import XCTest
@testable import UpmixCore

final class GraphicEQTests: XCTestCase {
    func testTenStandardBands() {
        XCTAssertEqual(
            GraphicEQ.standardFrequencies,
            [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000])
    }

    func testFlatSettingsGiveZeroSliders() {
        let eq = GraphicEQ(from: DaemonSettings())
        XCTAssertEqual(eq.gainsDb, [Float](repeating: 0, count: 10))
        XCTAssertTrue(eq.customBands.isEmpty)
    }

    func testMapsMatchingBandsToSliders() {
        var settings = DaemonSettings()
        settings.eqBands = [
            EqBand(freqHz: 64, gainDb: 4),
            EqBand(freqHz: 4000, gainDb: -3),
        ]
        let eq = GraphicEQ(from: settings)
        XCTAssertEqual(eq.gainsDb[1], 4)
        XCTAssertEqual(eq.gainsDb[7], -3)
        XCTAssertEqual(eq.gainsDb.filter { $0 != 0 }.count, 2)
        XCTAssertTrue(eq.customBands.isEmpty)
    }

    func testPreservesCustomBands() {
        // Non-standard frequency, non-default Q, or out-of-slider-range gain
        // must survive untouched rather than being snapped to a slider.
        var settings = DaemonSettings()
        settings.eqBands = [
            EqBand(freqHz: 300, gainDb: 2),            // non-standard freq
            EqBand(freqHz: 1000, gainDb: 3, q: 5),     // non-default Q
            EqBand(freqHz: 2000, gainDb: 18),          // beyond slider range
            EqBand(freqHz: 500, gainDb: -2),           // maps to a slider
        ]
        let eq = GraphicEQ(from: settings)
        XCTAssertEqual(eq.customBands.count, 3)
        XCTAssertEqual(eq.gainsDb[4], -2)

        var out = eq.applied(to: settings)
        XCTAssertEqual(out.eqBands.count, 4)
        XCTAssertTrue(out.eqBands.contains(EqBand(freqHz: 1000, gainDb: 3, q: 5)))
        XCTAssertTrue(out.eqBands.contains(EqBand(freqHz: 2000, gainDb: 18)))

        // Zeroing the slider drops only the slider band.
        var flat = eq
        flat.gainsDb[4] = 0
        out = flat.applied(to: settings)
        XCTAssertEqual(out.eqBands.count, 3)
    }

    func testAppliedWritesOnlyNonZeroSliderBands() {
        var eq = GraphicEQ(from: DaemonSettings())
        eq.gainsDb[0] = 6
        eq.gainsDb[9] = -4.5
        let out = eq.applied(to: DaemonSettings())
        XCTAssertEqual(out.eqBands.count, 2)
        XCTAssertEqual(out.eqBands[0], EqBand(freqHz: 32, gainDb: 6))
        XCTAssertEqual(out.eqBands[1], EqBand(freqHz: 16000, gainDb: -4.5))
    }

    func testAppliedPreservesNonEqSettings() {
        var settings = DaemonSettings()
        settings.upmix.rearGain = 0.42
        settings.eqPreampDb = -3
        let out = GraphicEQ(from: settings).applied(to: settings)
        XCTAssertEqual(out.upmix.rearGain, 0.42)
        XCTAssertEqual(out.eqPreampDb, -3)
    }

    func testRoundTripThroughConfigFile() {
        var eq = GraphicEQ(from: DaemonSettings())
        eq.gainsDb = [1, -2, 3, -4, 5, -6, 7, -8, 9, -10]
        let written = eq.applied(to: DaemonSettings()).render()
        let reparsed = DaemonSettings.parse(written)
        XCTAssertTrue(reparsed.warnings.isEmpty)
        XCTAssertEqual(GraphicEQ(from: reparsed.settings).gainsDb, eq.gainsDb)
    }

    func testSliderGainsClampToUiRange() {
        var eq = GraphicEQ(from: DaemonSettings())
        eq.gainsDb[3] = 40
        eq.gainsDb[5] = -40
        let out = eq.applied(to: DaemonSettings())
        XCTAssertEqual(out.eqBands.first { $0.freqHz == 250 }?.gainDb, GraphicEQ.maxSliderDb)
        XCTAssertEqual(out.eqBands.first { $0.freqHz == 1000 }?.gainDb, -GraphicEQ.maxSliderDb)
    }
}
