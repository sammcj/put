import AppKit
import Foundation
@testable import PutWindows
import Testing

private var axTestsEnabled: Bool {
    ProcessInfo.processInfo.environment["PUT_RUN_AX_TESTS"] == "1"
}

/// End-to-end capture of a real app's focused window by pid. AX-dependent, so
/// gated on `PUT_RUN_AX_TESTS=1`; reported as skipped otherwise (never a
/// vacuous pass).
@MainActor
@Suite(
    "WindowProbe pid capture (PUT_RUN_AX_TESTS=1)",
    .disabled(if: !axTestsEnabled, "PUT_RUN_AX_TESTS not set"))
struct WindowProbePidCaptureTests {
    @Test
    func pidVariantAgreesWithFrontmost() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier
        else {
            Issue.record("No frontmost application available in the test session")
            return
        }
        let viaPid = WindowProbe.focusedWindow(pid: app.processIdentifier, bundleID: bundleID)
        let viaFrontmost = WindowProbe.focusedWindow()
        // The frontmost app resolved two ways: both nil when Accessibility is
        // not granted, the same window's descriptor when it is. Neither crashes.
        #expect(viaPid?.descriptor.processID == viaFrontmost?.descriptor.processID)
        #expect(viaPid?.descriptor.bundleID == viaFrontmost?.descriptor.bundleID)
    }
}
