import CoreGraphics
import Foundation
import PutCore
import PutDisplay

/// Whether an applied frame is a faithful replay of the rule's saved
/// absolute coordinates, or a proportional remap.
///
/// `.exact` means the resolved display's geometry is indistinguishable from
/// the saved target, so the stored absolute frame is replayed verbatim.
/// `.proportional` means the frame was derived from the normalised (unit-space)
/// fallback - because the resolved display matched by identity but at a
/// different resolution/scale, or because no identity match was found and the
/// missing-display policy placed the window onto a substitute panel.
///
/// The distinction matters after wake: an external panel often enumerates at a
/// transient resolution before its real (or forced-HiDPI) mode settles, so a
/// proportional placement at that instant lands the window in the wrong size
/// and position. The wake-retry uses this flag to schedule a corrective second
/// pass once the displays have settled. See `AutoTriggerController`.
public enum PlacementFidelity: Sendable, Equatable {
    case exact
    case proportional
}

public enum PlacementDecision: Equatable, Sendable {
    /// Apply this global-space frame to the matched window using the given
    /// display as reference. `quality` describes how close the current display
    /// arrangement matches the rule's saved target; `fidelity` whether the
    /// frame is an exact replay or a proportional remap.
    case applyFrame(CGRect, on: DisplayFingerprint, quality: DisplayMatchQuality, fidelity: PlacementFidelity)

    /// The rule's target display is absent and the missing-display policy is
    /// `.skip`; do nothing.
    case skipped(reason: String)

    /// The rule's target display is absent and the missing-display policy is
    /// `.queueForReconnect`. Callers should retain the rule ID and retry on
    /// subsequent display changes.
    case queuedForReconnect(targetID: String)

    /// No connected displays at all; placement is impossible.
    case noDisplay
}

public enum PlacementEngine {
    /// Decide where to put a window that matches `rule` given the currently
    /// connected displays. Pure function.
    public static func resolve(rule: Rule, displays: [DisplayFingerprint]) -> PlacementDecision {
        guard !displays.isEmpty else { return .noDisplay }

        let match = DisplayMatcher.resolve(target: rule.targetDisplay, among: displays)

        if let match, match.quality <= .equivalent {
            let targetDisplay = match.display
            let sameGeometry = targetDisplay.sameGeometry(as: rule.targetDisplay)
            let localFrame: CGRect = if sameGeometry {
                rule.frame.absolute
            } else {
                Coordinates.denormalise(rule.frame.normalised, onDisplay: targetDisplay)
            }
            let global = Coordinates.toGlobal(localFrame, onDisplay: targetDisplay)
            // Identity matched but the panel is at a different resolution/scale
            // than when saved (classic post-wake transient): the absolute frame
            // no longer fits, so we remapped proportionally. Flag it so the
            // wake-retry can correct once the display settles.
            return .applyFrame(
                global,
                on: targetDisplay,
                quality: match.quality,
                fidelity: sameGeometry ? .exact : .proportional)
        }

        // Missing: apply policy.
        switch rule.missingDisplayPolicy {
        case .primaryProportional:
            // Prefer the matcher's closest-size result (`.similar`) over the
            // primary display when we have one; a similar-sized panel is
            // usually a better proportional target than whichever happens to
            // be flagged primary. Fall back to primary only if the matcher
            // returned nil (e.g. no displays — already short-circuited above).
            let fallback: DisplayFingerprint
            let quality: DisplayMatchQuality
            if let similar = match?.display {
                fallback = similar
                quality = .similar
            } else if let primary = DisplayMatcher.primary(among: displays) {
                fallback = primary
                quality = .primary
            } else {
                return .noDisplay
            }
            let local = Coordinates.denormalise(rule.frame.normalised, onDisplay: fallback)
            let global = Coordinates.toGlobal(local, onDisplay: fallback)
            return .applyFrame(global, on: fallback, quality: quality, fidelity: .proportional)

        case .skip:
            return .skipped(reason: "Target display \(rule.targetDisplay.id) not connected")

        case .queueForReconnect:
            return .queuedForReconnect(targetID: rule.targetDisplay.id)
        }
    }

    /// Build a fresh rule describing a window as it currently sits on-screen.
    /// Inverse of `resolve`: used at save time.
    ///
    /// `globalFrame` is the window's frame in global AX coordinates. The
    /// display returned by `Coordinates.displayContaining` is captured as the
    /// rule's target. When the window straddles two displays, the one with
    /// the larger overlapping area wins.
    public static func buildRule(
        matchCriteria: MatchCriteria,
        descriptiveLabel: String,
        globalFrame: CGRect,
        displays: [DisplayFingerprint],
        defaultMissingDisplayPolicy: MissingDisplayPolicy = .primaryProportional,
        restoresPosition: Bool = true) -> Rule?
    {
        guard let display = Coordinates.displayContaining(globalFrame, among: displays) else {
            return nil
        }
        let local = Coordinates.toLocal(globalFrame, onDisplay: display)
        let unit = Coordinates.normalise(local, onDisplay: display).clamped()
        let frame = WindowFrame(absolute: local, normalised: unit)
        return Rule(
            descriptiveLabel: descriptiveLabel,
            matchCriteria: matchCriteria,
            targetDisplay: display,
            frame: frame,
            missingDisplayPolicy: defaultMissingDisplayPolicy,
            restoresPosition: restoresPosition)
    }
}
