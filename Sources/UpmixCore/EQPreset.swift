import Foundation

/// Named gain curves for the 10 standard GraphicEQ bands
/// (32 64 125 250 500 1k 2k 4k 8k 16k), in dB. Values follow the widely
/// used consumer-EQ curve shapes.
public struct EQPreset: Equatable, Identifiable {
    public let name: String
    public let gainsDb: [Float]

    public var id: String { name }

    public static let all: [EQPreset] = [
        EQPreset(name: "Flat", gainsDb: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        EQPreset(name: "Rock", gainsDb: [5, 4, 3, 1, -0.5, -1, 0.5, 2.5, 3.5, 4.5]),
        EQPreset(name: "Pop", gainsDb: [-1.5, -1, 0, 2, 4, 4, 2, 0, -1, -1.5]),
        EQPreset(name: "Jazz", gainsDb: [4, 3, 1, 2, -1.5, -1.5, 0, 1, 3, 3.5]),
        EQPreset(name: "Classical", gainsDb: [4.5, 3.5, 3, 2.5, -1, -1, 0, 2, 3, 3.5]),
        EQPreset(name: "Bass Boost", gainsDb: [5.5, 4.5, 3.5, 2.5, 1, 0, 0, 0, 0, 0]),
        EQPreset(name: "Treble Boost", gainsDb: [0, 0, 0, 0, 0, 1, 2.5, 3.5, 4.5, 5.5]),
        EQPreset(name: "Vocal", gainsDb: [-2, -1, 0, 1, 3.5, 4, 3.5, 2, 0.5, -1]),
    ]

    /// The preset exactly matching these slider gains, if any.
    public static func matching(_ gainsDb: [Float]) -> EQPreset? {
        all.first { $0.gainsDb == gainsDb }
    }
}
