import Foundation

/// The daemon's complete tunable state: upmix knobs plus EQ. Parsed from and
/// rendered to the plain `key = value` config file that the daemon watches
/// and the (future) UI writes.
public struct DaemonSettings: Equatable {
    public static let maxEqBands = Equalizer.maxBands
    /// Bands validate against the daemon's fixed pipeline rate.
    public static let nominalSampleRate = 48_000.0

    public var upmix = UpmixConfig()
    public var eqBands: [EqBand] = []
    /// nil = automatic headroom (measured worst-case cascade boost). The
    /// default is a fixed -6 dB — constant headroom within a fraction of a dB
    /// of every built-in preset's worst case (extremes touch the full-scale
    /// limiter), so adjusting one band never shifts the level of the others
    /// the way auto's re-measurement does.
    public var eqPreampDb: Float? = -6

    /// Output device selection. Both nil = automatic (most capable real
    /// device). The name is the primary key (USB UIDs change with the port);
    /// the uid disambiguates same-name devices.
    public var outputName: String?
    public var outputUid: String?

    public var outputSelection: OutputSelection {
        if outputName == nil && outputUid == nil { return .automatic }
        return .explicit(uid: outputUid, name: outputName)
    }

    public init() {}

    /// Forgiving line-based parse: `#` comments, blank lines, `key = value`.
    /// Unknown keys, malformed lines, and out-of-range values produce a
    /// warning and leave the `defaults` value in place — a bad config must
    /// never take the audio down. Scalar keys: last value wins.
    /// `eq_band = <freq_hz> <gain_db> [<q>]` lines accumulate in order,
    /// appending to any bands already in `defaults`.
    public static func parse(
        _ text: String, defaults: DaemonSettings = DaemonSettings()
    ) -> (settings: DaemonSettings, warnings: [String]) {
        var settings = defaults
        var warnings: [String] = []

        func scalar(_ raw: String, _ key: String, min: Double, max: Double, line: Int) -> Double? {
            guard let value = Double(raw), value >= min, value <= max else {
                warnings.append("line \(line): \(key) requires a number in [\(min), \(max)]")
                return nil
            }
            return value
        }

        // Normalize CRLF/CR before splitting: "\r\n" is a single Character in
        // Swift, so splitting on "\n" alone would treat a CRLF file as one line.
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for (index, rawLine) in normalized.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = index + 1
            // Comment stripper honoring backslash escapes: render() writes
            // device names containing '#' as "\#" so they survive this cut.
            var content = ""
            var previous: Character? = nil
            for character in rawLine {
                if character == "#" && previous != "\\" { break }
                content.append(character)
                previous = character
            }
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            guard let eq = trimmed.firstIndex(of: "=") else {
                warnings.append("line \(line): expected key = value")
                continue
            }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)

            switch key {
            case "rear_gain":
                if let v = scalar(value, key, min: 0, max: 1, line: line) {
                    settings.upmix.rearGain = Float(v)
                }
            case "rear_delay_ms":
                if let v = scalar(value, key, min: 1, max: 100, line: line) {
                    settings.upmix.rearDelayMs = v
                }
            case "center_gain":
                if let v = scalar(value, key, min: 0, max: 0.5, line: line) {
                    settings.upmix.centerGain = Float(v)
                }
            case "lfe_gain":
                if let v = scalar(value, key, min: 0, max: 0.45, line: line) {
                    settings.upmix.lfeGain = Float(v)
                }
            case "output_device":
                if value == "auto" {
                    settings.outputName = nil
                    settings.outputUid = nil
                } else if value.isEmpty {
                    warnings.append("line \(line): output_device requires a device name or auto")
                } else {
                    settings.outputName = value.replacingOccurrences(of: "\\#", with: "#")
                }
            case "output_device_uid":
                if value.isEmpty {
                    warnings.append("line \(line): output_device_uid requires a value")
                } else {
                    settings.outputUid = value.replacingOccurrences(of: "\\#", with: "#")
                }
            case "eq_preamp_db":
                if value == "auto" {
                    settings.eqPreampDb = nil
                } else if let v = scalar(value, key, min: -60, max: 0, line: line) {
                    settings.eqPreampDb = Float(v)
                }
            case "eq_band":
                let parts = value.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard parts.count == 2 || parts.count == 3,
                      let freq = Double(parts[0]), let gain = Double(parts[1]),
                      let q = parts.count == 3 ? Double(parts[2]) : EqBand.defaultQ
                else {
                    warnings.append("line \(line): eq_band requires <freq_hz> <gain_db> [<q>]")
                    continue
                }
                let band = EqBand(freqHz: freq, gainDb: Float(gain), q: q)
                guard band.validated(sampleRate: nominalSampleRate) != nil else {
                    warnings.append("line \(line): eq_band out of range (freq in [10, \(Int(0.45 * nominalSampleRate))], |gain| <= 24, q in [0.1, 18])")
                    continue
                }
                guard settings.eqBands.count < maxEqBands else {
                    warnings.append("line \(line): more than \(maxEqBands) eq_band lines, ignoring")
                    continue
                }
                settings.eqBands.append(band)
            default:
                // Sanitize before echoing: warnings end up in logs, and the
                // key text is arbitrary file content (control characters
                // could forge log lines or emit terminal escapes).
                let safeKey = String(String.UnicodeScalarView(
                    key.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
                )).prefix(60)
                warnings.append("line \(line): unknown key \"\(safeKey)\"")
            }
        }
        return (settings, warnings)
    }

    /// Canonical config-file text; `parse(render())` round-trips exactly.
    public func render() -> String {
        // Device names/UIDs are descriptor-supplied text: strip control
        // characters (nothing may inject config lines) and escape '#' so the
        // comment stripper leaves them intact.
        func configValue(_ raw: String) -> String {
            let clean = String(String.UnicodeScalarView(
                raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            return clean.replacingOccurrences(of: "#", with: "\\#")
        }
        var lines = [
            "# upmixd configuration — edited live; the daemon reloads on save",
            "",
            "# output_device = auto picks the most capable real device",
            "output_device = \(outputName.map(configValue) ?? "auto")",
        ]
        if let outputUid {
            lines.append("output_device_uid = \(configValue(outputUid))")
        }
        lines += [
            "",
            "# upmix (bounds are the no-clipping limits for full-scale input)",
            "rear_gain = \(upmix.rearGain)",
            "rear_delay_ms = \(upmix.rearDelayMs)",
            "center_gain = \(upmix.centerGain)",
            "lfe_gain = \(upmix.lfeGain)",
            "",
            "# equalizer: eq_band = <freq_hz> <gain_db> [<q>]",
            "eq_preamp_db = \(eqPreampDb.map { "\($0)" } ?? "auto")",
        ]
        for band in eqBands {
            lines.append("eq_band = \(band.freqHz) \(band.gainDb) \(band.q)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
