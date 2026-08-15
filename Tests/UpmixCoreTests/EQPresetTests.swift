import XCTest
@testable import UpmixCore

final class EQPresetTests: XCTestCase {
    func testEveryPresetFitsTheSliders() {
        XCTAssertFalse(EQPreset.all.isEmpty)
        for preset in EQPreset.all {
            XCTAssertEqual(
                preset.gainsDb.count, GraphicEQ.standardFrequencies.count,
                "\(preset.name) must have one gain per band")
            XCTAssertTrue(
                preset.gainsDb.allSatisfy { abs($0) <= GraphicEQ.maxSliderDb },
                "\(preset.name) must stay within the slider range")
        }
    }

    func testPresetNamesAreUnique() {
        let names = EQPreset.all.map(\.name)
        XCTAssertEqual(names.count, Set(names).count)
    }

    func testFlatPresetIsAllZeros() {
        let flat = EQPreset.all.first { $0.name == "Flat" }
        XCTAssertEqual(flat?.gainsDb, [Float](repeating: 0, count: 10))
    }

    func testMatchingFindsExactPresetOrNil() {
        for preset in EQPreset.all {
            XCTAssertEqual(EQPreset.matching(preset.gainsDb)?.name, preset.name)
        }
        var custom = EQPreset.all[1].gainsDb
        custom[0] += 1
        XCTAssertNil(EQPreset.matching(custom))
    }

    func testPresetsAreValidConfigBands() {
        // Applying any preset and writing the file must produce a config the
        // daemon accepts without warnings.
        for preset in EQPreset.all {
            var eq = GraphicEQ(from: DaemonSettings())
            eq.gainsDb = preset.gainsDb
            let text = eq.applied(to: DaemonSettings()).render()
            let result = DaemonSettings.parse(text)
            XCTAssertTrue(result.warnings.isEmpty, "\(preset.name): \(result.warnings)")
        }
    }
}
