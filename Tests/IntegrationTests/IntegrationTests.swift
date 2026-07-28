import Foundation
@testable import PutDisplay
@testable import PutPlacement
@testable import PutWindows
import Testing

private var integrationTestsEnabled: Bool {
    ProcessInfo.processInfo.environment["PUT_RUN_AX_TESTS"] == "1"
}

@MainActor
@Suite(
    "Display integration (PUT_RUN_AX_TESTS=1)",
    .disabled(if: !integrationTestsEnabled, "PUT_RUN_AX_TESTS not set"))
struct DisplayIntegrationTests {
    @Test
    func enumerationReturnsAtLeastOneDisplay() throws {
        let displays = try DisplayProbe.snapshot()
        #expect(!displays.isEmpty)
        #expect(displays.contains { $0.isPrimary })
    }

    @Test
    func primaryIsResolvable() throws {
        let displays = try DisplayProbe.snapshot()
        #expect(DisplayMatcher.primary(among: displays) != nil)
    }
}

@Suite(
    "Window integration (PUT_RUN_AX_TESTS=1)",
    .disabled(if: !integrationTestsEnabled, "PUT_RUN_AX_TESTS not set"))
struct WindowIntegrationTests {
    @Test
    func snapshotCompletesWithoutCrashing() {
        // When Accessibility is granted this returns non-empty; when not, it
        // returns empty but never throws.
        _ = WindowProbe.snapshot()
    }

    @Test
    func accessibilityTrustCheckIsObservable() {
        _ = AccessibilityTrust.isTrusted
    }
}
