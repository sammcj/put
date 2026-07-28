import AppKit
import Foundation

/// Tracks the most recently activated application that is not Put itself.
///
/// The Rules tab "+" (and Cmd-N) capture the focused window, but pressing them
/// makes a Put window frontmost, so "the focused window" is Put's own Settings
/// window. This observer remembers the app the user was in beforehand so the
/// capture can target that app's focused window instead.
///
/// `@MainActor` because `NSWorkspace` delivers its activation notifications on
/// the main thread. The `NotificationCenter`, notification name, own-bundle id,
/// and the notification-to-identity extractor are all injectable so the
/// recording logic is hermetically testable without the real `NSWorkspace`.
@MainActor
public final class ActivationHistory {
    /// The Sendable identity carried across the notification actor hop: enough
    /// to re-open the app's Accessibility element (`processID`) and to know
    /// which app it was (`bundleID`).
    public struct Activation: Sendable, Equatable {
        public let processID: pid_t
        public let bundleID: String

        public init(processID: pid_t, bundleID: String) {
            self.processID = processID
            self.bundleID = bundleID
        }
    }

    /// Pulls the activated app's identity out of an activation notification.
    /// Production reads the `NSRunningApplication` NSWorkspace attaches; tests
    /// inject their own so no `NSRunningApplication` is needed.
    public typealias Extractor = @Sendable (Notification) -> Activation?

    private let ownBundleID: String
    private let center: NotificationCenter
    private let notificationName: Notification.Name
    private let extract: Extractor
    private var observer: NSObjectProtocol?
    private var last: Activation?

    public init(
        ownBundleID: String = Bundle.main.bundleIdentifier ?? "",
        center: NotificationCenter = NSWorkspace.shared.notificationCenter,
        notificationName: Notification.Name = NSWorkspace.didActivateApplicationNotification,
        extract: @escaping Extractor = activationFromRunningApplication)
    {
        self.ownBundleID = ownBundleID
        self.center = center
        self.notificationName = notificationName
        self.extract = extract
    }

    /// The app the user was in before Put became frontmost, or nil if none has
    /// activated since `start()`.
    public var previousActiveApp: Activation? {
        last
    }

    /// Record an activation, ignoring Put's own so the history always points at
    /// the app the user was in before they brought a Put window forward.
    /// Synchronous and pure - the notification handler funnels into this and
    /// tests call it directly.
    public func record(_ activation: Activation) {
        guard activation.bundleID != ownBundleID else { return }
        last = activation
    }

    /// Begin observing activation notifications. Idempotent.
    public func start() {
        guard observer == nil else { return }
        let extract = extract
        observer = center.addObserver(
            forName: notificationName,
            object: nil,
            queue: .main)
        { [weak self] notification in
            guard let activation = extract(notification) else { return }
            // The observer is registered on `.main`, so this block already runs
            // on the main actor's executor. Record synchronously rather than
            // hopping through an unstructured Task: back-to-back activations
            // must record in arrival order, and independent Tasks give no such
            // guarantee (last-writer-wins would then point at the wrong app).
            MainActor.assumeIsolated { self?.record(activation) }
        }
    }

    /// Detach the observer. Call from `applicationWillTerminate`.
    public func stop() {
        if let observer {
            center.removeObserver(observer)
            self.observer = nil
        }
    }
}

/// Default extractor: read the `NSRunningApplication` NSWorkspace attaches to
/// its activation notification's user info. A top-level function so it stays
/// nonisolated and matches the non-isolated `Extractor` the notification block
/// runs, without inheriting `ActivationHistory`'s `@MainActor` isolation.
public func activationFromRunningApplication(_ notification: Notification) -> ActivationHistory.Activation? {
    guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
          let bundleID = app.bundleIdentifier
    else { return nil }
    return ActivationHistory.Activation(processID: app.processIdentifier, bundleID: bundleID)
}
