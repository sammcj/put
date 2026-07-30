import ApplicationServices
import CoreGraphics
import Foundation

/// Position-only mutation, split from `WindowMutator.swift` so neither file
/// carries the whole AX write surface. The retry, readback and AX-write
/// primitives this shares with `setFrame`/`setSize` are module-internal rather
/// than file-private for exactly this reason - `private` members aren't visible
/// to an extension in another file.
extension WindowMutator {
    /// Move a window without touching its size. Used when a rule has
    /// `restoreScope == .displayOnly`, where the point is to change which
    /// display the window is on and nothing else. Mirrors the retry/drift
    /// behaviour of `setSize` but writes only `kAXPositionAttribute` and
    /// compares only the origin.
    ///
    /// Moving between displays is the case that needs the retries: an app that
    /// has latched onto a stale `NSScreen` binding (post-wake, post-Space move)
    /// accepts the write and then clamps the window back onto the display it
    /// thinks it lives on. The `nudge` between attempts is what makes it
    /// re-query.
    public static func setPosition(_ handle: WindowHandle, to origin: CGPoint) throws {
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
            try retryOnCannotComplete(context: "setPosition", handle: handle) {
                try writePosition(handle.axElement, origin)
            }
            actual = readFrame(handle.axElement)

            if let actual, originMatches(target: origin, actual: actual.origin) {
                logPositionOutcome(
                    handle: handle,
                    initial: initial,
                    target: origin,
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
        // a fabricated frame would pollute the drift diagnostic.
        guard let finalActual = actual ?? readFrame(handle.axElement) else {
            throw AXOperationError.elementGone
        }
        logPositionOutcome(
            handle: handle,
            initial: initial,
            target: origin,
            actual: finalActual,
            attempts: attemptsMade)
        throw AXOperationError.drifted(
            target: CGRect(origin: origin, size: finalActual.size),
            actual: finalActual,
            attempts: attemptsMade)
    }

    static func originMatches(target: CGPoint, actual: CGPoint) -> Bool {
        abs(target.x - actual.x) <= frameTolerance
            && abs(target.y - actual.y) <= frameTolerance
    }

    private static func logPositionOutcome(
        handle: WindowHandle,
        initial: CGRect?,
        target: CGPoint,
        actual: CGRect,
        attempts: Int)
    {
        let initialDesc = initial.map(String.init(describing:)) ?? "unknown"
        let drifted = !originMatches(target: target, actual: actual.origin)
        log.info(
            """
            setPosition bundle=\(handle.descriptor.bundleID, privacy: .public) \
            attempts=\(attempts, privacy: .public) \
            drifted=\(drifted, privacy: .public) \
            initial=\(initialDesc, privacy: .public) \
            target=\(String(describing: target), privacy: .public) \
            actual=\(String(describing: actual), privacy: .public)
            """)
    }
}
