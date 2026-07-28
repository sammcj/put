import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OSLog
import PutCore

/// Accessibility-driven enumeration of live windows.
///
/// All functions are synchronous and safe to call from any thread; the
/// underlying Accessibility APIs route internally. Callers that care about
/// main-thread responsiveness should dispatch these onto a background queue,
/// since enumerating AX attributes across many apps can take tens of
/// milliseconds.
public enum WindowProbe {
    private static let log = PutLog.logger(category: "windows.probe")

    /// Snapshot every visible window belonging to a regular running app.
    /// Requires Accessibility permission; returns an empty array if not
    /// granted.
    public static func snapshot() -> [WindowHandle] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .flatMap { windows(in: $0) }
    }

    /// The single focused window of the frontmost application, if any.
    public static func focusedWindow() -> WindowHandle? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier
        else { return nil }
        return focusedWindow(pid: app.processIdentifier, bundleID: bundleID)
    }

    /// The single focused window of the app with `pid`, if any. Lets a caller
    /// target an app that is not frontmost - the Rules tab "+" needs the app the
    /// user was in before Put's Settings window took focus. Same XPC-blocking
    /// caveat as `focusedWindow()`; callers dispatch it off the main actor.
    public static func focusedWindow(pid: pid_t, bundleID: String) -> WindowHandle? {
        let appElement = AXUIElementCreateApplication(pid)
        // Accessibility returns an AXUIElement bridged as CFTypeRef.
        guard let focused = copyAttribute(appElement, kAXFocusedWindowAttribute),
              let windowElement = axDowncast(focused, to: AXUIElement.self, ifTypeID: AXUIElementGetTypeID())
        else { return nil }
        let descriptor = describe(window: windowElement, bundleID: bundleID, pid: pid)
        return WindowHandle(descriptor: descriptor, axElement: windowElement, appElement: appElement)
    }

    /// Every window of every regular app whose bundle ID matches.
    public static func windows(forBundleID bundleID: String) -> [WindowHandle] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier == bundleID }
            .flatMap { windows(in: $0) }
    }

    /// Bundle IDs of regular apps owning at least one standard window across
    /// *all* Mission Control Spaces. `kAXWindowsAttribute` only reports the
    /// current Space, so this is the signal that tells a window exiled to
    /// another Space (present here, absent from the AX snapshot) apart from one
    /// that's simply closed (absent from both). Reads only window metadata
    /// (owner PID, layer, bounds), so it needs no Screen Recording permission.
    public static func bundleIDsWithStandardWindows() -> Set<String> {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var pids: Set<pid_t> = []
        for info in infos {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
            guard standardSized(info) else { continue }
            pids.insert(pid)
        }
        guard !pids.isEmpty else { return [] }
        var bundleByPID: [pid_t: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let bundleID = app.bundleIdentifier { bundleByPID[app.processIdentifier] = bundleID }
        }
        return Set(pids.compactMap { bundleByPID[$0] })
    }

    /// Reject trivial helper/utility windows (tooltips, status overlays) so a
    /// stray off-screen helper can't read as a stranded document window.
    private static func standardSized(_ info: [String: Any]) -> Bool {
        guard let boundsDict = info[kCGWindowBounds as String] else { return true }
        guard CFGetTypeID(boundsDict as CFTypeRef) == CFDictionaryGetTypeID() else { return true }
        var rect = CGRect.zero
        // swiftlint:disable:next force_cast
        guard CGRectMakeWithDictionaryRepresentation(boundsDict as! CFDictionary, &rect) else { return true }
        return rect.width >= 80 && rect.height >= 80
    }

    // MARK: - Private

    private static func windows(in app: NSRunningApplication) -> [WindowHandle] {
        guard let bundleID = app.bundleIdentifier else { return [] }
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        guard let rawWindows = copyAttribute(appElement, kAXWindowsAttribute) else {
            return []
        }
        guard let array = rawWindows as? [AXUIElement] else {
            log.debug("kAXWindowsAttribute for \(bundleID, privacy: .public) was not an array")
            return []
        }
        return array.map { windowElement in
            let descriptor = describe(window: windowElement, bundleID: bundleID, pid: pid)
            return WindowHandle(descriptor: descriptor, axElement: windowElement, appElement: appElement)
        }
    }

    private static func describe(window: AXUIElement, bundleID: String, pid: pid_t) -> WindowDescriptor {
        let title = (copyAttribute(window, kAXTitleAttribute) as? String) ?? ""
        let role = copyAttribute(window, kAXRoleAttribute) as? String
        let subrole = copyAttribute(window, kAXSubroleAttribute) as? String
        let frame = readFrame(of: window)
        let minimised = (copyAttribute(window, kAXMinimizedAttribute) as? Bool) ?? false

        return WindowDescriptor(
            bundleID: bundleID,
            processID: pid,
            title: title,
            role: role,
            subrole: subrole,
            frame: frame,
            isMinimised: minimised)
    }

    private static func readFrame(of window: AXUIElement) -> CGRect {
        let origin = readCGPoint(window, kAXPositionAttribute) ?? .zero
        let size = readCGSize(window, kAXSizeAttribute) ?? .zero
        return CGRect(origin: origin, size: size)
    }

    // MARK: - AX helpers

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success else { return nil }
        return value
    }

    private static func readCGPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let raw = copyAttribute(element, attribute),
              let axValue = axDowncast(raw, to: AXValue.self, ifTypeID: AXValueGetTypeID())
        else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func readCGSize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let raw = copyAttribute(element, attribute),
              let axValue = axDowncast(raw, to: AXValue.self, ifTypeID: AXValueGetTypeID())
        else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }
}

/// Downcast a Core Foundation value returned by the Accessibility API to a
/// concrete CF type, but only when its runtime `CFTypeID` matches `typeID`;
/// returns nil otherwise. Folds the guarded `CFGetTypeID` + `unsafeDowncast`
/// idiom shared by the AX read paths in `WindowProbe` and `WindowMutator`.
func axDowncast<T: AnyObject>(_ value: AnyObject, to _: T.Type, ifTypeID typeID: CFTypeID) -> T? {
    guard CFGetTypeID(value) == typeID else { return nil }
    return unsafeDowncast(value, to: T.self)
}
