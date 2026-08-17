import XCTest
@testable import UpmixCore

final class UpmixerTests: XCTestCase {
    private func upmix(
        _ upmixer: Upmixer, left: [Float], right: [Float]
    ) -> [[Float]] {
        let frames = left.count
        var outs = [[Float]](repeating: [], count: 6)
        let raw = (0..<6).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: frames) }
        defer { raw.forEach { $0.deallocate() } }
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                upmixer.process(left: l.baseAddress!, right: r.baseAddress!, frames: frames, outputs: raw)
            }
        }
        for i in 0..<6 {
            outs[i] = Array(UnsafeBufferPointer(start: raw[i], count: frames))
        }
        return outs
    }

    private func sine(freq: Double, sampleRate: Double, frames: Int) -> [Float] {
        (0..<frames).map { Float(sin(2.0 * .pi * freq * Double($0) / sampleRate)) }
    }

    private func rms(_ x: ArraySlice<Float>) -> Float {
        sqrt(x.map { $0 * $0 }.reduce(0, +) / Float(x.count))
    }

    func testFrontChannelsPassThroughUnchanged() {
        let n = 512
        let left = (0..<n).map { _ in Float.random(in: -1...1) }
        let right = (0..<n).map { _ in Float.random(in: -1...1) }
        let outs = upmix(Upmixer(), left: left, right: right)
        XCTAssertEqual(outs[OutputChannel.frontLeft.rawValue], left)
        XCTAssertEqual(outs[OutputChannel.frontRight.rawValue], right)
    }

    func testCenterIsScaledSumOfFronts() {
        let n = 512
        let left = (0..<n).map { _ in Float.random(in: -1...1) }
        let right = (0..<n).map { _ in Float.random(in: -1...1) }
        let config = UpmixConfig()
        let outs = upmix(Upmixer(config: config), left: left, right: right)
        let center = outs[OutputChannel.center.rawValue]
        for i in 0..<n {
            XCTAssertEqual(center[i], config.centerGain * (left[i] + right[i]), accuracy: 1e-5)
        }
    }

    func testRearsAreDelayedAttenuatedFronts() {
        let config = UpmixConfig()
        let delaySamples = Int(config.rearDelayMs / 1000.0 * config.sampleRate)
        let n = delaySamples + 64
        var left = [Float](repeating: 0, count: n)
        left[0] = 1
        let right = [Float](repeating: 0, count: n)

        let outs = upmix(Upmixer(config: config), left: left, right: right)
        let rearLeft = outs[OutputChannel.rearLeft.rawValue]
        let rearRight = outs[OutputChannel.rearRight.rawValue]

        XCTAssertEqual(rearLeft[delaySamples], config.rearGain, accuracy: 1e-5)
        for i in 0..<n where i != delaySamples {
            XCTAssertEqual(rearLeft[i], 0, accuracy: 1e-6, "rearLeft[\(i)] should be silent")
        }
        for i in 0..<n {
            XCTAssertEqual(rearRight[i], 0, accuracy: 1e-6, "rearRight[\(i)] should be silent")
        }
    }

    func testLfePassesLowFrequencies() {
        let config = UpmixConfig()
        let n = 9600
        let low = sine(freq: 40, sampleRate: config.sampleRate, frames: n)
        let outs = upmix(Upmixer(config: config), left: low, right: low)
        let lfe = outs[OutputChannel.lfe.rawValue]
        // Steady state only: compare the second half. Input to the filter is
        // lfeGain * (L+R) = 2 * lfeGain * sine.
        let inputRMS = rms(low[(n/2)...]) * 2 * config.lfeGain
        let ratio = rms(lfe[(n/2)...]) / inputRMS
        XCTAssertGreaterThan(ratio, 0.9, "40 Hz should pass the \(config.lfeCutoffHz) Hz low-pass")
    }

    func testLfeAttenuatesHighFrequencies() {
        let config = UpmixConfig()
        let n = 9600
        let high = sine(freq: 5000, sampleRate: config.sampleRate, frames: n)
        let outs = upmix(Upmixer(config: config), left: high, right: high)
        let lfe = outs[OutputChannel.lfe.rawValue]
        let inputRMS = rms(high[(n/2)...]) * 2 * config.lfeGain
        let ratio = rms(lfe[(n/2)...]) / inputRMS
        XCTAssertLessThan(ratio, 0.05, "5 kHz should be strongly attenuated by the LFE low-pass")
    }

    func testChunkedProcessingMatchesSinglePass() {
        let config = UpmixConfig()
        let n = 4096
        let left = sine(freq: 300, sampleRate: config.sampleRate, frames: n)
        let right = sine(freq: 80, sampleRate: config.sampleRate, frames: n)

        let single = upmix(Upmixer(config: config), left: left, right: right)

        let chunked = Upmixer(config: config)
        let firstHalf = upmix(chunked, left: Array(left[..<(n / 2)]), right: Array(right[..<(n / 2)]))
        let secondHalf = upmix(chunked, left: Array(left[(n / 2)...]), right: Array(right[(n / 2)...]))

        for ch in 0..<6 {
            let stitched = firstHalf[ch] + secondHalf[ch]
            for i in 0..<n {
                XCTAssertEqual(stitched[i], single[ch][i], accuracy: 1e-6,
                               "channel \(ch) sample \(i) differs between chunked and single-pass")
            }
        }
    }

    func testRecoversFromNonFiniteInput() {
        let config = UpmixConfig()
        let upmixer = Upmixer(config: config)
        let n = 512

        var poisoned = [Float](repeating: 0.5, count: n)
        poisoned[10] = .nan
        poisoned[20] = .infinity
        let dirty = upmix(upmixer, left: poisoned, right: poisoned)
        for ch in 0..<6 {
            XCTAssertTrue(dirty[ch].allSatisfy(\.isFinite),
                          "channel \(ch) leaked non-finite samples to the DAC")
        }

        let clean = sine(freq: 40, sampleRate: config.sampleRate, frames: n)
        let outs = upmix(upmixer, left: clean, right: clean)
        for ch in 0..<6 {
            XCTAssertTrue(outs[ch].allSatisfy(\.isFinite),
                          "channel \(ch) still non-finite after clean input")
        }
        // The LFE filter state must not stay poisoned: after a clean buffer
        // it should produce signal again, not silence or NaN.
        XCTAssertGreaterThan(rms(outs[OutputChannel.lfe.rawValue][(n/2)...]), 0.01)
    }

    func testLfeStaysWithinFullScaleForFullScaleBass() {
        // Worst case for the low-pass overshoot: full-scale correlated
        // low-frequency square wave.
        let config = UpmixConfig()
        let n = 19200
        let period = Int(config.sampleRate / 50)
        let square: [Float] = (0..<n).map { ($0 / (period / 2)) % 2 == 0 ? 1.0 : -1.0 }
        let outs = upmix(Upmixer(config: config), left: square, right: square)
        let peak = outs[OutputChannel.lfe.rawValue].map(abs).max()!
        XCTAssertLessThanOrEqual(peak, 1.0, "LFE must not exceed full scale (would clip in the DAC)")
    }

    func testOutputStaysFiniteForHugeFiniteInput() {
        // Two huge-but-finite samples overflow their sum to infinity inside
        // the derived channels; the outputs must still be sanitized.
        let upmixer = Upmixer(config: UpmixConfig())
        let n = 512
        var left = [Float](repeating: 0.1, count: n)
        left[9] = 3e38
        let outs = upmix(upmixer, left: left, right: left)
        for ch in [OutputChannel.center, .lfe, .rearLeft, .rearRight] {
            XCTAssertTrue(outs[ch.rawValue].allSatisfy(\.isFinite),
                          "channel \(ch) leaked non-finite samples")
        }
    }

    func testRejectsInvalidConfig() {
        // Cutoff at/above Nyquist must be rejected up front rather than
        // producing an unstable filter.
        XCTAssertNil(UpmixConfig(sampleRate: 22_050, lfeCutoffHz: 12_000).validated())
        XCTAssertNil(UpmixConfig(sampleRate: 0).validated())
        XCTAssertNil(UpmixConfig(rearDelayMs: 0).validated())
        // Screening must reject, never trap, on pathological values.
        XCTAssertNil(UpmixConfig(sampleRate: .infinity).validated())
        XCTAssertNil(UpmixConfig(rearDelayMs: .infinity).validated())
        XCTAssertNil(UpmixConfig(rearDelayMs: 1e300).validated())
        // Absurd rates must fail screening: init derives delay capacity from
        // the rate, so a "validated" 1e12 Hz config would try to allocate
        // gigabytes (or overflow the Int conversion outright).
        XCTAssertNil(UpmixConfig(sampleRate: 1e12, rearDelayMs: 1e-5).validated())
        XCTAssertNotNil(UpmixConfig(sampleRate: 192_000).validated())
        XCTAssertNil(UpmixConfig(centerGain: .nan).validated())
        XCTAssertNil(UpmixConfig(lfeGain: .infinity).validated())
        XCTAssertNotNil(UpmixConfig().validated())
    }

    func testInPlaceOutputAliasingFrontBuffers() {
        // The daemon reuses the input buffers for FL/FR; make sure processing
        // other channels doesn't read fronts after they've been overwritten.
        let config = UpmixConfig()
        let n = 256
        let left = (0..<n).map { _ in Float.random(in: -1...1) }
        let right = (0..<n).map { _ in Float.random(in: -1...1) }
        let expected = upmix(Upmixer(config: config), left: left, right: right)

        var lbuf = left
        var rbuf = right
        let extra = (0..<4).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: n) }
        defer { extra.forEach { $0.deallocate() } }
        lbuf.withUnsafeMutableBufferPointer { l in
            rbuf.withUnsafeMutableBufferPointer { r in
                let outs = [l.baseAddress!, r.baseAddress!] + extra
                Upmixer(config: config).process(
                    left: l.baseAddress!, right: r.baseAddress!, frames: n, outputs: outs)
            }
        }
        XCTAssertEqual(lbuf, expected[0])
        XCTAssertEqual(rbuf, expected[1])
        for ch in 2..<6 {
            let got = Array(UnsafeBufferPointer(start: extra[ch - 2], count: n))
            for i in 0..<n {
                XCTAssertEqual(got[i], expected[ch][i], accuracy: 1e-6,
                               "aliased channel \(ch) sample \(i) differs")
            }
        }
    }
}
