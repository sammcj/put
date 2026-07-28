import Foundation
@testable import PutAutomation
import PutDisplay
import Testing

/// In-memory `DisplayConfigurationObserving` whose event stream the test drives
/// directly. Counts start/stop so the `defer { stop() }` pairing can be
/// asserted (a dropped observer that skips stop() leaks the CG callback).
private final class FakeDisplayObserver: DisplayConfigurationObserving, @unchecked Sendable {
    let events: AsyncStream<DisplayChangeEvent>
    private let continuation: AsyncStream<DisplayChangeEvent>.Continuation
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0

    var startCount: Int {
        lock.withLock { starts }
    }

    var stopCount: Int {
        lock.withLock { stops }
    }

    init() {
        var captured: AsyncStream<DisplayChangeEvent>.Continuation!
        events = AsyncStream { captured = $0 }
        continuation = captured
    }

    func start() {
        lock.withLock { starts += 1 }
    }

    func stop() {
        lock.withLock { stops += 1 }
    }

    func emit(_ event: DisplayChangeEvent) {
        continuation.yield(event)
    }

    func finish() {
        continuation.finish()
    }
}

@MainActor
@Suite("forEachDisplayConfigurationChange")
struct DisplayConfigurationObservingTests {
    @Test
    func runsActionOncePerConfigurationChangeAndStops() async {
        let observer = FakeDisplayObserver()
        observer.emit(.beginConfiguration) // filtered out
        observer.emit(.configurationChanged)
        observer.emit(.configurationChanged)
        observer.finish()

        var count = 0
        await forEachDisplayConfigurationChange(observer: observer) { count += 1 }

        #expect(count == 2)
        #expect(observer.startCount == 1)
        #expect(observer.stopCount == 1)
    }

    @Test
    func stopsWhenStreamEndsWithNoEvents() async {
        let observer = FakeDisplayObserver()
        observer.finish()

        var count = 0
        await forEachDisplayConfigurationChange(observer: observer) { count += 1 }

        #expect(count == 0)
        #expect(observer.startCount == 1)
        #expect(observer.stopCount == 1)
    }
}
