import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OSLog
import PutCore

/// Applies frame changes to live windows via the Accessibility API.
public enum WindowMutator {
    private static let log = PutLog.logger(category: "windows.mutator")

    /// Navigation, not placement: activate the owning app and raise the window
    /// so macOS brings it forward and switches to whichever Space it currently
    /// lives on. Pure public AX with no persistent side effect, so both calls
    /// are best-effort — a stale handle simply fails to focus rather than
    /// throwing. This is the "jump to window" primitive; it never moves the
    /// window, only the user's view to it.
    public static func raise(_ handle: WindowHandle) {
        if let app = NSRunningApplication(processIdentifier: handle.descriptor.processID) {
            app.activate()
        }
        _ = AXUIElementPerformAction(handle.axElement, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(
            handle.axElement,
            kAXMainAttribute as CFString,
            kCFBooleanTrue)
        log.info("raise bundle=\(handle.descriptor.bundleID, privacy: .public)")
    }

    /// Maximum absolute deviation (points) on any axis (origin x/y, width,
    /// height) between requested and readback frame before we consider the
    /// write "drifted" and retry.
    static let frameTolerance: CGFloat = 2

    /// Total attempts a single `setFrame` call makes to land inside tolerance
    /// before giving up and throwing `.drifted`. First attempt plus retries.
    static let maxAttempts = 3

    public static func setFrame(_ handle: WindowHandle, to frame: CGRect) throws {
        if handle.descriptor.isMinimised {
            try unminimise(handle)
        }

        let initial = readFrame(handle.axElement)
        var actual: CGRect?
        var attemptsMade = 0

        // Apps like Firefox-post-wake accept `kAXSizeAttribute` writes with
        // AXError.success but silently ignore them. Retry up to `maxAttempts`
        // to catch genuinely transient state, but bail early if successive
        // attempts produce the same actual frame — that means the app is
        // stubbornly clamping and further retries just flicker the window
        // without progress.
        for attempt in 1...maxAttempts {
            attemptsMade = attempt
            if attempt > 1 {
                // Nudge on retry only. Raising + re-marking the window as
                // main tends to make apps re-query their current display
                // (they latch onto a stale NSScreen binding after wake or
                // Space moves).
                nudge(handle.axElement)
                Thread.sleep(forTimeInterval: 0.35)
            }
            let previous = actual
            try applyOnce(handle: handle, target: frame)
            actual = readFrame(handle.axElement)

            if let actual, frameMatches(target: frame, actual: actual) {
                logOutcome(
                    handle: handle,
                    initial: initial,
                    target: frame,
                    actual: actual,
                    attempts: attempt)
                return
            }
            if shouldBailAfterNoProgress(
                attempt: attempt,
                previousActual: previous,
                currentActual: actual)
            {
                break
            }
        }

        // A nil readback here means the window vanished mid-restore (closed,
        // app quit). Report that honestly as `.elementGone` rather than
        // fabricating an `actual` frame equal to the target — the old fallback
        // wrote a target==actual pair into the "Window drifted" NDJSON
        // diagnostic, falsely implying the app accepted then ignored the write.
        guard let finalActual = actual ?? readFrame(handle.axElement) else {
            throw AXOperationError.elementGone
        }
        logOutcome(
            handle: handle,
            initial: initial,
            target: frame,
            actual: finalActual,
            attempts: attemptsMade)
        throw AXOperationError.drifted(
            target: frame,
            actual: finalActual,
            attempts: attemptsMade)
    }

    /// Resize a window without touching its position. Used when a rule has
    /// `restoresPosition == false`. Mirrors the retry/drift behaviour of
    /// `setFrame` but only writes `kAXSizeAttribute` and only compares size
    /// dimensions when deciding success or bail-out.
    public static func setSize(_ handle: WindowHandle, to size: CGSize) throws {
        if handle.descriptor.isMinimised {
            try unminimise(handle)
        }

        let initial = readFrame(handle.axElement)
        var actual: CGRect?
        var attemptsMade = 0

        for attempt in 1...maxAttempts {
            attemptsMade = attempt
            if attempt > 1 {
                nudge(handle.axElement)
                Thread.sleep(forTimeInterval: 0.35)
            }
            let previous = actual
            try retryOnCannotComplete(context: "setSize", handle: handle) {
                try writeSize(handle.axElement, size)
            }
            actual = readFrame(handle.axElement)

            if let actual, sizeMatches(target: size, actual: actual.size) {
                logSizeOutcome(
                    handle: handle,
                    initial: initial,
                    target: size,
                    actual: actual,
                    attempts: attempt)
                return
            }
            if shouldBailAfterNoProgress(
                attempt: attempt,
                previousActual: previous,
                currentActual: actual)
            {
                break
            }
        }

        // See `setFrame`: a nil readback means the element is gone. Reporting
        // a fabricated zero-origin frame would pollute the drift diagnostic.
        guard let finalActual = actual ?? readFrame(handle.axElement) else {
            throw AXOperationError.elementGone
        }
        logSizeOutcome(
            handle: handle,
            initial: initial,
            target: size,
            actual: finalActual,
            attempts: attemptsMade)
        throw AXOperationError.drifted(
            target: CGRect(origin: finalActual.origin, size: size),
            actual: finalActual,
            attempts: attemptsMade)
    }

    /// Runs one pass of the AX writes returned by `writeSequence`. See
    /// `writeSequence(growing:)` for the rationale behind the ordering.
    private static func applyOnce(handle: WindowHandle, target: CGRect) throws {
        let point = CGPoint(x: target.origin.x, y: target.origin.y)
        let size = CGSize(width: target.width, height: target.height)
        let current = readFrame(handle.axElement)
        let willGrow = isGrowing(from: current?.size, to: size)
        for step in writeSequence(growing: willGrow) {
            try retryOnCannotComplete(context: step.context, handle: handle) {
                switch step.kind {
                case .position:
                    try writePosition(handle.axElement, point)
                case .size:
                    try writeSize(handle.axElement, size)
                }
            }
        }
    }

    /// One write in the apply sequence. `kind` selects which AX attribute is
    /// written; `context` is a stable label used for cannot-complete retry
    /// logging.
    struct WriteStep: Equatable {
        enum Kind: Equatable { case position, size }
        let kind: Kind
        let context: String
    }

    /// Ordered AX writes for a single apply pass. Both branches must end with
    /// `.size` because Firefox (and other Gecko apps) silently revert size
    /// when a position write immediately follows it. The growing branch
    /// inserts an initial position write so the window has room before sizing
    /// up; the shrinking branch sets size first so the target origin is
    /// reachable on the destination display.
    static func writeSequence(growing: Bool) -> [WriteStep] {
        if growing {
            return [
                WriteStep(kind: .position, context: "setPosition.pre"),
                WriteStep(kind: .size, context: "setSize.pre"),
                WriteStep(kind: .position, context: "setPosition"),
                WriteStep(kind: .size, context: "setSize")
            ]
        }
        return [
            WriteStep(kind: .size, context: "setSize.pre"),
            WriteStep(kind: .position, context: "setPosition"),
            WriteStep(kind: .size, context: "setSize")
        ]
    }

    /// True when two consecutive attempts produced equivalent actual frames,
    /// signalling the app has clamped to a stable (non-target) geometry and
    /// further retries would only flicker the window.
    static func shouldBailAfterNoProgress(
        attempt: Int,
        previousActual: CGRect?,
        currentActual: CGRect?) -> Bool
    {
        guard attempt > 1,
              let previousActual,
              let currentActual
        else { return false }
        return frameMatches(target: previousActual, actual: currentActual)
    }

    /// Best-effort kick to break apps out of a latched geometry state.
    /// Failures are ignored — this is strictly additive behaviour and the
    /// subsequent write sequence will still run either way.
    private static func nudge(_ element: AXUIElement) {
        _ = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(
            element,
            kAXMainAttribute as CFString,
            kCFBooleanTrue)
    }

    static func frameMatches(target: CGRect, actual: CGRect) -> Bool {
        abs(target.origin.x - actual.origin.x) <= frameTolerance
            && abs(target.origin.y - actual.origin.y) <= frameTolerance
            && abs(target.size.width - actual.size.width) <= frameTolerance
            && abs(target.size.height - actual.size.height) <= frameTolerance
    }

    static func sizeMatches(target: CGSize, actual: CGSize) -> Bool {
        abs(target.width - actual.width) <= frameTolerance
            && abs(target.height - actual.height) <= frameTolerance
    }

    static func isGrowing(from current: CGSize?, to target: CGSize) -> Bool {
        guard let current else { return false }
        return target.width > current.width + 1 || target.height > current.height + 1
    }

    private static func logOutcome(
        handle: WindowHandle,
        initial: CGRect?,
        target: CGRect,
        actual: CGRect,
        attempts: Int)
    {
        let initialDesc = initial.map(String.init(describing:)) ?? "unknown"
        let drifted = !frameMatches(target: target, actual: actual)
        log.info(
            """
            setFrame bundle=\(handle.descriptor.bundleID, privacy: .public) \
            attempts=\(attempts, privacy: .public) \
            drifted=\(drifted, privacy: .public) \
            initial=\(initialDesc, privacy: .public) \
            target=\(String(describing: target), privacy: .public) \
            actual=\(String(describing: actual), privacy: .public)
            """)
    }

    private static func logSizeOutcome(
        handle: WindowHandle,
        initial: CGRect?,
        target: CGSize,
        actual: CGRect,
        attempts: Int)
    {
        let initialDesc = initial.map(String.init(describing:)) ?? "unknown"
        let drifted = !sizeMatches(target: target, actual: actual.size)
        log.info(
            """
            setSize bundle=\(handle.descriptor.bundleID, privacy: .public) \
            attempts=\(attempts, privacy: .public) \
            drifted=\(drifted, privacy: .public) \
            initial=\(initialDesc, privacy: .public) \
            target=\(String(describing: target), privacy: .public) \
            actual=\(String(describing: actual), privacy: .public)
            """)
    }

    private static func retryOnCannotComplete(
        context: String,
        handle: WindowHandle,
        _ operation: () throws -> Void) throws
    {
        do {
            try operation()
        } catch let error as AXOperationError {
            if case let .operationFailed(axError, _) = error, axError == .cannotComplete {
                log.info(
                    "AX \(context, privacy: .public) retrying after .cannotComplete for \(handle.descriptor.bundleID, privacy: .public)")
                Thread.sleep(forTimeInterval: 0.003)
                try operation()
            } else {
                throw error
            }
        }
    }

    public static func unminimise(_ handle: WindowHandle) throws {
        let err = AXUIElementSetAttributeValue(
            handle.axElement,
            kAXMinimizedAttribute as CFString,
            false as CFBoolean)
        guard err == .success else {
            throw AXOperationError(err, context: "unminimise")
        }
    }

    private static func writePosition(_ element: AXUIElement, _ point: CGPoint) throws {
        var mutable = point
        guard let value = AXValueCreate(.cgPoint, &mutable) else {
            throw AXOperationError.operationFailed(.failure, "AXValueCreate(cgPoint)")
        }
        let err = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        guard err == .success else {
            throw AXOperationError(err, context: "setPosition")
        }
    }

    private static func writeSize(_ element: AXUIElement, _ size: CGSize) throws {
        var mutable = size
        guard let value = AXValueCreate(.cgSize, &mutable) else {
            throw AXOperationError.operationFailed(.failure, "AXValueCreate(cgSize)")
        }
        let err = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
        guard err == .success else {
            throw AXOperationError(err, context: "setSize")
        }
    }

    private static func readFrame(_ element: AXUIElement) -> CGRect? {
        guard let origin = readCGPoint(element, kAXPositionAttribute),
              let size = readCGSize(element, kAXSizeAttribute)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func readCGPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var raw: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let value = raw,
              let axValue = axDowncast(value, to: AXValue.self, ifTypeID: AXValueGetTypeID())
        else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func readCGSize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var raw: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let value = raw,
              let axValue = axDowncast(value, to: AXValue.self, ifTypeID: AXValueGetTypeID())
        else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }
}
