import PutDisplay

/// Minimal seam over `DisplayChangeObserver` so display-change consumers can be
/// driven by a fake in tests. `DisplayChangeObserver` conforms as-is.
public protocol DisplayConfigurationObserving: Sendable {
    var events: AsyncStream<DisplayChangeEvent> { get }
    func start()
    func stop()
}

extension DisplayChangeObserver: DisplayConfigurationObserving {}

/// Starts `observer`, runs `action` once per `.configurationChanged` event, and
/// guarantees `stop()` on teardown. The `defer` pairing is load-bearing: a
/// dropped observer that never calls `stop()` leaks its CG reconfiguration
/// callback forever (the `passRetained` self-reference is balanced only by
/// `stop()`), so every consumer must go through this function.
@MainActor
public func forEachDisplayConfigurationChange(
    observer: some DisplayConfigurationObserving,
    perform action: @MainActor () -> Void) async
{
    observer.start()
    defer { observer.stop() }
    for await event in observer.events where event == .configurationChanged {
        action()
    }
}
