import CoreGraphics
import Foundation

/// Abstraction over `WindowProbe` so test fixtures can inject stub window
/// handles into `ActionCoordinator` without touching the real Accessibility
/// API. Production code uses `DefaultWindowProbe`, which forwards to the
/// static `WindowProbe` methods; tests can provide their own conformer.
public protocol WindowProbing: Sendable {
    func snapshot() -> [WindowHandle]
    func focusedWindow() -> WindowHandle?
    /// Focused window of the app with `pid`. Defaulted to `focusedWindow()` so
    /// existing test stubs keep working; production resolves the real per-pid
    /// window (see the Rules tab "+" capture path in `ActionCoordinator`).
    func focusedWindow(pid: pid_t, bundleID: String) -> WindowHandle?
    func windows(forBundleID bundleID: String) -> [WindowHandle]
    /// Bundle IDs owning a standard window on any Space (see `WindowProbe`).
    /// Defaulted so existing test stubs need no change; the default reports no
    /// off-Space windows, which simply disables the unreachable-window feature.
    func bundleIDsWithStandardWindows() -> Set<String>
}

public extension WindowProbing {
    func focusedWindow(pid _: pid_t, bundleID _: String) -> WindowHandle? {
        focusedWindow()
    }

    func bundleIDsWithStandardWindows() -> Set<String> {
        []
    }
}

/// Abstraction over `AccessibilityTrust.isTrusted` so test hosts can exercise
/// the `ActionCoordinator` public entry points without actually granting the
/// Put process Accessibility permission. Production code uses
/// `DefaultAccessibilityGate`.
public protocol AccessibilityGateProviding: Sendable {
    var isTrusted: Bool { get }
}

public struct DefaultAccessibilityGate: AccessibilityGateProviding {
    public init() {}
    public var isTrusted: Bool {
        AccessibilityTrust.isTrusted
    }
}

public struct DefaultWindowProbe: WindowProbing {
    public init() {}
    public func snapshot() -> [WindowHandle] {
        WindowProbe.snapshot()
    }

    public func focusedWindow() -> WindowHandle? {
        WindowProbe.focusedWindow()
    }

    public func focusedWindow(pid: pid_t, bundleID: String) -> WindowHandle? {
        WindowProbe.focusedWindow(pid: pid, bundleID: bundleID)
    }

    public func windows(forBundleID bundleID: String) -> [WindowHandle] {
        WindowProbe.windows(forBundleID: bundleID)
    }

    public func bundleIDsWithStandardWindows() -> Set<String> {
        WindowProbe.bundleIDsWithStandardWindows()
    }
}

/// Abstraction over `WindowMutator.setFrame`. Same rationale as
/// `WindowProbing`.
public protocol WindowMutating: Sendable {
    func setFrame(_ handle: WindowHandle, to frame: CGRect) throws
    func setSize(_ handle: WindowHandle, to size: CGSize) throws
    func setPosition(_ handle: WindowHandle, to origin: CGPoint) throws
    /// Navigation only: bring the window forward, switching Spaces to follow
    /// it. Best-effort, no persistent side effect, so it does not throw.
    func raise(_ handle: WindowHandle)
}

public struct DefaultWindowMutator: WindowMutating {
    public init() {}
    public func setFrame(_ handle: WindowHandle, to frame: CGRect) throws {
        try WindowMutator.setFrame(handle, to: frame)
    }

    public func setSize(_ handle: WindowHandle, to size: CGSize) throws {
        try WindowMutator.setSize(handle, to: size)
    }

    public func setPosition(_ handle: WindowHandle, to origin: CGPoint) throws {
        try WindowMutator.setPosition(handle, to: origin)
    }

    public func raise(_ handle: WindowHandle) {
        WindowMutator.raise(handle)
    }
}
