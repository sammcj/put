import Foundation

/// Well-known names for the four global hotkeys. Stored as strings so Core
/// stays decoupled from the `KeyboardShortcuts` package.
public enum GlobalHotkeyName: String, Codable, Hashable, Sendable, CaseIterable {
    /// Save the focused window as a rule that matches every window of that
    /// app (bundle-wide, no title filter). Default.
    case saveFocusedWindowAllApp
    /// Save the focused window as a rule that matches only windows with the
    /// same title. No default binding.
    case saveFocusedWindowTitleOnly
    case restoreActiveWindow
    case saveAllWindows
    case restoreAllWindows
}

public struct HotkeyBindings: Codable, Hashable, Sendable {
    /// Per-layout activation shortcuts. Key is `Layout.id.uuidString`, value
    /// is a `KeyboardShortcuts.Name` raw value. The shortcuts themselves are
    /// persisted by the `KeyboardShortcuts` package in `UserDefaults`; this
    /// map only tracks the association between layouts and shortcut names.
    public var layoutActivations: [String: String]

    public init(layoutActivations: [String: String] = [:]) {
        self.layoutActivations = layoutActivations
    }
}
