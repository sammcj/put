import CoreGraphics
import Foundation
import PutCore

/// Per-window memory of recent successful placements, used by
/// `ActionCoordinator` to suppress automatic re-placement of a window the
/// user has moved or resized away from where Put put it.
///
/// The decision logic lives here as pure value-typed code so it can be
/// exercised without spinning up an Accessibility-dependent coordinator;
/// the live cache and `AXUIElement` keying live in `ActionCoordinator`.
///
/// ## No time-based cooldown
///
/// An earlier version expired suppression after a fixed 30s window anchored
/// to the placement time. That was the cause of the "Put keeps snapping my
/// window back" bug: the user moves a window, keeps working, and the next
/// wake or display event hours later finds the record stale and re-asserts
/// the saved frame. Suppression is now durable. Once a window is detected as
/// user-moved it stays suppressed until one of these resets it:
///
/// - the rule resolves to a different target frame - e.g. a display is added
///   or removed, or the layout is edited - which fails the target-match guard
///   below and lets the write through (this is how "the display layout
///   changed" resets the window, precisely and per-window, rather than a
///   blanket wipe that benign reconfigure bursts would trip), or
/// - the user runs an explicit restore (hotkey/menu), which bypasses the
///   check and rewrites the record so the window matches its target again, or
/// - the window is closed, dropping its record on the next full snapshot.
///
/// For the trigger timing that *does* still use clocks (debounce, wake/launch
/// retries) see `RestoreTiming` in PutAutomation.
public enum PlacementHistory {
    /// Which parts of a recorded placement a replay check compares.
    ///
    /// A rule only gets to suppress on what it actually asserts. Comparing a
    /// component the rule leaves alone is worse than useless: the window's size
    /// under a position-only rule is whatever the user last made it, so a whole
    /// frame comparison reports every user resize as a target mismatch and
    /// switches suppression off entirely - the opposite of what it's for.
    public enum FrameComparison: Sendable {
        /// Origin and size, for a rule restoring both.
        case wholeFrame
        /// Origin only, for a rule restoring a position but not a size.
        case originOnly
    }

    /// Frozen record of a successful placement: which rule produced it,
    /// where it was put, and when. `placedAt` is kept for diagnostics and
    /// logging only; it no longer gates suppression.
    public struct Record: Hashable, Sendable {
        public var ruleID: UUID
        public var targetFrame: CGRect
        public var placedAt: Date

        public init(ruleID: UUID, targetFrame: CGRect, placedAt: Date) {
            self.ruleID = ruleID
            self.targetFrame = targetFrame
            self.placedAt = placedAt
        }
    }

    /// A window must differ from its recorded target by more than this many
    /// points - on either origin axis or either dimension - for us to treat
    /// it as user-moved or user-resized. Above the typical "drift" the AX
    /// server reports for borderline apps, well below any deliberate user
    /// drag or resize.
    public static let defaultDriftThreshold: CGFloat = 50

    /// Should an auto-trigger replay of `nextRuleID` at `nextTargetFrame`
    /// against a window currently at `currentFrame` be suppressed because
    /// the user appears to have moved or resized that window away from where
    /// we last placed it?
    ///
    /// Returns `true` only when *all* of the following hold:
    ///
    /// - `record` exists,
    /// - `record.ruleID` matches the rule about to be applied,
    /// - `record.targetFrame` matches the target frame about to be applied
    ///   (so a target shift, e.g. layout edit or display change, still gets
    ///   to write), compared over the components in `comparing`,
    /// - the window's current frame still sits on its target display (a
    ///   window the system shuffled onto a *different* display - e.g. a
    ///   display power-cycle reflow - is not a user move, so we let the
    ///   restore put it back),
    /// - the window's current frame is more than `driftThreshold` points from
    ///   that recorded target, again over the components in `comparing`.
    ///
    /// There is deliberately no time component; see the type doc for why.
    ///
    /// `targetDisplayBounds` is the global-AX rect of the display the rule
    /// resolves onto. Pass `nil` to skip the cross-display check (e.g. when the
    /// caller can't resolve a display); behaviour then matches the old
    /// frame-only inference.
    public static func shouldSkipReplay(
        record: Record?,
        currentFrame: CGRect,
        nextRuleID: UUID,
        nextTargetFrame: CGRect,
        targetDisplayBounds: CGRect? = nil,
        comparing: FrameComparison = .wholeFrame,
        driftThreshold: CGFloat = defaultDriftThreshold) -> Bool
    {
        guard let record else { return false }
        guard record.ruleID == nextRuleID else { return false }
        guard sameTarget(record.targetFrame, nextTargetFrame, comparing: comparing) else { return false }
        if let bounds = targetDisplayBounds, !movedWithinDisplay(bounds: bounds, current: currentFrame) {
            return false
        }
        return movedBeyond(
            threshold: driftThreshold,
            target: nextTargetFrame,
            current: currentFrame,
            comparing: comparing)
    }

    private static func sameTarget(
        _ recorded: CGRect,
        _ next: CGRect,
        comparing: FrameComparison) -> Bool
    {
        switch comparing {
        case .wholeFrame:
            recorded.equalTo(next)
        case .originOnly:
            recorded.origin == next.origin
        }
    }

    /// True when the window's centre still lies on its target display. macOS
    /// reflows windows across displays on a power-cycle, which a frame-delta
    /// check can't tell from a user drag; a window now centred on a *different*
    /// display was almost certainly moved by the system, not the user.
    private static func movedWithinDisplay(bounds: CGRect, current: CGRect) -> Bool {
        bounds.contains(CGPoint(x: current.midX, y: current.midY))
    }

    /// True when `current` differs from `target` by more than `threshold` on
    /// any compared frame component.
    private static func movedBeyond(
        threshold: CGFloat,
        target: CGRect,
        current: CGRect,
        comparing: FrameComparison) -> Bool
    {
        let moved = abs(current.minX - target.minX) > threshold
            || abs(current.minY - target.minY) > threshold
        switch comparing {
        case .originOnly:
            return moved
        case .wholeFrame:
            return moved
                || abs(current.width - target.width) > threshold
                || abs(current.height - target.height) > threshold
        }
    }
}
