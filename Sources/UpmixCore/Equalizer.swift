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

    /// Introspection only (copies); never called on the render thread.
    public var bands: [EqBand] { Array(bandStorage) }
    public private(set) var effectivePreampDb: Float

    // Preallocated and mutated with keepingCapacity so apply() — which runs
    // on the render thread — never frees or allocates heap. Private and
    // uniquely referenced, so no copy-on-write can trigger either.
    private var bandStorage: ContiguousArray<EqBand>

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
        bandStorage = []
        bandStorage.reserveCapacity(Self.maxBands)
        effectivePreampDb = 0
        preampLinear = 1
        activeBands = 0
        let placeholder = BiquadPeaking(
            band: EqBand(freqHz: 1000, gainDb: 0), sampleRate: sampleRate)
        leftChain = [BiquadPeaking](repeating: placeholder, count: Self.maxBands)
        rightChain = leftChain
        guard apply(bands: bands, preampDb: preampDb) else { return nil }
    }

    /// Live update: validates, then rewrites coefficients in place (filter
    /// state resets — a brief transient, not a glitch loop). Returns false —
    /// changing nothing — on invalid input.
    ///
    /// Real-time safety: with an EXPLICIT preampDb this is allocation-free
    /// and render-thread safe. With nil (auto), the cascade measurement runs
    /// and may allocate — resolve auto to a number off the render thread
    /// first (see Engine.submit).
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
        bandStorage.removeAll(keepingCapacity: true)
        bandStorage.append(contentsOf: newBands)
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
            // Hard-clamp at full scale: the downstream upmixer's no-clip
            // math assumes |input| <= 1, and the clamp is the guarantee that
            // holds even for configs beyond the preamp measurement's
            // accuracy. Also drops non-finite values (overflow inside a
            // boosted biquad); poisoned filter state self-clears at the
            // end-of-buffer flush.
            left[i] = l.isFinite ? min(max(l, -1), 1) : 0
            right[i] = r.isFinite ? min(max(r, -1), 1) : 0
        }
        for b in 0..<activeBands {
            leftChain[b].flushState()
            rightChain[b].flushState()
        }
    }

    /// Cascade response in dB at one frequency.
    private static func cascadeDb(
        atFreq freq: Double, bands: [EqBand], sampleRate: Double
    ) -> Double {
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
        return db
    }

    // Cluster offsets around each band center, in bandwidths. Narrow digital
    // peaks (high Q, warped near Nyquist) live within a bandwidth of some
    // band's f0; sampling there is what a global grid cannot do.
    private static let clusterOffsets: [Double] = [-1, -0.5, -0.25, -0.125, 0, 0.125, 0.25, 0.5, 1]

    /// Worst-case combined boost of the cascade in dB: a coarse log grid plus
    /// a cluster of points around every band center (exact f0 included), then
    /// golden-section refinement around the best sample. Overlapping boosted
    /// bands multiply, so this — not the largest single band — is what the
    /// auto preamp must compensate. May allocate (scratch buffer and sort);
    /// call only off the render thread. Process() additionally hard-clamps at
    /// full scale, so even an adversarial config beyond measurement accuracy
    /// cannot push more than full scale downstream.
    public static func cascadeMaxBoostDb(bands: [EqBand], sampleRate: Double) -> Float {
        guard !bands.isEmpty else { return 0 }
        let gridPoints = 512
        let total = gridPoints + bands.count * clusterOffsets.count
        let fMin = 10.0
        let fMax = 0.45 * sampleRate
        let logStep = log(fMax / fMin) / Double(gridPoints - 1)

        var maxDb = 0.0
        withUnsafeTemporaryAllocation(of: Double.self, capacity: total) { freqs in
            for k in 0..<gridPoints {
                freqs[k] = fMin * exp(Double(k) * logStep)
            }
            var idx = gridPoints
            for band in bands {
                let bandwidth = band.freqHz / band.q
                for offset in clusterOffsets {
                    freqs[idx] = min(max(band.freqHz + offset * bandwidth, fMin), fMax)
                    idx += 1
                }
            }
            var sortable = freqs // same memory; the struct itself needs var for sort()
            sortable.sort()
            var bestIndex = 0
            for i in 0..<total {
                let db = cascadeDb(atFreq: freqs[i], bands: bands, sampleRate: sampleRate)
                if db > maxDb {
                    maxDb = db
                    bestIndex = i
                }
            }
            // Golden-section refine inside the bracketing neighbours.
            var lo = freqs[max(bestIndex - 1, 0)]
            var hi = freqs[min(bestIndex + 1, total - 1)]
            let phi = 0.6180339887498949
            for _ in 0..<40 {
                let a = hi - (hi - lo) * phi
                let b = lo + (hi - lo) * phi
                let dbA = cascadeDb(atFreq: a, bands: bands, sampleRate: sampleRate)
                let dbB = cascadeDb(atFreq: b, bands: bands, sampleRate: sampleRate)
                if dbA > dbB {
                    hi = b
                    maxDb = max(maxDb, dbA)
                } else {
                    lo = a
                    maxDb = max(maxDb, dbB)
                }
            }
        }
        return maxDb > 0 ? Float(maxDb) + 0.25 : 0
    }
}
