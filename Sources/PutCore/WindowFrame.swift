import CoreGraphics
import Foundation

/// The placement of a saved window captured in two complementary forms so the
/// placement engine can pick the right strategy at restore time.
///
/// `absolute` is the rect expressed in display-local logical coordinates
/// (top-left origin) at the time the rule was saved. When the current display
/// matches the saved `DisplayFingerprint` geometry exactly, this is replayed
/// verbatim and is pixel-perfect.
///
/// `normalised` is the same rect expressed as a unit-square ratio relative to
/// the same saved display. When the current display has a different
/// resolution, scale, or `Looks like` setting, this is denormalised onto the
/// target and produces a proportional placement.
public struct WindowFrame: Codable, Hashable, Sendable {
    public var absolute: CGRect
    public var normalised: UnitRect

    public init(absolute: CGRect, normalised: UnitRect) {
        self.absolute = absolute
        self.normalised = normalised
    }
}
