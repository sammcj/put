import Foundation

/// Superseded by `RestoreComponents`, which expresses combinations this enum
/// can't (size on a target display without replaying the saved position, say).
///
/// Retained for the `restoreScope` key in `Rule`'s Codable, which is still read
/// (configs written before the components existed) and still written (so a
/// config round-tripping through an older build degrades to the nearest scope
/// rather than re-asserting geometry the user cleared).
public enum RestoreScope: String, Codable, Sendable, CaseIterable, Hashable {
    /// Put the window back on its saved display at its saved size and position.
    case sizeAndPosition

    /// Resize the window to its saved size and leave it wherever it currently
    /// sits.
    case sizeOnly

    /// Move the window onto its saved display and change nothing else.
    case displayOnly

    /// The components an older config's scope maps onto.
    public var components: RestoreComponents {
        switch self {
        case .sizeAndPosition:
            .sizeAndPosition
        case .sizeOnly:
            .sizeOnly
        case .displayOnly:
            .displayOnly
        }
    }

    /// Nearest scope an older build can act on, for the compatibility key.
    ///
    /// Combinations without an exact equivalent degrade to the scope that
    /// asserts least: size on a target display becomes `.sizeOnly` (resize
    /// where it stands) rather than `.sizeAndPosition`, which would replay a
    /// position the user turned off. An empty set has no equivalent at all and
    /// maps to `.sizeOnly`; Settings keeps at least one component on, so it
    /// only arises from a hand-edited config.
    public static func closest(to components: RestoreComponents) -> RestoreScope {
        switch (components.size, components.position) {
        case (true, true):
            .sizeAndPosition
        case (true, false):
            .sizeOnly
        case (false, true):
            .displayOnly
        case (false, false):
            components.display ? .displayOnly : .sizeOnly
        }
    }
}
