import Foundation
import OSLog
import PutAutomation
import PutCore
import PutStorage

/// Debounced persistence for `AppState.config`. SwiftUI views mutate the
/// config directly; this type watches for changes and writes them to disk
/// without blocking the UI.
///
/// The debounce interval is conservative (400ms) so a burst of slider/stepper
/// edits collapses into a single write. On app termination the pending write
/// should be flushed via `flush()`.
@MainActor
public final class ConfigPersister {
    private let state: AppState
    private let store: ConfigStore
    private let log: Logger = PutLog.logger(category: "persister")
    private var pendingTask: Task<Void, Never>?
    private var lastPersisted: Config?

    public init(state: AppState, store: ConfigStore) {
        self.state = state
        self.store = store
        lastPersisted = state.config
    }

    /// Schedule a write of the current state after the debounce interval.
    public func scheduleWrite(debounce: TimeInterval = 0.4) {
        pendingTask?.cancel()
        pendingTask = Task { [weak state, store, log] in
            try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
            if Task.isCancelled { return }
            guard let state else { return }
            do {
                try await store.save(state.config)
                log.debug("Config persisted")
                if state.lastSaveError != nil { state.lastSaveError = nil }
            } catch {
                let message = error.localizedDescription
                log.error("Config persist failed: \(message, privacy: .public)")
                state.lastSaveError = "Put couldn't save your settings: \(message)"
            }
        }
    }

    public func flush() async {
        pendingTask?.cancel()
        do {
            try await store.save(state.config)
            if state.lastSaveError != nil { state.lastSaveError = nil }
        } catch {
            let message = error.localizedDescription
            log.error("Config flush failed: \(message, privacy: .public)")
            state.lastSaveError = "Put couldn't save your settings on quit: \(message)"
        }
    }
}
