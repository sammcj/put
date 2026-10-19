import AppKit
import ApplicationServices
import Foundation
import OSLog
import PutCore

/// Whether Mission Control currently owns the screen. A seam so restore gating
/// can be tested without a live Dock.
@MainActor
public protocol MissionControlStateProviding: AnyObject {
    /// True while Mission Control, App Exposé or Show Desktop is showing.
    var isMissionControlActive: Bool { get }
}

/// Enter/exit bookkeeping for the Dock's Exposé notifications, split from the
/// AX plumbing so it is testable.
///
/// The Dock posts no exit for some paths out of Mission Control (a Dock crash,
/// sleep while it is open), so an entry expires after `staleAfter`. Without
/// that, one missed exit would pause automatic restores until Put relaunched.
public struct MissionControlState: Equatable, Sendable {
    /// Undocumented Dock AX notifications, as observed by yabai and TrellisWM.
    public static let enterNotifications: Set = [
        "AXExposeShowAllWindows",
        "AXExposeShowFrontWindows",
        "AXExposeShowDesktop"
    ]
    public static let exitNotification = "AXExposeExit"
    public static let staleAfter: TimeInterval = 120

    private var enteredAt: Date?

    public init() {}

    public mutating func handle(_ notification: String, at now: Date) {
        if Self.enterNotifications.contains(notification) {
            enteredAt = now
        } else if notification == Self.exitNotification {
            enteredAt = nil
        }
    }

    public mutating func reset() {
        enteredAt = nil
    }

    public func isActive(at now: Date) -> Bool {
        guard let enteredAt else { return false }
        return now.timeIntervalSince(enteredAt) < Self.staleAfter
    }
}

/// Tracks Mission Control by observing the Dock's AX notifications.
///
/// A geometry write landing while Mission Control is open applies to the
/// thumbnail layout macOS is animating, then gets overridden on exit, so
/// automatic restores hold off until it closes.
///
/// The attachment is reconciled against the live Dock pid on every read rather
/// than from workspace launch notifications, which macOS doesn't post for
/// `LSUIElement` apps like the Dock. That covers `killall Dock`, a Dock crash,
/// and Accessibility trust arriving after launch. A pid that refused the
/// notifications isn't retried until the Dock relaunches.
@MainActor
public final class MissionControlObserver: MissionControlStateProviding {
    private static let dockBundleID = "com.apple.dock"

    private let log = PutLog.logger(category: "windows.missionControl")
    private var state = MissionControlState()
    private var axObserver: AXObserver?
    private var attachedPID: pid_t?
    private var refusedPID: pid_t?
    /// Retained while attached so a callback can never reach a freed observer.
    private var retainedSelf: Unmanaged<MissionControlObserver>?

    public init() {}

    public var isMissionControlActive: Bool {
        reconcileAttachment()
        return state.isActive(at: Date())
    }

    public func start() {
        reconcileAttachment()
    }

    public func stop() {
        detach()
    }

    fileprivate func handle(_ notification: String) {
        let wasActive = state.isActive(at: Date())
        state.handle(notification, at: Date())
        let isActive = state.isActive(at: Date())
        if wasActive != isActive {
            log
                .info(
                    "Mission Control \(isActive ? "opened" : "closed", privacy: .public) (\(notification, privacy: .public))")
        }
    }

    private func reconcileAttachment() {
        let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: Self.dockBundleID)
            .first { !$0.isTerminated }?.processIdentifier
        if let attachedPID, attachedPID != dockPID {
            log.info("Dock pid \(attachedPID, privacy: .public) gone; re-attaching")
            detach()
        }
        guard attachedPID == nil, let dockPID, dockPID != refusedPID, AXIsProcessTrusted() else { return }
        attach(to: dockPID)
    }

    private func attach(to pid: pid_t) {
        var created: AXObserver?
        guard AXObserverCreate(pid, missionControlCallback, &created) == .success, let created else {
            refusedPID = pid
            log.error("AXObserverCreate failed for Dock pid \(pid, privacy: .public)")
            return
        }
        let retained = Unmanaged.passRetained(self)
        let dockElement = AXUIElementCreateApplication(pid)
        let names = MissionControlState.enterNotifications.union([MissionControlState.exitNotification])
        let registered = names.filter {
            AXObserverAddNotification(created, dockElement, $0 as CFString, retained.toOpaque()) == .success
        }
        // Without the exit notification an entry could only end by expiring, so
        // a partial registration is worse than none.
        guard registered.contains(MissionControlState.exitNotification), registered.count > 1 else {
            retained.release()
            refusedPID = pid
            log.error("Dock refused Mission Control notifications; restores won't wait for it")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        axObserver = created
        attachedPID = pid
        retainedSelf = retained
        log.info("Observing Mission Control via Dock pid \(pid, privacy: .public)")
    }

    private func detach() {
        if let axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .commonModes)
        }
        axObserver = nil
        attachedPID = nil
        retainedSelf?.release()
        retainedSelf = nil
        state.reset()
    }
}

/// AX delivers on the run loop the source was added to, which is the main one.
private func missionControlCallback(
    _: AXObserver,
    _: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?)
{
    guard let refcon else { return }
    let observer = Unmanaged<MissionControlObserver>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    MainActor.assumeIsolated {
        observer.handle(name)
    }
}
