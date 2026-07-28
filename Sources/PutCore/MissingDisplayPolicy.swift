import Foundation

/// What the placement engine does when a rule's target display is not
/// currently connected.
public enum MissingDisplayPolicy: String, Codable, Hashable, Sendable, CaseIterable {
    /// Remap the stored unit rect onto the primary display. Non-destructive,
    /// predictable, and the default.
    case primaryProportional

    /// Leave the window untouched. Useful for rules bound to a specific
    /// ultrawide where remapping onto a 13" laptop would produce nonsense.
    case skip

    /// Remember the intent and apply it when the target display returns.
    case queueForReconnect
}
