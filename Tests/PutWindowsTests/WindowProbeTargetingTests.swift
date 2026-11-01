import AppKit
@testable import PutWindows
import Testing

/// Put's own windows must never be enumerated: AX calls into the calling
/// process run in-process on the caller's thread, so a restore from a detached
/// task would drive `NSWindow` off the main thread and trap.
struct WindowProbeTargetingTests {
    private let ownPID: pid_t = 100

    @Test
    func excludesOwnProcessEvenWhenRegular() {
        #expect(!WindowProbe.isTargetable(pid: ownPID, policy: .regular, bundleID: "net.smcleod.put", ownPID: ownPID))
    }

    @Test
    func acceptsOtherRegularApps() {
        #expect(WindowProbe.isTargetable(pid: 200, policy: .regular, bundleID: "org.mozilla.firefox", ownPID: ownPID))
    }

    @Test
    func rejectsAccessoryAndUnbundledApps() {
        #expect(!WindowProbe.isTargetable(pid: 200, policy: .accessory, bundleID: "com.example", ownPID: ownPID))
        #expect(!WindowProbe.isTargetable(pid: 200, policy: .regular, bundleID: nil, ownPID: ownPID))
    }
}
