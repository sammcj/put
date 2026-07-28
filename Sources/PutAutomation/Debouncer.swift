import Foundation

/// Trailing-edge debouncer. Each `schedule(_:)` call cancels any outstanding
/// task and schedules a new one that runs `action` after `interval` has
/// elapsed without any further calls.
///
/// Used to collapse bursts of `CGDisplayReconfigurationCallback` events
/// (typical replug produces several in rapid succession) into a single
/// restore.
@MainActor
public final class Debouncer {
    private let interval: TimeInterval
    private var task: Task<Void, Never>?

    public init(interval: TimeInterval) {
        self.interval = interval
    }

    public func schedule(_ action: @MainActor @escaping () async -> Void) {
        task?.cancel()
        task = Task { [interval] in
            try? await Task.sleep(for: .seconds(interval))
            if Task.isCancelled { return }
            await action()
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
    }
}
