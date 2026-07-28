import CoreGraphics
import Foundation
import OSLog
import PutCore

public enum DisplayChangeEvent: Equatable, Sendable {
    case beginConfiguration
    case configurationChanged
}

/// Wraps `CGDisplayRegisterReconfigurationCallback` as an `AsyncStream`.
///
/// Events for the "begin" phase and the final "end" phase are surfaced
/// separately; most callers should listen only for `.configurationChanged`
/// and ignore `.beginConfiguration`. A single reconfiguration may emit
/// multiple `.configurationChanged` events (one per affected display), so
/// consumers are expected to debounce.
public final class DisplayChangeObserver: @unchecked Sendable {
    public let events: AsyncStream<DisplayChangeEvent>

    private let continuation: AsyncStream<DisplayChangeEvent>.Continuation
    private let log: Logger
    private let lock = NSLock()
    private var started = false
    private var retainedPtr: UnsafeMutableRawPointer?

    public init() {
        var capturedContinuation: AsyncStream<DisplayChangeEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { cont in
            capturedContinuation = cont
        }
        continuation = capturedContinuation
        log = PutLog.logger(category: "display.observer")
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        // Retain self across the callback lifetime so an in-flight callback
        // can't deref freed memory if the owner drops us before stop().
        let ptr = Unmanaged.passRetained(self).toOpaque()
        retainedPtr = ptr
        CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, ptr)
        started = true
        log.info("Display change observer started")
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard started else { return }
        started = false
        continuation.finish()
        if let ptr = retainedPtr {
            CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, ptr)
            Unmanaged<DisplayChangeObserver>.fromOpaque(ptr).release()
            retainedPtr = nil
        }
        log.info("Display change observer stopped")
    }

    /// Yields only if the observer is still started; callback path holds the
    /// lock so we don't race against `stop()` finishing the continuation.
    fileprivate func yieldIfStarted(_ event: DisplayChangeEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard started else { return }
        continuation.yield(event)
    }
}

private func displayReconfigurationCallback(
    display: CGDirectDisplayID,
    flags: CGDisplayChangeSummaryFlags,
    userInfo: UnsafeMutableRawPointer?)
{
    guard let userInfo else { return }
    let observer = Unmanaged<DisplayChangeObserver>.fromOpaque(userInfo).takeUnretainedValue()
    if flags.contains(.beginConfigurationFlag) {
        observer.yieldIfStarted(.beginConfiguration)
    } else {
        observer.yieldIfStarted(.configurationChanged)
    }
}
