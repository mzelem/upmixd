import Foundation

/// One peaking-EQ band. Q defaults to ~1.41, the conventional width for a
/// 10-band (one-octave) graphic equalizer.
public struct EqBand: Equatable {
    public var freqHz: Double
    public var gainDb: Float
    public var q: Double

    public init(freqHz: Double, gainDb: Float, q: Double = 1.41) {
        self.freqHz = freqHz
        self.gainDb = gainDb
        self.q = q
    }

    /// Returns self if the band is usable at the given sample rate; nil
    /// otherwise. Never traps.
    public func validated(sampleRate: Double) -> EqBand? {
        guard sampleRate.isFinite, sampleRate > 0,
              freqHz.isFinite, freqHz > 0, freqHz < sampleRate / 2,
              gainDb.isFinite, abs(gainDb) <= 24,
              q.isFinite, q >= 0.1, q <= 18
        else { return nil }
        return self
    }
}

/// RBJ peaking-EQ biquad (transposed direct form II), same topology and
/// state discipline as BiquadLowpass.
struct BiquadPeaking {
    private let b0, b1, b2, a1, a2: Float
    private var z1: Float = 0
    private var z2: Float = 0

    init(band: EqBand, sampleRate: Double) {
        let amp = pow(10.0, Double(band.gainDb) / 40.0)
        let omega = 2.0 * Double.pi * band.freqHz / sampleRate
        let cosw = cos(omega)
        let alpha = sin(omega) / (2.0 * band.q)
        let a0 = 1.0 + alpha / amp
        b0 = Float((1.0 + alpha * amp) / a0)
        b1 = Float((-2.0 * cosw) / a0)
        b2 = Float((1.0 - alpha * amp) / a0)
        a1 = Float((-2.0 * cosw) / a0)
        a2 = Float((1.0 - alpha / amp) / a0)
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

/// Stereo peaking equalizer applied in place. Stateful; call `process` with
/// consecutive buffers of the same stream. Real-time safe: no allocation,
/// locks, or ObjC in `process`. Non-finite input samples are treated as
/// silence.
public final class Equalizer {
    public let bands: [EqBand]
    public let effectivePreampDb: Float

    private let preampLinear: Float
    private var leftChain: [BiquadPeaking]
    private var rightChain: [BiquadPeaking]

    /// `preampDb` nil selects automatic headroom: -(max positive band gain),
    /// so full-scale input cannot clip at any band's center frequency.
    /// Returns nil for invalid bands or preamp (never traps).
    public init?(bands: [EqBand], sampleRate: Double, preampDb: Float? = nil) {
        var validatedBands: [EqBand] = []
        for band in bands {
            guard let valid = band.validated(sampleRate: sampleRate) else { return nil }
            validatedBands.append(valid)
        }
        if let preampDb {
            guard preampDb.isFinite, preampDb <= 0, preampDb >= -60 else { return nil }
            effectivePreampDb = preampDb
        } else {
            let maxBoost = validatedBands.map(\.gainDb).max() ?? 0
            effectivePreampDb = -max(0, maxBoost)
        }
        self.bands = validatedBands
        preampLinear = pow(10, effectivePreampDb / 20)
        leftChain = validatedBands.map { BiquadPeaking(band: $0, sampleRate: sampleRate) }
        rightChain = validatedBands.map { BiquadPeaking(band: $0, sampleRate: sampleRate) }
    }

    public func process(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frames: Int
    ) {
        let bandCount = leftChain.count
        for i in 0..<frames {
            var l = left[i].isFinite ? left[i] * preampLinear : 0
            var r = right[i].isFinite ? right[i] * preampLinear : 0
            for b in 0..<bandCount {
                l = leftChain[b].process(l)
                r = rightChain[b].process(r)
            }
            left[i] = l
            right[i] = r
        }
        for b in 0..<bandCount {
            leftChain[b].flushState()
            rightChain[b].flushState()
        }
    }
}
