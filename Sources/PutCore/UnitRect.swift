import CoreGraphics
import Foundation

/// A rectangle expressed in the unit square [0, 1] x [0, 1] of some reference
/// frame, used as a display-independent fallback when a stored absolute rect
/// cannot be replayed onto the current arrangement.
public struct UnitRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let zero = UnitRect(x: 0, y: 0, width: 0, height: 0)
    public static let full = UnitRect(x: 0, y: 0, width: 1, height: 1)

    /// True when every component lies within [0, 1].
    public var isNormalised: Bool {
        (0.0...1.0).contains(x)
            && (0.0...1.0).contains(y)
            && (0.0...1.0).contains(width)
            && (0.0...1.0).contains(height)
    }

    /// Clamp into [0, 1] so x + width <= 1 and y + height <= 1, keeping the
    /// proportional fallback on-display. The extent is clamped first (a window
    /// can be no larger than its display), then the origin slides to make room.
    /// Sliding preserves the window's size where it fits, matching
    /// `clampingBelowMenuBar`; only a rect genuinely wider or taller than the
    /// display shrinks.
    public func clamped() -> UnitRect {
        let clampedWidth = min(max(width, 0), 1)
        let clampedHeight = min(max(height, 0), 1)
        return UnitRect(
            x: min(max(x, 0), 1 - clampedWidth),
            y: min(max(y, 0), 1 - clampedHeight),
            width: clampedWidth,
            height: clampedHeight)
    }
}
