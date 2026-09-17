import CoreGraphics
import Foundation
import PutCore

public enum ScreenConfigMatchOutcome: Equatable, Sendable {
    case noMatch
    /// Identity set matched. `arrangementAligned` reports whether the relative
    /// `globalOrigin` offsets also line up with the capture. It never blocks a
    /// match: macOS assigns the built-in display a different offset on every
    /// replug, so gating on it left layouts silently unactivated. The flag is
    /// surfaced so the near-miss can be logged.
    case matched(arrangementAligned: Bool)
}

/// Compares a captured `ScreenConfigTrigger` against a current display
/// snapshot. Pure function. Identity-set match decides the outcome; the
/// arrangement comparison is informational.
public enum ScreenConfigMatcher {
    /// Tolerance (in points) for arrangement comparisons. macOS reports
    /// display origins as integers, so anything outside a single point is a
    /// genuine layout difference, not floating-point noise.
    private static let arrangementTolerance: CGFloat = 1.0

    public static func evaluate(
        trigger: ScreenConfigTrigger,
        against current: [DisplayFingerprint]) -> ScreenConfigMatchOutcome
    {
        guard trigger.displays.count == current.count else { return .noMatch }
        guard !trigger.displays.isEmpty else { return .noMatch }

        // Pair each captured display with a current display by identity.
        // Reuse `DisplayMatcher` so the identity rules (UUID > vendor+product+serial
        // > vendor+product) stay in one place. Quality must be `equivalent` or
        // better; "similar" (size-only) is too loose for trigger evaluation.
        //
        // Consume candidates by per-instance index into `current`, not by the
        // fingerprint `id` string: twin displays (same vendor+product, nil
        // serial, nil UUID) share one id, so id-based consumption removed BOTH
        // twins after the first pairing and forced .noMatch on an exact match.
        var pairs: [(captured: DisplayFingerprint, live: DisplayFingerprint)] = []
        var availableIndices = Array(current.indices)
        for captured in trigger.displays {
            let candidates = availableIndices.map { current[$0] }
            guard let result = DisplayMatcher.resolve(target: captured, among: candidates),
                  result.quality <= .equivalent,
                  let slot = availableIndices.firstIndex(where: { current[$0] == result.display })
            else {
                return .noMatch
            }
            pairs.append((captured, result.display))
            availableIndices.remove(at: slot)
        }

        return .matched(arrangementAligned: arrangementsAlign(pairs: pairs))
    }

    /// Compares the relative arrangement of paired displays. Subtracts the
    /// first canonical display's `globalOrigin` from every other display's
    /// origin in both the captured and live sets, then asserts the offset
    /// vectors match within tolerance. Subtracting a common anchor makes the
    /// check insensitive to which display macOS happens to call "primary"
    /// across reboots — only the relative geometry has to line up.
    private static func arrangementsAlign(
        pairs: [(captured: DisplayFingerprint, live: DisplayFingerprint)]) -> Bool
    {
        guard pairs.count > 1 else { return true }
        // Sort by captured display identity for a deterministic anchor; both
        // sides walk the same order, so the delta computation stays stable.
        let sortedPairs = pairs.sorted { $0.captured.id < $1.captured.id }
        let capturedAnchor = sortedPairs[0].captured.globalOrigin
        let liveAnchor = sortedPairs[0].live.globalOrigin

        for pair in sortedPairs.dropFirst() {
            let capturedDelta = CGPoint(
                x: pair.captured.globalOrigin.x - capturedAnchor.x,
                y: pair.captured.globalOrigin.y - capturedAnchor.y)
            let liveDelta = CGPoint(
                x: pair.live.globalOrigin.x - liveAnchor.x,
                y: pair.live.globalOrigin.y - liveAnchor.y)
            if abs(capturedDelta.x - liveDelta.x) > arrangementTolerance
                || abs(capturedDelta.y - liveDelta.y) > arrangementTolerance
            {
                return false
            }
        }
        return true
    }
}
