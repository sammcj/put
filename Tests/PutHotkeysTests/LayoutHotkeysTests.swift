import Foundation
import KeyboardShortcuts
@testable import PutHotkeys
import Testing

@MainActor
@Suite("LayoutHotkeys")
struct LayoutHotkeysTests {
    /// Records every call the LayoutHotkeys client makes so the test can
    /// assert the exact sequence without invoking the real module-global
    /// `KeyboardShortcuts` registry.
    private final class RecordingRegistry: KeyboardShortcutsRegistering {
        enum Call: Equatable {
            case enable(String)
            case disable(String)
            case removeHandler(String)
            case onKeyUp(String)
        }

        private(set) var calls: [Call] = []
        private(set) var handlers: [String: () -> Void] = [:]

        func enable(_ name: KeyboardShortcuts.Name) {
            calls.append(.enable(name.rawValue))
        }

        func disable(_ name: KeyboardShortcuts.Name) {
            calls.append(.disable(name.rawValue))
        }

        func removeHandler(for name: KeyboardShortcuts.Name) {
            calls.append(.removeHandler(name.rawValue))
            handlers[name.rawValue] = nil
        }

        func onKeyUp(for name: KeyboardShortcuts.Name, action: @escaping () -> Void) {
            calls.append(.onKeyUp(name.rawValue))
            handlers[name.rawValue] = action
        }

        func fire(_ name: KeyboardShortcuts.Name) {
            handlers[name.rawValue]?()
        }
    }

    private func key(for id: UUID) -> String {
        "layout.\(id.uuidString)"
    }

    @Test
    func initialSyncEnablesEachLayoutAndRegistersHandler() {
        let registry = RecordingRegistry()
        let hotkeys = LayoutHotkeys(registry: registry)
        let first = UUID()
        let second = UUID()

        hotkeys.syncRegistrations(layoutIDs: [first, second])

        let enabled = registry.calls.filter {
            if case .enable = $0 { true } else { false }
        }
        let registered = registry.calls.filter {
            if case .onKeyUp = $0 { true } else { false }
        }
        #expect(enabled.count == 2)
        #expect(registered.count == 2)
        #expect(enabled.contains(.enable(key(for: first))))
        #expect(enabled.contains(.enable(key(for: second))))
        #expect(registered.contains(.onKeyUp(key(for: first))))
        #expect(registered.contains(.onKeyUp(key(for: second))))
    }

    @Test
    func removedLayoutIsDisabledAndHandlerDetached() {
        let registry = RecordingRegistry()
        let hotkeys = LayoutHotkeys(registry: registry)
        let first = UUID()
        let second = UUID()

        hotkeys.syncRegistrations(layoutIDs: [first, second])
        hotkeys.syncRegistrations(layoutIDs: [first])

        let teardown = registry.calls.suffix(2)
        #expect(teardown.contains(.disable(key(for: second))))
        #expect(teardown.contains(.removeHandler(key(for: second))))
        // The remaining layout wasn't touched on the second sync.
        #expect(!teardown.contains(.disable(key(for: first))))
    }

    @Test
    func secondSyncWithSameIDsIsNoop() {
        let registry = RecordingRegistry()
        let hotkeys = LayoutHotkeys(registry: registry)
        let only = UUID()

        hotkeys.syncRegistrations(layoutIDs: [only])
        let callsAfterFirst = registry.calls.count
        hotkeys.syncRegistrations(layoutIDs: [only])

        #expect(registry.calls.count == callsAfterFirst)
    }

    @Test
    func keyUpDispatchesActivatorWithLayoutID() {
        let registry = RecordingRegistry()
        let hotkeys = LayoutHotkeys(registry: registry)
        var dispatched: [UUID] = []
        hotkeys.bind { id in dispatched.append(id) }

        let first = UUID()
        let second = UUID()
        hotkeys.syncRegistrations(layoutIDs: [first, second])

        registry.fire(.layoutActivation(layoutID: first))
        registry.fire(.layoutActivation(layoutID: second))
        registry.fire(.layoutActivation(layoutID: first))

        #expect(dispatched == [first, second, first])
    }

    @Test
    func removeAllTearsDownEveryKnownLayout() {
        let registry = RecordingRegistry()
        let hotkeys = LayoutHotkeys(registry: registry)
        let ids = [UUID(), UUID(), UUID()]
        hotkeys.syncRegistrations(layoutIDs: ids)

        hotkeys.removeAll()

        for id in ids {
            let name = key(for: id)
            #expect(registry.calls.contains(.disable(name)))
            #expect(registry.calls.contains(.removeHandler(name)))
        }
        // Subsequent sync with the same IDs should re-add them rather than
        // consider them still known.
        let countBefore = registry.calls.count
        hotkeys.syncRegistrations(layoutIDs: ids)
        #expect(registry.calls.count > countBefore)
    }

    @Test
    func defaultRegistryCanBeConstructed() {
        _ = DefaultKeyboardShortcutsRegistry()
    }
}
