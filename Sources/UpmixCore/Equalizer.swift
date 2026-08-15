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
    /// otherwise. Never traps. The frequency bounds ([10 Hz, 0.45*sr]) keep
    /// the pole pair off the unit circle with margin at both DC and Nyquist.
    public func validated(sampleRate: Double) -> EqBand? {
        guard sampleRate.isFinite, sampleRate > 0,
              freqHz.isFinite, freqHz >= 10, freqHz <= 0.45 * sampleRate,
              gainDb.isFinite, abs(gainDb) <= 24,
              q.isFinite, q >= 0.1, q <= 18
        else { return nil }
        return self
    }
}

/// RBJ peaking coefficients in Double precision, shared by the filter and
/// the cascade-response measurement.
func peakingCoefficients(
    _ band: EqBand, sampleRate: Double
) -> (b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
    let amp = pow(10.0, Double(band.gainDb) / 40.0)
    let omega = 2.0 * Double.pi * band.freqHz / sampleRate
    let cosw = cos(omega)
    let alpha = sin(omega) / (2.0 * band.q)
    let a0 = 1.0 + alpha / amp
    return (
        b0: (1.0 + alpha * amp) / a0,
        b1: (-2.0 * cosw) / a0,
        b2: (1.0 - alpha * amp) / a0,
        a1: (-2.0 * cosw) / a0,
        a2: (1.0 - alpha / amp) / a0
    )
}

/// RBJ peaking-EQ biquad (transposed direct form II), same topology and
/// state discipline as BiquadLowpass.
struct BiquadPeaking {
    private let b0, b1, b2, a1, a2: Float
    private var z1: Float = 0
    private var z2: Float = 0

    init(band: EqBand, sampleRate: Double) {
        let c = peakingCoefficients(band, sampleRate: sampleRate)
        b0 = Float(c.b0)
        b1 = Float(c.b1)
        b2 = Float(c.b2)
        a1 = Float(c.a1)
        a2 = Float(c.a2)
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

    /// `preampDb` nil selects automatic headroom: -(measured worst-case
    /// cascade boost), so full-scale input cannot clip at any frequency even
    /// when boosted bands overlap. Returns nil for invalid bands or preamp
    /// (never traps).
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

        effectivePreampDb = preampDb
            ?? -Self.cascadeMaxBoostDb(bands: newBands, sampleRate: sampleRate)
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
            // A finite-but-enormous sample can overflow inside a boosted
            // biquad; nothing non-finite may leave this module. (Poisoned
            // filter state self-clears at the end-of-buffer flush.)
            left[i] = l.isFinite ? l : 0
            right[i] = r.isFinite ? r : 0
        }
        for b in 0..<activeBands {
            leftChain[b].flushState()
            rightChain[b].flushState()
        }
    }

    /// Worst-case combined boost of the cascade in dB, measured on a log
    /// frequency grid (dense enough for the narrowest permitted band) plus a
    /// small margin for grid interpolation error. Overlapping boosted bands
    /// multiply, so this — not the largest single band — is what the auto
    /// preamp must compensate. Allocation-free; callable from apply().
    static func cascadeMaxBoostDb(bands: [EqBand], sampleRate: Double) -> Float {
        guard !bands.isEmpty else { return 0 }
        let points = 512
        let fMin = 10.0
        let fMax = 0.45 * sampleRate
        let logStep = log(fMax / fMin) / Double(points - 1)
        var maxDb = 0.0
        for k in 0..<points {
            let freq = fMin * exp(Double(k) * logStep)
            let omega = 2.0 * Double.pi * freq / sampleRate
            let c1 = cos(omega), s1 = sin(omega)
            let c2 = cos(2 * omega), s2 = sin(2 * omega)
            var db = 0.0
            for band in bands {
                let co = peakingCoefficients(band, sampleRate: sampleRate)
                let numRe = co.b0 + co.b1 * c1 + co.b2 * c2
                let numIm = -(co.b1 * s1 + co.b2 * s2)
                let denRe = 1.0 + co.a1 * c1 + co.a2 * c2
                let denIm = -(co.a1 * s1 + co.a2 * s2)
                let mag2 = (numRe * numRe + numIm * numIm) / (denRe * denRe + denIm * denIm)
                db += 10.0 * log10(mag2)
            }
            maxDb = max(maxDb, db)
        }
        return maxDb > 0 ? Float(maxDb) + 0.25 : 0
    }
}
