import Foundation
@testable import PutAutomation
@testable import PutCore
import Testing

@MainActor
@Suite("AppState")
struct AppStateTests {
    @Test
    func activeLayoutFallsBackWhenIDIsStale() {
        let defaultLayout = PutCore.Layout.defaultLayout()
        let config = Config(
            layouts: [defaultLayout],
            activeLayoutID: UUID())
        let state = AppState(config: config)
        #expect(state.activeLayout?.id == defaultLayout.id)
    }

    @Test
    func replaceActiveLayoutUpdatesByIDAndSetsActive() {
        let layout = PutCore.Layout.defaultLayout()
        let state = AppState(config: Config(layouts: [layout], activeLayoutID: layout.id))
        var modified = layout
        modified.name = "Coding"
        state.replaceActiveLayout(modified)
        #expect(state.config.layouts.first?.name == "Coding")
        #expect(state.config.activeLayoutID == modified.id)
    }

    @Test
    func queuedRuleIDsAreMutable() {
        let state = AppState(
            config: Config(layouts: [PutCore.Layout.defaultLayout()], activeLayoutID: UUID()),
            queuedRuleIDs: [])
        let ruleID = UUID()
        state.queuedRuleIDs.insert(ruleID)
        #expect(state.queuedRuleIDs.contains(ruleID))
    }
}
