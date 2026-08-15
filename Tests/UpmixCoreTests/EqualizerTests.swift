import XCTest
@testable import UpmixCore

final class EqualizerTests: XCTestCase {
    private let sampleRate = 48_000.0

    private func sine(freq: Double, frames: Int) -> [Float] {
        (0..<frames).map { Float(sin(2.0 * .pi * freq * Double($0) / sampleRate)) }
    }

    private func rms(_ x: ArraySlice<Float>) -> Float {
        sqrt(x.map { $0 * $0 }.reduce(0, +) / Float(x.count))
    }

    /// Runs a stereo signal through the EQ and returns steady-state
    /// output/input RMS ratio measured over the second half.
    private func gain(of eq: Equalizer, at freq: Double) -> Float {
        let n = 19200
        var left = sine(freq: freq, frames: n)
        var right = left
        let input = rms(left[(n/2)...])
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                eq.process(left: l.baseAddress!, right: r.baseAddress!, frames: n)
            }
        }
        return rms(left[(n/2)...]) / input
    }

    func testBoostAtCenterFrequency() {
        let eq = Equalizer(
            bands: [EqBand(freqHz: 1000, gainDb: 6)], sampleRate: sampleRate, preampDb: 0)!
        let g = gain(of: eq, at: 1000)
        XCTAssertEqual(g, 2.0, accuracy: 0.1, "+6 dB at center should double amplitude")
    }

    func testCutAtCenterFrequency() {
        let eq = Equalizer(
            bands: [EqBand(freqHz: 1000, gainDb: -6)], sampleRate: sampleRate, preampDb: 0)!
        let g = gain(of: eq, at: 1000)
        XCTAssertEqual(g, 0.5, accuracy: 0.05, "-6 dB at center should halve amplitude")
    }

    func testUnityFarFromBand() {
        let eq = Equalizer(
            bands: [EqBand(freqHz: 1000, gainDb: 6)], sampleRate: sampleRate, preampDb: 0)!
        let g = gain(of: eq, at: 60)
        XCTAssertEqual(g, 1.0, accuracy: 0.05, "band should not affect frequencies octaves away")
    }

    func testAutoPreampCompensatesMaxBoost() {
        // preampDb nil = automatic headroom for the measured cascade peak.
        let eq = Equalizer(
            bands: [EqBand(freqHz: 1000, gainDb: 6), EqBand(freqHz: 8000, gainDb: 2)],
            sampleRate: sampleRate)!
        XCTAssertLessThanOrEqual(eq.effectivePreampDb, -6)
        XCTAssertGreaterThan(eq.effectivePreampDb, -7, "preamp should be near the peak, not stacked")
        let g = gain(of: eq, at: 1000)
        XCTAssertLessThanOrEqual(g, 1.005, "boosted center must not exceed unity after preamp")
        XCTAssertGreaterThan(g, 0.88, "preamp should not be grossly over-conservative")
    }

    func testAutoPreampCoversOverlappingBoosts() {
        // Two overlapping +6 dB bands cascade to ~+11 dB between them; the
        // auto preamp must cover the measured combined peak, not just the
        // single largest band.
        let eq = Equalizer(
            bands: [EqBand(freqHz: 1000, gainDb: 6), EqBand(freqHz: 1200, gainDb: 6)],
            sampleRate: sampleRate)!
        for freq in [1000.0, 1094.0, 1200.0] {
            let g = gain(of: eq, at: freq)
            XCTAssertLessThanOrEqual(
                g, 1.005, "full-scale \(freq) Hz must not clip (measured \(g))")
        }
    }

    func testOutputStaysFiniteForHugeFiniteInput() {
        // A finite-but-enormous sample overflows Float inside a boosted
        // biquad; the output must still be sanitized.
        let eq = Equalizer(
            bands: [EqBand(freqHz: 1000, gainDb: 24)], sampleRate: sampleRate, preampDb: 0)!
        let n = 512
        var left: [Float] = (0..<n).map { _ in 0.1 }
        left[10] = 3e38
        var right = left
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                eq.process(left: l.baseAddress!, right: r.baseAddress!, frames: n)
            }
        }
        XCTAssertTrue(left.allSatisfy(\.isFinite), "overflow inside the filter must not escape")
        let g = gain(of: eq, at: 1000)
        XCTAssertGreaterThan(g, 1.0, "state should recover in the next buffer")
    }

    func testAutoPreampIsZeroWithoutBoosts() {
        let eq = Equalizer(
            bands: [EqBand(freqHz: 1000, gainDb: -4)], sampleRate: sampleRate)!
        XCTAssertEqual(eq.effectivePreampDb, 0, accuracy: 1e-5)
    }

    func testEmptyBandsIsPassthrough() {
        let eq = Equalizer(bands: [], sampleRate: sampleRate)!
        let n = 512
        var left = (0..<n).map { _ in Float.random(in: -1...1) }
        var right = (0..<n).map { _ in Float.random(in: -1...1) }
        let expectedL = left
        let expectedR = right
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                eq.process(left: l.baseAddress!, right: r.baseAddress!, frames: n)
            }
        }
        XCTAssertEqual(left, expectedL)
        XCTAssertEqual(right, expectedR)
    }

    func testChunkedMatchesSinglePass() {
        let n = 4096
        let src = sine(freq: 700, frames: n)

        func run(_ eq: Equalizer, _ chunks: [Range<Int>]) -> [Float] {
            var left = src
            var right = src
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    for c in chunks {
                        eq.process(
                            left: l.baseAddress! + c.lowerBound,
                            right: r.baseAddress! + c.lowerBound,
                            frames: c.count)
                    }
                }
            }
            return left
        }

        let bands = [EqBand(freqHz: 700, gainDb: 5), EqBand(freqHz: 3000, gainDb: -3)]
        let single = run(Equalizer(bands: bands, sampleRate: sampleRate)!, [0..<n])
        let chunked = run(Equalizer(bands: bands, sampleRate: sampleRate)!, [0..<(n/2), (n/2)..<n])
        for i in 0..<n {
            XCTAssertEqual(chunked[i], single[i], accuracy: 1e-6, "sample \(i) differs")
        }
    }

    func testRecoversFromNonFiniteInput() {
        let eq = Equalizer(
            bands: [EqBand(freqHz: 1000, gainDb: 6)], sampleRate: sampleRate, preampDb: 0)!
        let n = 512
        var left: [Float] = (0..<n).map { _ in 0.5 }
        left[7] = .nan
        left[99] = .infinity
        var right = left
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                eq.process(left: l.baseAddress!, right: r.baseAddress!, frames: n)
            }
        }
        XCTAssertTrue(left.allSatisfy(\.isFinite), "non-finite input must not reach the output")

        // State must not stay poisoned.
        let g = gain(of: eq, at: 1000)
        XCTAssertEqual(g, 2.0, accuracy: 0.1, "filter state should recover after garbage input")
    }

    func testRejectsInvalidBands() {
        XCTAssertNil(EqBand(freqHz: 0, gainDb: 3).validated(sampleRate: sampleRate))
        XCTAssertNil(EqBand(freqHz: 5, gainDb: 3).validated(sampleRate: sampleRate),
                     "sub-10Hz should be rejected for pole-stability margin")
        XCTAssertNil(EqBand(freqHz: 22_000, gainDb: 3).validated(sampleRate: sampleRate),
                     "frequencies above 0.45*sr should be rejected for stability margin")
        XCTAssertNotNil(EqBand(freqHz: 21_000, gainDb: 3).validated(sampleRate: sampleRate))
        XCTAssertNil(EqBand(freqHz: 30_000, gainDb: 3).validated(sampleRate: sampleRate))
        XCTAssertNil(EqBand(freqHz: 1000, gainDb: 30).validated(sampleRate: sampleRate))
        XCTAssertNil(EqBand(freqHz: 1000, gainDb: .nan).validated(sampleRate: sampleRate))
        XCTAssertNil(EqBand(freqHz: 1000, gainDb: 3, q: 0).validated(sampleRate: sampleRate))
        XCTAssertNotNil(EqBand(freqHz: 1000, gainDb: 3).validated(sampleRate: sampleRate))
        XCTAssertNil(Equalizer(bands: [EqBand(freqHz: 0, gainDb: 1)], sampleRate: sampleRate))
    }
}
