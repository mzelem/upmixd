import Foundation

/// Output channel order matches the CM6206's 6-channel alt setting: FL FR FC LFE RL RR.
public enum OutputChannel: Int, CaseIterable {
    case frontLeft = 0
    case frontRight = 1
    case center = 2
    case lfe = 3
    case rearLeft = 4
    case rearRight = 5
}

public struct UpmixConfig {
    public var sampleRate: Double
    /// Gain applied to (L+R) for the center channel.
    public var centerGain: Float
    /// Low-pass cutoff for the subwoofer feed.
    public var lfeCutoffHz: Double
    /// Gain applied to (L+R) before the LFE low-pass.
    public var lfeGain: Float
    /// Rear channels are delayed copies of the fronts ("speaker fill").
    public var rearDelayMs: Double
    public var rearGain: Float

    public init(
        sampleRate: Double = 48_000,
        centerGain: Float = 0.354,
        lfeCutoffHz: Double = 120,
        // 0.45 keeps the low-pass overshoot (~1.09x on full-scale correlated
        // bass) under full scale: 2 * 0.45 * 1.09 ≈ 0.98.
        lfeGain: Float = 0.45,
        // 25ms/0.9 chosen by ear on the 5.1 rig: 15ms/0.7 read as too subtle,
        // the longer delay makes the rears register as their own presence.
        rearDelayMs: Double = 25,
        rearGain: Float = 0.9
    ) {
        self.sampleRate = sampleRate
        self.centerGain = centerGain
        self.lfeCutoffHz = lfeCutoffHz
        self.lfeGain = lfeGain
        self.rearDelayMs = rearDelayMs
        self.rearGain = rearGain
    }

    /// Returns self if the config produces a stable, meaningful processor;
    /// nil otherwise (non-finite fields, cutoff at/above Nyquist,
    /// non-positive rate/delay, absurd delay length). Never traps.
    public func validated() -> UpmixConfig? {
        guard sampleRate.isFinite, sampleRate > 0,
              lfeCutoffHz.isFinite, lfeCutoffHz > 0, lfeCutoffHz < sampleRate / 2,
              centerGain.isFinite, lfeGain.isFinite, rearGain.isFinite,
              rearDelayMs.isFinite, rearDelayMs > 0
        else { return nil }
        let delaySamples = rearDelayMs / 1000.0 * sampleRate
        guard delaySamples >= 1, delaySamples <= 10_000_000 else { return nil }
        return self
    }
}

/// Second-order Butterworth low-pass (transposed direct form II).
struct BiquadLowpass {
    private let b0, b1, b2, a1, a2: Float
    private var z1: Float = 0
    private var z2: Float = 0

    init(cutoffHz: Double, sampleRate: Double) {
        let omega = 2.0 * Double.pi * cutoffHz / sampleRate
        let cosw = cos(omega)
        let alpha = sin(omega) / (2.0 * 0.70710678) // Q = 1/sqrt(2)
        let a0 = 1.0 + alpha
        b0 = Float(((1.0 - cosw) / 2.0) / a0)
        b1 = Float((1.0 - cosw) / a0)
        b2 = Float(((1.0 - cosw) / 2.0) / a0)
        a1 = Float((-2.0 * cosw) / a0)
        a2 = Float((1.0 - alpha) / a0)
    }

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    /// Flush pathological state: denormals (expensive on Intel) and any
    /// non-finite values that would otherwise persist forever in the IIR.
    mutating func flushState() {
        if !z1.isFinite || !z2.isFinite {
            z1 = 0
            z2 = 0
            return
        }
        if abs(z1) < .leastNormalMagnitude { z1 = 0 }
        if abs(z2) < .leastNormalMagnitude { z2 = 0 }
    }
}

/// Fixed-length delay line backed by a ring buffer.
struct DelayLine {
    private var buffer: [Float]
    private var index = 0

    init(delaySamples: Int) {
        precondition(delaySamples > 0)
        buffer = [Float](repeating: 0, count: delaySamples)
    }

    mutating func process(_ x: Float) -> Float {
        let y = buffer[index]
        buffer[index] = x
        index += 1
        if index == buffer.count { index = 0 }
        return y
    }
}

/// Stereo → 5.1 upmixer. Stateful (LFE filter, rear delay lines); call
/// `process` with consecutive buffers of the same stream.
public final class Upmixer {
    public let config: UpmixConfig
    private var lfeFilter: BiquadLowpass
    private var rearLeftDelay: DelayLine
    private var rearRightDelay: DelayLine

    public init(config rawConfig: UpmixConfig = UpmixConfig()) {
        guard let config = rawConfig.validated() else {
            preconditionFailure("invalid UpmixConfig: \(rawConfig)")
        }
        self.config = config
        lfeFilter = BiquadLowpass(cutoffHz: config.lfeCutoffHz, sampleRate: config.sampleRate)
        let delaySamples = Int(config.rearDelayMs / 1000.0 * config.sampleRate)
        rearLeftDelay = DelayLine(delaySamples: delaySamples)
        rearRightDelay = DelayLine(delaySamples: delaySamples)
    }

    /// Upmix `frames` samples of deinterleaved stereo into six output buffers
    /// (ordered per `OutputChannel`). Each output must hold at least `frames`.
    /// Aliasing contract: only FL may alias `left` and only FR may alias
    /// `right` — any other overlap between outputs and inputs corrupts data.
    /// Non-finite input samples are treated as silence.
    public func process(
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        frames: Int,
        outputs: [UnsafeMutablePointer<Float>]
    ) {
        precondition(outputs.count == OutputChannel.allCases.count)
        let center = outputs[OutputChannel.center.rawValue]
        let lfe = outputs[OutputChannel.lfe.rawValue]
        let rearL = outputs[OutputChannel.rearLeft.rawValue]
        let rearR = outputs[OutputChannel.rearRight.rawValue]

        // Derived channels first: FL/FR outputs may alias the inputs, so the
        // fronts are written last.
        for i in 0..<frames {
            let l = left[i].isFinite ? left[i] : 0
            let r = right[i].isFinite ? right[i] : 0
            let sum = l + r
            center[i] = config.centerGain * sum
            lfe[i] = lfeFilter.process(config.lfeGain * sum)
            rearL[i] = config.rearGain * rearLeftDelay.process(l)
            rearR[i] = config.rearGain * rearRightDelay.process(r)
        }
        lfeFilter.flushState()

        // Sanitized copy (works in place when FL/FR alias the inputs).
        let frontL = outputs[OutputChannel.frontLeft.rawValue]
        let frontR = outputs[OutputChannel.frontRight.rawValue]
        for i in 0..<frames {
            frontL[i] = left[i].isFinite ? left[i] : 0
            frontR[i] = right[i].isFinite ? right[i] : 0
        }
    }
}
