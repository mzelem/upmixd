import XCTest
@testable import UpmixCore

final class LiveApplyTests: XCTestCase {
    private let sampleRate = 48_000.0

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

    func testUpmixerAppliesGainChangesLive() {
        let upmixer = Upmixer(config: UpmixConfig())
        // Longer than the rear delay (1200 samples) so both buffers together
        // put the delay line fully into steady state.
        let n = 2048
        let ones = [Float](repeating: 1, count: n)
        _ = upmix(upmixer, left: ones, right: ones)

        var newConfig = UpmixConfig()
        newConfig.centerGain = 0.1
        newConfig.rearGain = 0.2
        XCTAssertTrue(upmixer.apply(newConfig))

        let outs = upmix(upmixer, left: ones, right: ones)
        XCTAssertEqual(outs[OutputChannel.center.rawValue][n - 1], 0.1 * 2, accuracy: 1e-5)
        // Rears are delayed past the first buffer's constant fill by now, so
        // steady-state rear output is rearGain * 1.
        XCTAssertEqual(outs[OutputChannel.rearLeft.rawValue][n - 1], 0.2, accuracy: 1e-5)
    }

    func testUpmixerAppliesDelayChangeLive() {
        let upmixer = Upmixer(config: UpmixConfig())
        var newConfig = UpmixConfig()
        newConfig.rearDelayMs = 10
        XCTAssertTrue(upmixer.apply(newConfig))

        let delaySamples = Int(10.0 / 1000.0 * sampleRate)
        let n = delaySamples + 64
        var left = [Float](repeating: 0, count: n)
        left[0] = 1
        let outs = upmix(upmixer, left: left, right: [Float](repeating: 0, count: n))
        XCTAssertEqual(
            outs[OutputChannel.rearLeft.rawValue][delaySamples],
            newConfig.rearGain, accuracy: 1e-5,
            "impulse should appear at the NEW delay offset")
    }

    func testUpmixerRejectsDelayBeyondCapacity() {
        let upmixer = Upmixer(config: UpmixConfig())
        var newConfig = UpmixConfig()
        newConfig.rearDelayMs = 5000
        XCTAssertFalse(upmixer.apply(newConfig))
    }

    private func eqGain(_ eq: Equalizer, at freq: Double) -> Float {
        let n = 19200
        var left: [Float] = (0..<n).map { Float(sin(2.0 * .pi * freq * Double($0) / sampleRate)) }
        var right = left
        let input = sqrt(left[(n/2)...].map { $0 * $0 }.reduce(0, +) / Float(n / 2))
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                eq.process(left: l.baseAddress!, right: r.baseAddress!, frames: n)
            }
        }
        let output = sqrt(left[(n/2)...].map { $0 * $0 }.reduce(0, +) / Float(n / 2))
        return output / input
    }

    func testEqualizerAppliesBandsLive() {
        let eq = Equalizer(bands: [], sampleRate: sampleRate)!
        XCTAssertEqual(eqGain(eq, at: 1000), 1.0, accuracy: 0.02)

        XCTAssertTrue(eq.apply(bands: [EqBand(freqHz: 1000, gainDb: 6)], preampDb: 0))
        XCTAssertEqual(eqGain(eq, at: 1000), 2.0, accuracy: 0.1)

        // Back to fewer (zero) bands.
        XCTAssertTrue(eq.apply(bands: [], preampDb: 0))
        XCTAssertEqual(eqGain(eq, at: 1000), 1.0, accuracy: 0.02)
    }

    func testEqualizerApplyUsesAutoPreamp() {
        let eq = Equalizer(bands: [], sampleRate: sampleRate)!
        XCTAssertTrue(eq.apply(bands: [EqBand(freqHz: 1000, gainDb: 6)], preampDb: nil))
        XCTAssertEqual(eq.effectivePreampDb, -6, accuracy: 1e-5)
        XCTAssertEqual(eqGain(eq, at: 1000), 1.0, accuracy: 0.06)
    }

    func testEqualizerApplyRejectsInvalid() {
        let eq = Equalizer(bands: [EqBand(freqHz: 500, gainDb: 3)], sampleRate: sampleRate)!
        let before = eqGain(eq, at: 500)

        let tooMany = (0..<17).map { EqBand(freqHz: 100 + Double($0) * 100, gainDb: 1) }
        XCTAssertFalse(eq.apply(bands: tooMany, preampDb: 0))
        XCTAssertFalse(eq.apply(bands: [EqBand(freqHz: 0, gainDb: 1)], preampDb: 0))
        XCTAssertFalse(eq.apply(bands: [EqBand(freqHz: 500, gainDb: 3)], preampDb: 5))

        XCTAssertEqual(eqGain(eq, at: 500), before, accuracy: 0.02,
                       "rejected apply must leave the response unchanged")
    }
}
