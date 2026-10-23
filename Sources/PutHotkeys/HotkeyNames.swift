import KeyboardShortcuts
import PutCore

public extension KeyboardShortcuts.Name {
    /// Save the focused window as a rule that applies to every window of the
    /// frontmost app (bundle-wide).
    static let saveFocusedWindowAllApp = Self("saveFocusedWindowAllApp", initial: .init(.f5, modifiers: .shift))
    /// Save the focused window as a rule that applies only to windows with
    /// the same title. No default binding — users opt in.
    static let saveFocusedWindowTitleOnly = Self("saveFocusedWindowTitleOnly")
    static let restoreActiveWindow = Self("restoreActiveWindow", initial: .init(.f5))
    static let saveAllWindows = Self("saveAllWindows", initial: .init(.f6, modifiers: .shift))
    static let restoreAllWindows = Self("restoreAllWindows", initial: .init(.f6))
}

/// Translation between the `GlobalHotkeyName` enum in `PutCore` and the
/// strongly-typed `KeyboardShortcuts.Name` constants.
public enum GlobalHotkey {
    public static func shortcutName(for name: GlobalHotkeyName) -> KeyboardShortcuts.Name {
        switch name {
        case .saveFocusedWindowAllApp:
            .saveFocusedWindowAllApp
        case .saveFocusedWindowTitleOnly:
            .saveFocusedWindowTitleOnly
        case .restoreActiveWindow:
            .restoreActiveWindow
        case .saveAllWindows:
            .saveAllWindows
        case .restoreAllWindows:
            .restoreAllWindows
        }
    }
}
