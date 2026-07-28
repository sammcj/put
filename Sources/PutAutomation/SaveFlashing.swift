import CoreGraphics
import Foundation

/// Presents a lightweight, transient visual confirmation at each saved
/// window's frame. The protocol keeps `ActionCoordinator` in `PutAutomation`
/// free of AppKit window-creation concerns — `PutUI` supplies the concrete
/// implementation.
@MainActor
public protocol SaveFlashing: Sendable {
    /// `rects` are global AX-space rectangles (top-left origin, primary
    /// display at 0,0). Implementors convert to screen coordinates
    /// themselves.
    func flash(rects: [CGRect])
}

public struct NoopSaveFlashing: SaveFlashing {
    public init() {}
    public func flash(rects: [CGRect]) {}
}
