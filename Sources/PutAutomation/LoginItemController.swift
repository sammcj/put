import AppKit
import Foundation
import Observation
import OSLog
import PutCore
import ServiceManagement

public enum LoginItemError: Error, Equatable {
    case registrationFailed(String)
    case unregistrationFailed(String)
}

/// Minimal seam over `LoginItemController` so the launch-at-login toggle logic
/// can be driven by a fake in tests. `LoginItemController` conforms as-is.
@MainActor
public protocol LoginItemToggling: AnyObject {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

/// Observable wrapper over `SMAppService.mainApp`. The app bundle must be
/// signed and in the user's Applications folder (or a trusted location) for
/// `SMAppService` to accept registration.
///
/// Caches the `isEnabled` state so SwiftUI views can bind to it without hitting
/// `SMAppService.mainApp.status` on every read. Refreshes after register /
/// unregister, and whenever the app becomes active (covers the case where the
/// user toggles the item from System Settings while Put is in the background).
@MainActor
@Observable
public final class LoginItemController {
    private static let log: Logger = PutLog.logger(category: "loginitem")

    public private(set) var isEnabled: Bool
    private var activationObserver: NSObjectProtocol?

    public init() {
        isEnabled = SMAppService.mainApp.status == .enabled
        // AppKit posts application-lifecycle notifications to
        // `NotificationCenter.default`; `NSWorkspace.shared.notificationCenter`
        // only delivers `NSWorkspace.*` notifications, so observing
        // `didBecomeActiveNotification` there never fires and the cached
        // `isEnabled` would go stale after a System Settings toggle.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main)
        { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Detach the activation observer. Call from `applicationWillTerminate`.
    /// We don't rely on `deinit` because it runs nonisolated and cannot
    /// reach the MainActor-owned observer token cleanly.
    public func stop() {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    public func refresh() {
        let now = SMAppService.mainApp.status == .enabled
        if now != isEnabled { isEnabled = now }
    }

    public func register() throws {
        do {
            try SMAppService.mainApp.register()
            Self.log.info("Login item registered")
            refresh()
        } catch {
            Self.log.error("Login item register failed: \(error.localizedDescription, privacy: .public)")
            throw LoginItemError.registrationFailed(error.localizedDescription)
        }
    }

    public func unregister() throws {
        do {
            try SMAppService.mainApp.unregister()
            Self.log.info("Login item unregistered")
            refresh()
        } catch {
            Self.log.error("Login item unregister failed: \(error.localizedDescription, privacy: .public)")
            throw LoginItemError.unregistrationFailed(error.localizedDescription)
        }
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled, !isEnabled {
            try register()
        } else if !enabled, isEnabled {
            try unregister()
        }
    }
}

extension LoginItemController: LoginItemToggling {}
