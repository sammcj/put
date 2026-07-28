import Foundation
import KeyboardShortcuts
import PutCore

/// Captures and restores the `KeyboardShortcuts` key bindings that live in
/// `UserDefaults` (outside `Config`) so a settings backup is complete.
///
/// Global shortcut names are derived from `GlobalHotkeyName.allCases`, so a new
/// global hotkey added to that enum is captured automatically with no change
/// here. Per-layout activation shortcuts are derived from the supplied layout
/// ids. Bindings are carried as `[Name.rawValue: jsonString]`, where the value
/// is the JSON the `KeyboardShortcuts` package itself persists, keeping the
/// backup envelope decoupled from the package's `Shortcut` type.
public enum ShortcutsBackup {
    /// All global shortcut names, derived from the Core enum.
    public static var globalNames: [KeyboardShortcuts.Name] {
        GlobalHotkeyName.allCases.map { GlobalHotkey.shortcutName(for: $0) }
    }

    @MainActor
    public static func capture(layoutIDs: [UUID]) -> [String: String] {
        let encoder = JSONEncoder()
        var result: [String: String] = [:]
        for name in names(forLayoutIDs: layoutIDs) {
            guard let shortcut = KeyboardShortcuts.getShortcut(for: name),
                  let data = try? encoder.encode(shortcut),
                  let json = String(data: data, encoding: .utf8)
            else { continue }
            result[name.rawValue] = json
        }
        return result
    }

    /// Apply captured bindings. Every name we know about (globals plus the
    /// supplied layout ids) is reconciled: a name present in `shortcuts` is set
    /// to that binding, a name absent from it is cleared. Pass the union of the
    /// pre-import and imported layout ids so stale per-layout bindings are
    /// cleared on a full restore.
    @MainActor
    public static func apply(_ shortcuts: [String: String], layoutIDs: [UUID]) {
        let decoder = JSONDecoder()
        for name in names(forLayoutIDs: layoutIDs) {
            if let json = shortcuts[name.rawValue],
               let data = json.data(using: .utf8),
               let shortcut = try? decoder.decode(KeyboardShortcuts.Shortcut.self, from: data)
            {
                KeyboardShortcuts.setShortcut(shortcut, for: name)
            } else {
                KeyboardShortcuts.setShortcut(nil, for: name)
            }
        }
    }

    private static func names(forLayoutIDs layoutIDs: [UUID]) -> [KeyboardShortcuts.Name] {
        globalNames + layoutIDs.map { KeyboardShortcuts.Name.layoutActivation(layoutID: $0) }
    }
}
