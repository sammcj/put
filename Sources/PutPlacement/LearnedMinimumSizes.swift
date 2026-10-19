import CoreGraphics
import Foundation

/// Minimum window sizes inferred from writes an app refused to honour.
///
/// Asking an app for a size below its minimum makes the write drift: the app
/// clamps, `WindowMutator` retries (nudging and sleeping between attempts), and
/// the restore reports a drift that will recur on every pass. Remembering the
/// size the app settled on lets later restores ask for something it accepts.
///
/// Keyed by rule rather than app. One app's windows have different minimums
/// (a main window against a utility panel), and an app that snaps to a grid or
/// keeps an aspect ratio can pass for one with a floor; keying per rule keeps
/// either mistake to the rule that produced it.
///
/// Held in memory only. A minimum belongs to an app version and its current
/// content, and a stale entry would silently enlarge windows; relearning one
/// costs a single drifted write after Put relaunches.
public struct LearnedMinimumSizes: Sendable, Equatable {
    /// Points beyond the target an axis must land before it counts as refused.
    /// Matches `WindowMutator.frameTolerance` so rounding never reads as a floor.
    public static let tolerance: CGFloat = 2

    private var minimums: [UUID: CGSize] = [:]

    public init() {}

    public func minimum(for ruleID: UUID) -> CGSize? {
        minimums[ruleID]
    }

    /// `frame` grown to at least the learned minimum for `ruleID`, keeping its
    /// origin. Unchanged when nothing has been learned for that rule.
    public func applying(to frame: CGRect, ruleID: UUID) -> CGRect {
        guard let minimum = minimums[ruleID] else { return frame }
        return CGRect(
            origin: frame.origin,
            size: CGSize(
                width: max(frame.width, minimum.width),
                height: max(frame.height, minimum.height)))
    }

    /// Record the floor a drifted write exposed. Returns the updated minimum
    /// when something new was learned, nil otherwise.
    ///
    /// An axis only counts when the window shrank towards the target and
    /// stopped short of it. An app that ignored the write outright (Firefox
    /// after wake) leaves the size where it started, and treating that as a
    /// minimum would pin the window at whatever size it happened to have.
    @discardableResult
    public mutating func learn(
        ruleID: UUID,
        initial: CGSize?,
        target: CGSize,
        actual: CGSize) -> CGSize?
    {
        guard let initial else { return nil }
        let width = Self.floor(initial: initial.width, target: target.width, actual: actual.width)
        let height = Self.floor(initial: initial.height, target: target.height, actual: actual.height)
        guard width != nil || height != nil else { return nil }

        let previous = minimums[ruleID] ?? .zero
        let updated = CGSize(
            width: max(previous.width, width ?? 0),
            height: max(previous.height, height ?? 0))
        guard updated != previous else { return nil }
        minimums[ruleID] = updated
        return updated
    }

    private static func floor(initial: CGFloat, target: CGFloat, actual: CGFloat) -> CGFloat? {
        let stoppedAboveTarget = actual > target + tolerance
        let shrankTowardsTarget = actual < initial - tolerance
        return stoppedAboveTarget && shrankTowardsTarget ? actual : nil
    }
}
