import Foundation
@testable import PutAutomation
@testable import PutCore
import Testing

@MainActor
private final class FakeLoginItem: LoginItemToggling {
    private(set) var isEnabled: Bool
    var errorToThrow: Error?
    private(set) var setEnabledCalls: [Bool] = []

    init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }

    func setEnabled(_ enabled: Bool) throws {
        setEnabledCalls.append(enabled)
        if let errorToThrow { throw errorToThrow }
        isEnabled = enabled
    }
}

@MainActor
@Suite("AppState.applyLaunchAtLogin")
struct LoginItemTogglingTests {
    private func makeState() -> AppState {
        AppState(config: Config(layouts: [PutCore.Layout.defaultLayout()], activeLayoutID: UUID()))
    }

    @Test
    func successMirrorsConfigClearsErrorAndPersists() {
        let state = makeState()
        let loginItem = FakeLoginItem(isEnabled: false)
        var persistCount = 0

        let error = state.applyLaunchAtLogin(true, loginItem: loginItem, onChange: { persistCount += 1 })

        #expect(error == nil)
        #expect(loginItem.setEnabledCalls == [true])
        #expect(loginItem.isEnabled)
        #expect(state.config.launchAtLogin)
        #expect(persistCount == 1)
    }

    @Test
    func failureReturnsMessageLeavesConfigAndSkipsPersist() {
        let state = makeState()
        let before = state.config.launchAtLogin
        let loginItem = FakeLoginItem(isEnabled: false)
        loginItem.errorToThrow = LoginItemError.registrationFailed("nope")
        var persistCount = 0

        let error = state.applyLaunchAtLogin(true, loginItem: loginItem, onChange: { persistCount += 1 })

        #expect(error == LoginItemError.registrationFailed("nope").localizedDescription)
        #expect(state.config.launchAtLogin == before)
        #expect(persistCount == 0)
        // The GeneralTab toggle renders `loginItem.isEnabled`; a failed enable
        // must leave it false so the switch does not flip on despite the error.
        #expect(loginItem.isEnabled == false)
    }
}
