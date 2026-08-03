import CoreGraphics
import Foundation
import PutCore

/// Coordinate conversions between the three spaces Put cares about:
///
/// - **Global AX space.** Top-left origin, spans the full virtual screen, used
///   by the Accessibility API's `kAXPositionAttribute`. Primary display's
///   top-left is at `(0, 0)`.
/// - **Display-local space.** Top-left origin relative to a single display's
///   `globalOrigin`. This is what `Rule.frame.absolute` stores.
/// - **Unit space.** `[0, 1] x [0, 1]` relative to a display's `pointSize`.
///   This is `Rule.frame.normalised`, used as the proportional fallback.
public enum Coordinates {
    /// Convert a rect in global AX space into display-local coords relative to
    /// the display it should be pinned to. No clamping is performed; the
    /// caller is responsible for choosing the right display (typically via
    /// `displayContaining`).
    public static func toLocal(_ global: CGRect, onDisplay display: DisplayFingerprint) -> CGRect {
        CGRect(
            x: global.origin.x - display.globalOrigin.x,
            y: global.origin.y - display.globalOrigin.y,
            width: global.size.width,
            height: global.size.height)
    }

    /// Convert a display-local rect back into global AX space.
    public static func toGlobal(_ local: CGRect, onDisplay display: DisplayFingerprint) -> CGRect {
        CGRect(
            x: local.origin.x + display.globalOrigin.x,
            y: local.origin.y + display.globalOrigin.y,
            width: local.size.width,
            height: local.size.height)
    }

    /// Normalise a display-local rect into unit space.
    public static func normalise(_ local: CGRect, onDisplay display: DisplayFingerprint) -> UnitRect {
        let width = max(display.pointSize.width, 1)
        let height = max(display.pointSize.height, 1)
        return UnitRect(
            x: Double(local.origin.x / width),
            y: Double(local.origin.y / height),
            width: Double(local.size.width / width),
            height: Double(local.size.height / height))
    }

    /// Denormalise a unit rect onto a display's point-size.
    public static func denormalise(_ unit: UnitRect, onDisplay display: DisplayFingerprint) -> CGRect {
        let width = max(display.pointSize.width, 1)
        let height = max(display.pointSize.height, 1)
        return CGRect(
            x: CGFloat(unit.x) * width,
            y: CGFloat(unit.y) * height,
            width: CGFloat(unit.width) * width,
            height: CGFloat(unit.height) * height)
    }

    /// Shift a global-AX frame down so its top edge sits at or below
    /// `visibleTopY` - the first row beneath the display's menu bar. macOS
    /// refuses to place a window above the menu bar and silently clamps it down
    /// to this line, so a saved or proportionally-remapped target above it is
    /// unreachable: the write "drifts" on every attempt and keeps getting
    /// re-triggered (and never records a moved-by-user baseline, so
    /// `respectManualMoves` can't suppress it). Clamping the target to what the
    /// OS will actually honour lets the placement settle.
    ///
    /// Size is preserved - macOS clamps by translation, not resize. Only the
    /// top is clamped; the OS imposes no equivalent limit on the other edges,
    /// and faithfully restoring an intentionally off-screen left/right/bottom
    /// position is a separate concern.
    public static func clampingBelowMenuBar(_ frame: CGRect, visibleTopY: CGFloat) -> CGRect {
        guard frame.minY < visibleTopY else { return frame }
        return CGRect(x: frame.minX, y: visibleTopY, width: frame.width, height: frame.height)
    }

