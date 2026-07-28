import CoreGraphics
import Foundation
import PutCore

/// Value snapshot of a window. Safe to carry across actor boundaries; does not
/// retain any live OS resources.
public struct WindowDescriptor: Hashable, Sendable {
    public var bundleID: String
    public var processID: pid_t
    public var title: String
    public var role: String?
    public var subrole: String?
    public var frame: CGRect
    public var isMinimised: Bool

    public init(
        bundleID: String,
        processID: pid_t,
        title: String,
        role: String?,
        subrole: String?,
        frame: CGRect,
        isMinimised: Bool)
    {
        self.bundleID = bundleID
        self.processID = processID
        self.title = title
        self.role = role
        self.subrole = subrole
        self.frame = frame
        self.isMinimised = isMinimised
    }
}
