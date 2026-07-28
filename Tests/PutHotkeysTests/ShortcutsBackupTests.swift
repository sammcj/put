import Foundation
import KeyboardShortcuts
import PutCore
@testable import PutHotkeys
import Testing

@MainActor
@Suite("ShortcutsBackup")
struct ShortcutsBackupTests {
    @Test
    func globalNamesCoverEveryGlobalHotkey() {
        // Adding a case to GlobalHotkeyName should flow into backups with no
        // change to ShortcutsBackup; this guards that derivation.
        let derived = Set(ShortcutsBackup.globalNames.map(\.rawValue))
        let expected = Set(GlobalHotkeyName.allCases.map(\.rawValue))
        #expect(derived == expected)
    }

    @Test
    func captureThenApplyRoundTripsAPerLayoutBinding() {
        let layoutID = UUID()
        let name = KeyboardShortcuts.Name.layoutActivation(layoutID: layoutID)
        defer { KeyboardShortcuts.setShortcut(nil, for: name) }

        let shortcut = KeyboardShortcuts.Shortcut(.k, modifiers: [.command, .option])
        KeyboardShortcuts.setShortcut(shortcut, for: name)

        let captured = ShortcutsBackup.capture(layoutIDs: [layoutID])
        #expect(captured[name.rawValue] != nil)

        // Wipe, then restore from the captured dict.
        KeyboardShortcuts.setShortcut(nil, for: name)
        #expect(KeyboardShortcuts.getShortcut(for: name) == nil)

        ShortcutsBackup.apply(captured, layoutIDs: [layoutID])
        #expect(KeyboardShortcuts.getShortcut(for: name) == shortcut)
    }

    @Test
    func applyClearsBindingsAbsentFromBackup() {
        let layoutID = UUID()
        let name = KeyboardShortcuts.Name.layoutActivation(layoutID: layoutID)
        defer { KeyboardShortcuts.setShortcut(nil, for: name) }

        KeyboardShortcuts.setShortcut(KeyboardShortcuts.Shortcut(.j), for: name)
        // The backup has no entry for this layout, so a full restore should
        // clear it rather than leave the stale binding.
        ShortcutsBackup.apply([:], layoutIDs: [layoutID])
        #expect(KeyboardShortcuts.getShortcut(for: name) == nil)
    }
}
