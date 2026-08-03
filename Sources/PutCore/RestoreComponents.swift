import Foundation

/// Which parts of a rule's saved placement a restore re-asserts.
///
/// The saved frame is captured in full whichever components are on, so turning
/// one off and back on later never loses the original coordinates.
///
/// `position` implies `display`. The saved origin is stored relative to a
/// display's top-left (`Rule.frame.absolute` against `Rule.targetDisplay`), so
/// replaying it without putting the window on that display is undefined. The
/// property observers below hold the invariant in both directions, and the
/// initialiser applies it to values that bypass them (decoding, memberwise
/// construction).
public struct RestoreComponents: Hashable, Sendable {
    /// Resize the window to its saved size.
    public var size: Bool

    /// Put the window back at its saved position on the target display.
    /// Turning this on turns `display` on with it.
    public var position: Bool {
        didSet { if position { display = true } }
    }

    /// Move the window onto the rule's target display. With `position` off the
    /// window keeps its position proportionally, mirroring where it sat on the
    /// display it came from. Turning this off turns `position` off with it.
    public var display: Bool {
        didSet { if !display { position = false } }
    }

    public init(size: Bool = true, position: Bool = true, display: Bool = true) {
        self.size = size
        self.position = position
        self.display = display || position
    }

    /// Saved size and position on the saved display. The default.
    public static let sizeAndPosition = RestoreComponents(size: true, position: true, display: true)

    /// Saved size only; the window stays wherever it currently sits.
    public static let sizeOnly = RestoreComponents(size: true, position: false, display: false)

    /// Target display only; the window keeps its current size and lands
    /// proportionally where it sat on the display it came from.
    public static let displayOnly = RestoreComponents(size: false, position: false, display: true)

    /// No component selected: the rule matches windows but writes nothing.
    /// Settings keeps at least one component on, so this is only reachable by
    /// hand-editing the config.
    public var isEmpty: Bool {
        !size && !position && !display
    }

    /// Whether restoring changes where the window sits rather than only its
    /// size. True for `display` alone: moving a window between displays is a
    /// position write, just one derived from where the window currently is
    /// rather than replayed from the saved frame.
    public var movesWindow: Bool {
        position || display
    }

    /// Whether the resolved frame draws its geometry from the saved frame, as
    /// opposed to being derived entirely from where the window already is.
    public var usesSavedFrame: Bool {
        size || position
    }

    /// The single AX write a restore performs. Derived here so both write paths
    /// (`ActionCoordinator.executeWrite` and `AutoTriggerController.write`)
    /// make the same choice from one place.
    public var write: RestoreWrite {
        switch (size, movesWindow) {
        case (true, true):
            .frame
        case (true, false):
            .size
        case (false, true):
            .position
        case (false, false):
            .nothing
        }
    }
}

extension RestoreComponents: Codable {
    private enum CodingKeys: String, CodingKey {
        case size, position, display
    }

    /// Routes through the normalising initialiser so a hand-edited config
    /// can't produce a position without a display. Missing keys take the
    /// same defaults as a fresh rule.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let size = try container.decodeIfPresent(Bool.self, forKey: .size) ?? true
        let position = try container.decodeIfPresent(Bool.self, forKey: .position) ?? true
        let display = try container.decodeIfPresent(Bool.self, forKey: .display) ?? true
        self.init(size: size, position: position, display: display)
    }
}

/// The AX write a restore performs for a given set of `RestoreComponents`.
public enum RestoreWrite: Sendable, Hashable {
    /// Size and position together.
    case frame
    /// Size only; the window's position is left alone.
    case size
    /// Position only; the window's size is left alone.
    case position
    /// Nothing to write.
    case nothing
}
