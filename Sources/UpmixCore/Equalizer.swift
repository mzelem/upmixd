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
    public static let maxBands = 16

    public private(set) var bands: [EqBand]
    public private(set) var effectivePreampDb: Float

    private let sampleRate: Double
    private var preampLinear: Float
    private var activeBands: Int
    // Fixed-size chains; slots beyond activeBands are never processed.
    private var leftChain: [BiquadPeaking]
    private var rightChain: [BiquadPeaking]

    /// `preampDb` nil selects automatic headroom: -(max positive band gain),
    /// so full-scale input cannot clip at any band's center frequency.
    /// Returns nil for invalid bands or preamp (never traps).
    public init?(bands: [EqBand], sampleRate: Double, preampDb: Float? = nil) {
        guard sampleRate.isFinite, sampleRate > 0 else { return nil }
        self.sampleRate = sampleRate
        self.bands = []
        effectivePreampDb = 0
        preampLinear = 1
        activeBands = 0
        let placeholder = BiquadPeaking(
            band: EqBand(freqHz: 1000, gainDb: 0), sampleRate: sampleRate)
        leftChain = [BiquadPeaking](repeating: placeholder, count: Self.maxBands)
        rightChain = leftChain
        guard apply(bands: bands, preampDb: preampDb) else { return nil }
    }

    /// Real-time-safe live update: validates, then rewrites coefficients in
    /// place (filter state resets — a brief transient, not a glitch loop).
    /// Returns false — changing nothing — on invalid input.
    public func apply(bands newBands: [EqBand], preampDb: Float?) -> Bool {
        guard newBands.count <= Self.maxBands else { return false }
        for band in newBands {
            guard band.validated(sampleRate: sampleRate) != nil else { return false }
        }
        if let preampDb {
            guard preampDb.isFinite, preampDb <= 0, preampDb >= -60 else { return false }
        }

        var maxBoost: Float = 0
        for band in newBands {
            maxBoost = max(maxBoost, band.gainDb)
        }
        effectivePreampDb = preampDb ?? -maxBoost
        preampLinear = pow(10, effectivePreampDb / 20)
        for (i, band) in newBands.enumerated() {
            leftChain[i] = BiquadPeaking(band: band, sampleRate: sampleRate)
            rightChain[i] = BiquadPeaking(band: band, sampleRate: sampleRate)
        }
        activeBands = newBands.count
        bands = newBands
        return true
    }

    public func process(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frames: Int
    ) {
        for i in 0..<frames {
            var l = left[i].isFinite ? left[i] * preampLinear : 0
            var r = right[i].isFinite ? right[i] * preampLinear : 0
            for b in 0..<activeBands {
                l = leftChain[b].process(l)
                r = rightChain[b].process(r)
            }
            left[i] = l
            right[i] = r
        }
        for b in 0..<activeBands {
            leftChain[b].flushState()
            rightChain[b].flushState()
        }
    }
}
