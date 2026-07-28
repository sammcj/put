import CoreGraphics
import Foundation
import PutWindows

// Shared test doubles for the PutWindows seams (`WindowProbing`,
// `WindowMutating`, `AccessibilityGateProviding`). These were duplicated across
// every PutAutomation suite in variants that differed only in which calls they
// recorded, which let the copies drift. Each double here records everything the
// suites collectively assert on; a suite that doesn't care about a counter
// simply never reads it.
//
// Doubles for the PutAutomation-only seams (`SaveFlashing`,
// `SaveScopeNotifying`) deliberately stay local to their suites: hoisting them
// would make this target - which PutCoreTests and friends also depend on -
// import PutAutomation for the sake of two call sites.
//
// Names differ from the historical per-suite ones (`StubProbe`, `StubMutator`,
// `StubGate`) so a suite keeping a genuinely specialised local double, such as
// the thread-recording mutator, doesn't collide with the shared type.

/// Stub `WindowProbing` returning a canned handle list and counting each query.
/// `focusedWindow(pid:bundleID:)` and `bundleIDsWithStandardWindows()` keep the
/// protocol's default implementations.
public final class StubWindowProbe: WindowProbing, @unchecked Sendable {
    public let handles: [WindowHandle]
    public var snapshotCalls = 0
    public var focusedCalls = 0
    public var bundleCalls: [String] = []

    public init(handles: [WindowHandle] = []) {
        self.handles = handles
    }

    public func snapshot() -> [WindowHandle] {
        snapshotCalls += 1
        return handles
    }

    public func focusedWindow() -> WindowHandle? {
        focusedCalls += 1
        return handles.first
    }

    public func windows(forBundleID bundleID: String) -> [WindowHandle] {
        bundleCalls.append(bundleID)
        return handles.filter { $0.descriptor.bundleID == bundleID }
    }
}

/// Recording `WindowMutating` that performs no Accessibility work. Suites assert
/// on whichever of the three call logs their scenario exercises.
public final class RecordingWindowMutator: WindowMutating, @unchecked Sendable {
    public var frameCalls: [(WindowHandle, CGRect)] = []
    public var sizeCalls: [(WindowHandle, CGSize)] = []
    public var raiseCalls: [WindowHandle] = []

    public init() {}

    public func setFrame(_ handle: WindowHandle, to frame: CGRect) throws {
        frameCalls.append((handle, frame))
    }

    public func setSize(_ handle: WindowHandle, to size: CGSize) throws {
        sizeCalls.append((handle, size))
    }

    public func raise(_ handle: WindowHandle) {
        raiseCalls.append(handle)
    }
}

/// Stub accessibility gate. Trusted by default; pass `trusted: false` to drive
/// the permission-denied branches.
public struct StubAccessibilityGate: AccessibilityGateProviding {
    public let trusted: Bool

    public init(trusted: Bool = true) {
        self.trusted = trusted
    }

    public var isTrusted: Bool {
        trusted
    }
}
