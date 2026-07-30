import Foundation

/// How much of a saved placement a rule re-asserts when it's restored.
///
/// The saved frame is always captured in full, whichever scope is chosen, so
/// switching between these never loses the original coordinates.
public enum RestoreScope: String, Codable, Sendable, CaseIterable, Hashable {
    /// Put the window back on its saved display at its saved size and position.
    case sizeAndPosition

    /// Resize the window to its saved size and leave it wherever it currently
    /// sits. Used for "force this size" rules.
    case sizeOnly

    /// Move the window onto its saved display and change nothing else. The
    /// window keeps its current size, and its position on the new display
    /// mirrors where it sat on the one it came from. Nothing happens when the
    /// window is already on the right display.
    case displayOnly

    /// Whether restoring writes the window's size.
    public var restoresSize: Bool {
        self != .displayOnly
    }

    /// Whether restoring writes the window's position. True for `.displayOnly`
    /// as well: moving a window between displays *is* a position write, just
    /// one derived from where the window currently is rather than replayed
    /// from the saved frame.
    public var restoresPosition: Bool {
        self != .sizeOnly
    }
}
