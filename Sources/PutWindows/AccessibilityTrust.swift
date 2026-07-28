import ApplicationServices
import Foundation
import OSLog
import PutCore

/// Wraps the global Accessibility-trust check and the deep-link to System
/// Settings. Designed to be idempotent: the system prompt is requested at
/// most once per process lifetime even if the helper is called repeatedly.
public enum AccessibilityTrust {
    private static let log = PutLog.logger(category: "ax.trust")
    // swiftlint:disable:next modifier_order
    private nonisolated(unsafe) static var hasPromptedThisLaunch = false
    private static let promptLock = NSLock()

    /// Silent trust check. Safe to call on every access without side effects.
    public static var isTrusted: Bool {
        AXIsProcessTrustedWithOptions(nil)
    }

    /// Shows the system prompt at most once per launch. Subsequent calls
    /// within the same process are no-ops so the user never sees the dialog
    /// twice for the same session.
    @discardableResult
    public static func promptIfNeeded() -> Bool {
        promptLock.lock()
        defer { promptLock.unlock() }
        if hasPromptedThisLaunch {
            return isTrusted
        }
        hasPromptedThisLaunch = true
        // `kAXTrustedCheckOptionPrompt` is a global CFStringRef flagged by
        // Swift 6 strict concurrency. Its documented value is the literal
        // below; hardcoding avoids the cross-module global reference.
        let options: CFDictionary = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        log.info("Accessibility trust prompt shown; trusted=\(trusted, privacy: .public)")
        return trusted
    }

    /// URL that opens System Settings straight to Privacy > Accessibility.
    public static let systemSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")!
}
