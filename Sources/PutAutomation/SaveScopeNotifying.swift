import Foundation

/// One window a save skipped because it sat on a display outside the active
/// layout's screen-config scope.
public struct OutOfScopeSave: Sendable, Equatable {
    /// Human-friendly label for the window's app (the rule's descriptive label).
    public let appLabel: String
    /// The display the window was actually on, by localised name when known.
    public let displayName: String

    public init(appLabel: String, displayName: String) {
        self.appLabel = appLabel
        self.displayName = displayName
    }
}

/// Surfaces a notice when a save touched windows on displays that aren't part
/// of the active layout's screen configuration - i.e. the user is saving while
/// running a layout whose monitors don't match what's connected. Kept as a
/// protocol so `ActionCoordinator` (in `PutAutomation`) stays free of AppKit
/// alert presentation; `PutUI` supplies the concrete implementation, mirroring
/// `SaveFlashing`.
@MainActor
public protocol SaveScopeNotifying: Sendable {
    func warnOutOfScopeSaves(layoutName: String, skipped: [OutOfScopeSave])
}

public struct NoopSaveScopeNotifying: SaveScopeNotifying {
    public init() {}
    public func warnOutOfScopeSaves(layoutName: String, skipped: [OutOfScopeSave]) {}
}
