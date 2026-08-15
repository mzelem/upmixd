import Foundation

/// Bridges DaemonSettings' free-form band list and a fixed 10-slider graphic
/// EQ UI. A config band belongs to a slider only if it sits exactly on a
/// standard frequency with the default Q and within the slider's gain range;
/// everything else is a "custom band" the UI preserves verbatim.
public struct GraphicEQ: Equatable {
    public static let standardFrequencies: [Double] =
        [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    public static let maxSliderDb: Float = 12
    static let sliderQ = 1.41

    /// One gain per standard frequency, in dB.
    public var gainsDb: [Float]
    /// Bands the sliders don't own, preserved in their original order.
    public private(set) var customBands: [EqBand]

    public init(from settings: DaemonSettings) {
        gainsDb = [Float](repeating: 0, count: Self.standardFrequencies.count)
        customBands = []
        var slotTaken = [Bool](repeating: false, count: Self.standardFrequencies.count)
        for band in settings.eqBands {
            if let slot = Self.standardFrequencies.firstIndex(of: band.freqHz),
               !slotTaken[slot], band.q == Self.sliderQ, abs(band.gainDb) <= Self.maxSliderDb {
                gainsDb[slot] = band.gainDb
                slotTaken[slot] = true
            } else {
                // Duplicates on a taken slot are preserved as custom, never
                // silently merged or dropped.
                customBands.append(band)
            }
        }
    }

    /// Returns `base` with its band list rebuilt from the custom bands plus
    /// every non-zero slider (clamped to the slider range), capped at the
    /// daemon's band limit: custom bands always survive; if the total would
    /// exceed the cap, the quietest sliders are sacrificed first. All
    /// non-EQ-band settings pass through untouched.
    public func applied(to base: DaemonSettings) -> DaemonSettings {
        var sliderBands: [EqBand] = []
        for (slot, gain) in gainsDb.enumerated() where gain != 0 {
            let clamped = max(-Self.maxSliderDb, min(Self.maxSliderDb, gain))
            sliderBands.append(
                EqBand(freqHz: Self.standardFrequencies[slot], gainDb: clamped))
        }
        let budget = max(0, DaemonSettings.maxEqBands - customBands.count)
        if sliderBands.count > budget {
            sliderBands.sort { abs($0.gainDb) > abs($1.gainDb) }
            sliderBands.removeLast(sliderBands.count - budget)
            sliderBands.sort { $0.freqHz < $1.freqHz }
        }
        var out = base
        out.eqBands = customBands + sliderBands
        return out
    }
}
