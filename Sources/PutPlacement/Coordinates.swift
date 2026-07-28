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
