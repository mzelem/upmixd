import Foundation

/// A playable output device as seen at selection time. Pure data so the
/// selection policy is testable without CoreAudio.
public struct OutputCandidate: Equatable {
    public var uid: String
    public var name: String
    public var maxOutputChannels: Int
    public var isCurrentDefault: Bool
    public var isVirtual: Bool

    public init(
        uid: String, name: String, maxOutputChannels: Int,
        isCurrentDefault: Bool = false, isVirtual: Bool = false
    ) {
        self.uid = uid
        self.name = name
        self.maxOutputChannels = maxOutputChannels
        self.isCurrentDefault = isCurrentDefault
        self.isVirtual = isVirtual
    }
}

public enum OutputSelection: Equatable {
    /// Pick the most capable real device automatically.
    case automatic
    /// A user-chosen device. UID matches first; the name rescues the
    /// selection when a replug changed the UID (USB UIDs embed the port).
    case explicit(uid: String?, name: String?)
}

/// The device the daemon should attach to, or nil if none qualifies (auto
/// with no real devices, or an explicit device that is absent — explicit
/// selections wait rather than silently switching).
public func chooseOutput(
    candidates: [OutputCandidate], selection: OutputSelection, captureUID: String
) -> OutputCandidate? {
    let real = candidates.filter { !$0.isVirtual && $0.uid != captureUID }
    switch selection {
    case .automatic:
        // Most channels wins (a surround adapter beats stereo devices); the
        // current default breaks ties (the user already chose it); UID sort
        // makes the final tie-break deterministic across enumeration orders.
        return real.max { a, b in
            if a.maxOutputChannels != b.maxOutputChannels {
                return a.maxOutputChannels < b.maxOutputChannels
            }
            if a.isCurrentDefault != b.isCurrentDefault {
                return b.isCurrentDefault
            }
            return a.uid > b.uid
        }
    case let .explicit(uid, name):
        if let uid, let byUid = real.first(where: { $0.uid == uid }) {
            return byUid
        }
        if let name, let byName = real.first(where: { $0.name == name }) {
            return byName
        }
        return nil
    }
}

/// How many channels the pipeline should run for a device: 5.1 when the
/// device can take it, otherwise EQ-only stereo passthrough.
public func pipelineChannels(deviceMaxChannels: Int) -> Int {
    deviceMaxChannels >= 6 ? 6 : 2
}
