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
    /// Why a rule that derives its position from the window's current one (a
    /// display restored without a saved position) produced no placement. Such a
    /// rule has no position of its own, so with no usable current frame it does
    /// nothing rather than falling back to the saved origin - which would move
    /// the window somewhere the rule never asked for.
    static let derivedPositionSkipReason = "Display-relative rule: window not on any connected display"

    /// Why a rule with no restore components at all produced no placement.
    /// Settings keeps at least one component on, so this only arises from a
    /// hand-edited config.
    static let inertRuleSkipReason = "Rule restores nothing: no size, position or display selected"

    /// Decide where to put a window that matches `rule` given the currently
    /// connected displays. Pure function.
    ///
    /// `currentFrame` is the matched window's live frame in global AX space.
    /// It's consulted by rules that don't replay the saved position, which
    /// derive their target from where the window already is; pass nil when
    /// there is no live window (a UI preview, say) and the saved frame is used
    /// instead where one exists.
    public static func resolve(
        rule: Rule,
        displays: [DisplayFingerprint],
        currentFrame: CGRect? = nil) -> PlacementDecision
    {
        guard !displays.isEmpty else { return .noDisplay }
        guard !rule.restoreComponents.isEmpty else { return .skipped(reason: inertRuleSkipReason) }

        let match = DisplayMatcher.resolve(target: rule.targetDisplay, among: displays)

        if let match, match.quality <= .equivalent {
            // Identity matched but the panel may be at a different
            // resolution/scale than when saved (classic post-wake transient):
            // the absolute frame no longer fits, so remap proportionally and
            // flag it so the wake-retry can correct once the display settles. A
            // rule that takes no geometry from the saved frame is unaffected by
            // the panel's mode, so it stays exact.
            let sameGeometry = match.display.sameGeometry(as: rule.targetDisplay)
            return decide(
                rule: rule,
                on: Resolution(
                    target: match.display,
                    quality: match.quality,
                    fidelity: sameGeometry || !rule.restoreComponents.usesSavedFrame ? .exact : .proportional,
                    sameGeometry: sameGeometry),
                currentFrame: currentFrame,
                displays: displays)
        }

        return resolveMissing(
            rule: rule,
            displays: displays,
            currentFrame: currentFrame,
            closest: match?.display)
    }

    /// The display a rule resolved onto, and how faithfully its saved frame
    /// carries over to it.
    private struct Resolution {
        let target: DisplayFingerprint
        let quality: DisplayMatchQuality
        let fidelity: PlacementFidelity
        /// Whether the saved absolute frame can be replayed verbatim, or has to
        /// be denormalised onto `target`.
        let sameGeometry: Bool
    }

    /// Build the target frame for `rule` on an already-chosen display.
    ///
    /// Three shapes, by what the rule takes from the saved frame:
    ///
    /// - Saved position (which implies the saved display): replay it, at the
    ///   saved size if size is on and the window's current size if not.
    /// - Display without a saved position: keep where the window sits relative
    ///   to the display it came from, at the saved size if size is on.
    /// - Neither: only the size is written, so the window stays put and the
    ///   saved frame carries the size.
    private static func decide(
        rule: Rule,
        on resolution: Resolution,
        currentFrame: CGRect?,
        displays: [DisplayFingerprint]) -> PlacementDecision
    {
        let components = rule.restoreComponents
        let target = resolution.target
        let savedLocal = resolution.sameGeometry
            ? rule.frame.absolute
            : Coordinates.denormalise(rule.frame.normalised, onDisplay: target)
        let saved = Coordinates.toGlobal(savedLocal, onDisplay: target)

        func apply(_ frame: CGRect) -> PlacementDecision {
            .applyFrame(frame, on: target, quality: resolution.quality, fidelity: resolution.fidelity)
        }

        if components.position {
            return apply(components.size
                ? saved
                : CGRect(origin: saved.origin, size: currentFrame?.size ?? saved.size))
        }

        if components.display {
            guard let moved = derivedFrame(
                target: target,
                currentFrame: currentFrame,
                resizedTo: components.size ? saved.size : nil,
                displays: displays)
            else { return .skipped(reason: derivedPositionSkipReason) }
            return apply(moved)
        }

        return apply(saved)
    }

    /// The rule's target display isn't connected; apply its
    /// `missingDisplayPolicy`. `closest` is the matcher's best non-identity
    /// candidate, if it found one.
    private static func resolveMissing(
        rule: Rule,
        displays: [DisplayFingerprint],
        currentFrame: CGRect?,
        closest: DisplayFingerprint?) -> PlacementDecision
    {
        switch rule.missingDisplayPolicy {
        case .primaryProportional:
            // Prefer the matcher's closest-size result (`.similar`) over the
            // primary display when we have one; a similar-sized panel is
            // usually a better proportional target than whichever happens to
            // be flagged primary. Fall back to primary only if the matcher
            // returned nil (e.g. no displays — already short-circuited above).
            let fallback: DisplayFingerprint
            let quality: DisplayMatchQuality
            if let closest {
                fallback = closest
                quality = .similar
            } else if let primary = DisplayMatcher.primary(among: displays) {
                fallback = primary
                quality = .primary
            } else {
                return .noDisplay
            }
            // The panel is a substitute, so every frame derived from it is a
            // guess: proportional regardless of which components are on, and
            // the saved absolute frame belongs to a different panel.
            return decide(
                rule: rule,
                on: Resolution(
                    target: fallback,
                    quality: quality,
                    fidelity: .proportional,
                    sameGeometry: false),
                currentFrame: currentFrame,
                displays: displays)

        case .skip:
            return .skipped(reason: "Target display \(rule.targetDisplay.id) not connected")

        case .queueForReconnect:
            return .queuedForReconnect(targetID: rule.targetDisplay.id)
        }
    }

    /// Target frame for a rule that restores a display but no saved position:
    /// the window's proportional position translated onto `target`, at its
    /// current size unless `resizedTo` supplies the rule's saved one.
    ///
    /// Returns nil when the window can't be attributed to a display it is
    /// genuinely on - no live frame was passed, the frame is non-finite, or it
    /// overlaps no display at all. `displayContaining` answers the save-time
    /// question ("which display should own this rule?") and so falls back to
    /// primary for a frame that overlaps nothing; that fallback is wrong here,
    /// because translating *from* a display the window isn't on invents an
    /// origin. A failed AX read yields `CGRect.zero`, which would otherwise map
    /// to the target's top-left corner.
    private static func derivedFrame(
        target: DisplayFingerprint,
        currentFrame: CGRect?,
        resizedTo newSize: CGSize?,
        displays: [DisplayFingerprint]) -> CGRect?
    {
        guard let currentFrame,
              let source = Coordinates.displayContaining(currentFrame, among: displays),
              overlaps(currentFrame, source)
        else { return nil }
        return Coordinates.moving(currentFrame, onto: target, from: source, resizedTo: newSize)
    }

    /// Whether `frame` covers a positive area of `display`. Mirrors the
    /// `area > 0` test inside `Coordinates.displayContaining`, which is what
    /// distinguishes a real attribution from its primary-display fallback.
    /// `CGRect.intersects` is not enough: it reports true for a zero-size rect
    /// whose origin lies inside the bounds, which is exactly the `CGRect.zero`
    /// a failed AX read produces.
    private static func overlaps(_ frame: CGRect, _ display: DisplayFingerprint) -> Bool {
        let bounds = CGRect(origin: display.globalOrigin, size: display.pointSize)
        let intersection = bounds.intersection(frame)
        return !intersection.isNull && intersection.width > 0 && intersection.height > 0
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
        restoreComponents: RestoreComponents = .sizeAndPosition) -> Rule?
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
            restoreComponents: restoreComponents)
    }
}
