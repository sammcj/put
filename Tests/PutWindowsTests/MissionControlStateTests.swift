import Foundation
@testable import PutWindows
import Testing

@Suite("MissionControlState")
struct MissionControlStateTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func inactiveUntilAnEntryNotification() {
        var state = MissionControlState()
        #expect(!state.isActive(at: start))
        state.handle("AXFocusedWindowChanged", at: start)
        #expect(!state.isActive(at: start))
    }

    @Test(arguments: ["AXExposeShowAllWindows", "AXExposeShowFrontWindows", "AXExposeShowDesktop"])
    func eachEntryActivatesAndExitClears(entry: String) {
        var state = MissionControlState()
        state.handle(entry, at: start)
        #expect(state.isActive(at: start.addingTimeInterval(1)))
        state.handle(MissionControlState.exitNotification, at: start.addingTimeInterval(2))
        #expect(!state.isActive(at: start.addingTimeInterval(2)))
    }

    @Test
    func missedExitExpires() {
        var state = MissionControlState()
        state.handle("AXExposeShowAllWindows", at: start)
        #expect(state.isActive(at: start.addingTimeInterval(MissionControlState.staleAfter - 1)))
        #expect(!state.isActive(at: start.addingTimeInterval(MissionControlState.staleAfter)))
    }

    @Test
    func switchingModesRefreshesTheEntry() {
        // Mission Control -> App Exposé without an exit in between.
        var state = MissionControlState()
        state.handle("AXExposeShowAllWindows", at: start)
        let later = start.addingTimeInterval(MissionControlState.staleAfter - 10)
        state.handle("AXExposeShowFrontWindows", at: later)
        #expect(state.isActive(at: start.addingTimeInterval(MissionControlState.staleAfter + 5)))
    }

    @Test
    func resetClears() {
        var state = MissionControlState()
        state.handle("AXExposeShowDesktop", at: start)
        state.reset()
        #expect(!state.isActive(at: start))
    }
}
