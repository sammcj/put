import Foundation
import OSLog
import PutCore

/// Routes a relaunch of an already-running Put instance (Spotlight, Raycast,
/// Finder, `open -a Put`) to the Settings window. AppKit dispatches this via
/// `NSApplicationDelegate.applicationShouldHandleReopen`. Login-item launches
/// don't take this path - they go through `applicationDidFinishLaunching` on
/// the fresh process.
@MainActor
public final class RelaunchHandler {
    private let log: Logger = PutLog.logger(category: "app.relaunch")
    private let openSettings: @MainActor () -> Void

    public init(openSettings: @escaping @MainActor () -> Void) {
        self.openSettings = openSettings
    }

    /// Bring Settings forward. `hasVisibleWindows` reflects what AppKit knows
    /// about the app's own windows; we open Settings regardless because the
    /// user's intent in re-launching an accessory app is to access its UI.
    /// `SettingsWindowController.show()` is itself idempotent.
    public func handleRelaunch(hasVisibleWindows: Bool) {
        log.info("Relaunch received; hasVisibleWindows=\(hasVisibleWindows, privacy: .public)")
        openSettings()
    }
}