    /// Move a global-AX frame from `source` onto `target`, keeping its size
    /// unless `resizedTo` supplies a new one. This is how a rule that restores
    /// a display without a saved position derives its target.
    ///
    /// `source` and `target` must come from the same `DisplayProbe` snapshot -
    /// the same-display check below is whole-struct equality, so fingerprints
    /// taken from different snapshots (different arrangement, different
    /// resolution) would compare unequal and lose the identity guarantee.
    ///
    /// Same display in and out with no resize is the identity, returned before
    /// any other work: a rule that restores only the display must leave a window
    /// already on its target display strictly alone, including one the user
    /// deliberately parked hanging off an edge. That guarantee is what lets the
    /// auto-replay suppression check skip such rules - see
    /// `PlacementHistoryStore.shouldSuppressAutoReplay`.
    ///
    /// A same-display *resize* keeps the window's origin but still clamps, since
    /// growing a window near an edge would otherwise push it off the panel
    /// entirely - the rule asked for a size, not for the window to leave.
    ///
    /// Across displays it's the window's *centre* that maps proportionally: a
    /// window centred 30% across and 40% down `source` ends up centred 30%
    /// across and 40% down `target`, keeping its size.
    ///
    /// Mapping the centre rather than the origin is what makes a window filling
    /// its display land centred on a bigger one. A maximised window's origin is
    /// (0, 0), which maps to (0, 0) on any display, so origin-mapping dumped it
    /// in the top-left corner at its old size. Its centre is (50%, 50%), which
    /// maps to the middle of the target. The same reasoning improves windows
    /// near the right or bottom edges, whose origin sits well inside the
    /// display even though the window doesn't.
    ///
    /// The result is clamped so the window sits fully within the target -
    /// otherwise a window near the edge of a wide panel would hang off a narrow
    /// one. A window larger than the target on an axis is pinned to that edge
    /// rather than shrunk: the only size this applies is the one the caller
    /// asked for.
    public static func moving(
        _ global: CGRect,
        onto target: DisplayFingerprint,
        from source: DisplayFingerprint,
        resizedTo newSize: CGSize? = nil) -> CGRect
    {
        let size = newSize ?? global.size
        if source == target {
            guard size != global.size else { return global }
            return clampedOnto(target, origin: CGPoint(
                x: global.minX - target.globalOrigin.x,
                y: global.minY - target.globalOrigin.y), size: size)
        }

        let sourceWidth = max(source.pointSize.width, 1)
        let sourceHeight = max(source.pointSize.height, 1)
        let localCentre = CGPoint(
            x: global.midX - source.globalOrigin.x,
            y: global.midY - source.globalOrigin.y)
        // Multiply before dividing: keeps whole-point arithmetic exact for the
        // common case where the two panels are simple multiples of each other.
        let mappedCentre = CGPoint(
            x: localCentre.x * target.pointSize.width / sourceWidth,
            y: localCentre.y * target.pointSize.height / sourceHeight)
        let mappedOrigin = CGPoint(
            x: mappedCentre.x - size.width / 2,
            y: mappedCentre.y - size.height / 2)

        return clampedOnto(target, origin: mappedOrigin, size: size)
    }

    /// Place `size` at a display-local `origin`, clamped so the window sits
    /// fully within `target`, and convert back to global AX space.
    private static func clampedOnto(
        _ target: DisplayFingerprint,
        origin: CGPoint,
        size: CGSize) -> CGRect
    {
        let clamped = CGPoint(
            x: clamp(origin.x, upperBound: target.pointSize.width - size.width),
            y: clamp(origin.y, upperBound: target.pointSize.height - size.height))
        return CGRect(origin: clamped, size: size)
            .offsetBy(dx: target.globalOrigin.x, dy: target.globalOrigin.y)
    }

    /// Clamp to `0...upperBound`, collapsing to 0 when the bound is negative
    /// (the window is larger than the display on that axis).
    private static func clamp(_ value: CGFloat, upperBound: CGFloat) -> CGFloat {
        guard upperBound > 0 else { return 0 }
        return min(max(value, 0), upperBound)
    }

    /// Pick the display whose bounds contain the greatest area of the given
    /// global-space rect. Used at save time to attribute a window to a
    /// display.
    public static func displayContaining(
        _ global: CGRect,
        among displays: [DisplayFingerprint]) -> DisplayFingerprint?
    {
        guard !displays.isEmpty else { return nil }
        // Reject garbage frames (null / non-finite) up front. Without this a
        // corrupt save rect intersects to area 0 everywhere, leaves best nil,
        // and falls through to the primary-display last resort, silently
        // persisting the corruption against primary. Fail closed instead.
        guard !global.isNull, !global.isInfinite,
              global.origin.x.isFinite, global.origin.y.isFinite,
              global.size.width.isFinite, global.size.height.isFinite
        else { return nil }

        var best: (display: DisplayFingerprint, overlap: CGFloat)?
        for display in displays {
            let bounds = CGRect(origin: display.globalOrigin, size: display.pointSize)
            let intersection = bounds.intersection(global)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            if area > 0, area > (best?.overlap ?? -1) {
                best = (display, area)
            }
        }

        if let best {
            return best.display
        }
        // No overlap at all: pick primary as a last resort so save still
        // produces something.
        return displays.first(where: { $0.isPrimary }) ?? displays.first
    }
}
