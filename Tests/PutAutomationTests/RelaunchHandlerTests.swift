import Foundation
@testable import PutAutomation
import Testing

@MainActor
@Suite("RelaunchHandler")
struct RelaunchHandlerTests {
    @Test
    func handleRelaunchOpensSettings() {
        var calls = 0
        let handler = RelaunchHandler(openSettings: { calls += 1 })

        handler.handleRelaunch(hasVisibleWindows: false)

        #expect(calls == 1)
    }

    @Test
    func handleRelaunchOpensSettingsEvenWhenWindowsVisible() {
        var calls = 0
        let handler = RelaunchHandler(openSettings: { calls += 1 })

        handler.handleRelaunch(hasVisibleWindows: true)

        #expect(calls == 1)
    }

    @Test
    func repeatedRelaunchesEachInvokeOpenSettings() {
        var calls = 0
        let handler = RelaunchHandler(openSettings: { calls += 1 })

        handler.handleRelaunch(hasVisibleWindows: false)
        handler.handleRelaunch(hasVisibleWindows: true)
        handler.handleRelaunch(hasVisibleWindows: false)

        #expect(calls == 3)
    }
}
