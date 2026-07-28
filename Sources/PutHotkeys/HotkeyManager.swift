import Foundation
import KeyboardShortcuts
import OSLog
import PutCore

/// Wires global hotkeys to handlers. Call `bind(handlers:)` once on launch
/// after Accessibility has been granted. Handlers are invoked on the main
/// thread.
@MainActor
public final class HotkeyManager {
    public struct Handlers {
        public var saveFocusedWindowAllApp: () -> Void
        public var saveFocusedWindowTitleOnly: () -> Void
        public var restoreActiveWindow: () -> Void
        public var saveAllWindows: () -> Void
        public var restoreAllWindows: () -> Void

        public init(
            saveFocusedWindowAllApp: @escaping () -> Void,
            saveFocusedWindowTitleOnly: @escaping () -> Void,
            restoreActiveWindow: @escaping () -> Void,
            saveAllWindows: @escaping () -> Void,
            restoreAllWindows: @escaping () -> Void)
        {
            self.saveFocusedWindowAllApp = saveFocusedWindowAllApp
            self.saveFocusedWindowTitleOnly = saveFocusedWindowTitleOnly
            self.restoreActiveWindow = restoreActiveWindow
            self.saveAllWindows = saveAllWindows
            self.restoreAllWindows = restoreAllWindows
        }
    }

    private let log: Logger = PutLog.logger(category: "hotkeys")

    public init() {}

    public func bind(handlers: Handlers) {
        KeyboardShortcuts.onKeyUp(for: .saveFocusedWindowAllApp) { [log] in
            log.info("Hotkey: saveFocusedWindowAllApp")
            handlers.saveFocusedWindowAllApp()
        }
        KeyboardShortcuts.onKeyUp(for: .saveFocusedWindowTitleOnly) { [log] in
            log.info("Hotkey: saveFocusedWindowTitleOnly")
            handlers.saveFocusedWindowTitleOnly()
        }
        KeyboardShortcuts.onKeyUp(for: .restoreActiveWindow) { [log] in
            log.info("Hotkey: restoreActiveWindow")
            handlers.restoreActiveWindow()
        }
        KeyboardShortcuts.onKeyUp(for: .saveAllWindows) { [log] in
            log.info("Hotkey: saveAllWindows")
            handlers.saveAllWindows()
        }
        KeyboardShortcuts.onKeyUp(for: .restoreAllWindows) { [log] in
            log.info("Hotkey: restoreAllWindows")
            handlers.restoreAllWindows()
        }
    }

    /// Disable all bindings. Useful during Accessibility prompts or tests.
    public func unbind() {
        KeyboardShortcuts.removeAllHandlers()
    }
}
