import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
@testable import PutAutomation
@testable import PutCore
@testable import PutDisplay
@testable import PutStorage
import PutTestSupport
@testable import PutWindows
import Testing

// `hasActiveDisplays` (the `.disabled(if:)` gate for the layout tests below)
// lives in PutTestSupport, shared with the other display-dependent suites.

// Coverage for change 6 (C3/C4): a settled restore that collides with an
// in-flight restore must re-queue its reasons rather than lose them, and a
// layout activation must only persist once its restore actually lands. The
// collision is injected deterministically by parking an in-flight restore on a
// gated probe, never by relying on timing.

/// Window probe whose first `snapshot()` optionally parks on a semaphore, so a
/// test can hold one restore in flight (keeping the coordinator's single-flight
/// guard closed) while it drives a second, colliding restore. `snapshot()` runs
/// on a detached task, so blocking there never stalls the main actor.
private final class TestProbe: WindowProbing, @unchecked Sendable {
    let handles: [WindowHandle]
    private let lock = NSLock()
    private var snapshotCount = 0
    private var firstPending: Bool
    private let gate = DispatchSemaphore(value: 0)
    private var released = false

    init(handles: [WindowHandle] = [], blockFirst: Bool = false) {
        self.handles = handles
        firstPending = blockFirst
    }

    var snapshotCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return snapshotCount
    }

    func snapshot() -> [WindowHandle] {
        lock.lock()
        snapshotCount += 1
        let block = firstPending
        firstPending = false
        lock.unlock()
        if block { gate.wait() }
        return handles
    }

    func focusedWindow() -> WindowHandle? {
        handles.first
    }

    func windows(forBundleID bundleID: String) -> [WindowHandle] {
        handles.filter { $0.descriptor.bundleID == bundleID }
    }

    /// Idempotent; safe to call from both a `defer` and the test body.
    func release() {
        lock.lock()
        let alreadyReleased = released
        released = true
        lock.unlock()
        if !alreadyReleased { gate.signal() }
    }
}

private final class TestMutator: WindowMutating, @unchecked Sendable {
    func setFrame(_: WindowHandle, to _: CGRect) throws {}
    func setSize(_: WindowHandle, to _: CGSize) throws {}
    func raise(_: WindowHandle) {}
}

private struct TestGate: AccessibilityGateProviding {
    let trusted: Bool
    var isTrusted: Bool {
        trusted
    }
}

/// Records `onActivateLayout` calls plus the coordinator snapshot count at the
/// moment each fired, so a test can assert activation happened AFTER the restore
/// probed rather than before it.
@MainActor
private final class ActivationRecorder {
    var ids: [UUID] = []
    var snapshotCountAtActivation: [Int] = []
}

private struct PollTimeout: Error {}

@MainActor
@Suite("AutoTriggerController busy-drop and activation ordering")
struct AutoTriggerBusyDropTests {
    private func makeHandle(bundleID: String) -> WindowHandle {
        makeWindowHandle(bundleID: bundleID)
    }

    private func makeStore() throws -> ConfigStore {
        try makeTempStore(prefix: "put-busydrop").store
    }

    /// Awaits an async condition without blocking the main actor. The collision
    /// itself is deterministic (a parked in-flight restore); this only paces the
    /// debounced follow-up passes.
    private func poll(
        timeout: Duration = .seconds(5),
        until condition: () -> Bool) async throws
    {
        let deadline = ContinuousClock().now.advanced(by: timeout)
        while !condition() {
            if ContinuousClock().now >= deadline { throw PollTimeout() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - C3: re-queue a busy-dropped settled restore

    @Test
    func busyDroppedSettledRestoreRequeuesAndFiresLater() async throws {
        var config = Config.bootstrap()
        config.autoTriggers = AutoTriggerSettings(
            onDisplayChange: false, onAppLaunch: false, onWake: true, onPutLaunch: false)
        let state = AppState(config: config)
        let store = try makeStore()
        let probe = TestProbe(handles: [makeHandle(bundleID: "com.example.one")], blockFirst: true)
        let coordinator = ActionCoordinator(
            state: state, store: store, probe: probe,
            mutator: TestMutator(), gate: TestGate(trusted: true))
        let triggers = AutoTriggerController(
            state: state, coordinator: coordinator, probe: TestProbe(),
            debounceInterval: 0.02, maxConsecutiveDrops: 1000)

        // Park an in-flight restore so the coordinator's single-flight guard is
        // closed (isRestoring == true) when the settled pass runs.
        let inflight = Task { await coordinator.restoreAllWindows(source: .explicit) }
        defer { probe.release() }
        try await poll(until: { probe.snapshotCalls >= 1 })

        // A settled restore now collides and is dropped; it must re-queue.
        triggers.scheduleSettledRestore(reason: .wake)
        try await poll(until: { triggers.settleRequeueAttempts >= 1 })

        // Release the in-flight restore; a re-queued pass must now fire on its
        // own, with no new external trigger, and land a second snapshot.
        probe.release()
        try await poll(until: { probe.snapshotCalls >= 2 })
        #expect(probe.snapshotCalls >= 2)
        try await poll(until: { triggers.settleRequeueAttempts >= 1 && triggers.pendingReasons.isEmpty })

        triggers.stop()
        _ = await inflight.value
    }

    // MARK: - C4: layout activation persistence follows the restore result

    @Test(.disabled(if: !hasActiveDisplays, "requires at least one active display"))
    func layoutActivationDoesNotPersistWhenRestoreDroppedBusy() async throws {
        // The trait guarantees a display is present; a missing one here is a
        // genuine failure, not a silent skip.
        let displays = try DisplayProbe.snapshot()
        try #require(!displays.isEmpty)

        var config = Config.bootstrap()
        config.autoTriggers = AutoTriggerSettings(
            onDisplayChange: true, onAppLaunch: false, onWake: false, onPutLaunch: false)
        let base = PutCore.Layout(name: "Base")
        let trigger = ScreenConfigTrigger(displays: displays, arrangementStrict: true, autoActivate: true)
        let docked = PutCore.Layout(name: "Docked", screenConfigs: [trigger])
        config.layouts = [base, docked]
        config.activeLayoutID = base.id
        let state = AppState(config: config)
        let store = try makeStore()
        let probe = TestProbe(handles: [makeHandle(bundleID: "com.example.one")], blockFirst: true)
        let coordinator = ActionCoordinator(
            state: state, store: store, probe: probe,
            mutator: TestMutator(), gate: TestGate(trusted: true))
        let triggers = AutoTriggerController(
            state: state, coordinator: coordinator, probe: TestProbe(), debounceInterval: 0)
        let recorder = ActivationRecorder()
        triggers.onActivateLayout = { recorder.ids.append($0) }

        // Park an in-flight restore so the layout restore is dropped busy.
        let inflight = Task { await coordinator.restoreAllWindows(source: .explicit) }
        defer { probe.release() }
        try await poll(until: { probe.snapshotCalls >= 1 })

        let (fired, result) = await triggers.applyLayoutTriggersIfMatching(reasonList: "test")

        #expect(fired == false)
        #expect(result == nil)
        #expect(recorder.ids.isEmpty) // no persistence on a busy-drop
        #expect(state.config.activeLayoutID == base.id) // in-memory switch reverted

        probe.release()
        _ = await inflight.value
    }

    @Test(.disabled(if: !hasActiveDisplays, "requires at least one active display"))
    func layoutActivationPersistsAfterSuccessfulRestore() async throws {
        // The trait guarantees a display is present; a missing one here is a
        // genuine failure, not a silent skip.
        let displays = try DisplayProbe.snapshot()
        try #require(!displays.isEmpty)

        var config = Config.bootstrap()
        config.autoTriggers = AutoTriggerSettings(
            onDisplayChange: true, onAppLaunch: false, onWake: false, onPutLaunch: false)
        let base = PutCore.Layout(name: "Base")
        let trigger = ScreenConfigTrigger(displays: displays, arrangementStrict: true, autoActivate: true)
        let docked = PutCore.Layout(name: "Docked", screenConfigs: [trigger])
        config.layouts = [base, docked]
        config.activeLayoutID = base.id
        let state = AppState(config: config)
        let store = try makeStore()
        let probe = TestProbe(handles: [makeHandle(bundleID: "com.example.one")])
        let coordinator = ActionCoordinator(
            state: state, store: store, probe: probe,
            mutator: TestMutator(), gate: TestGate(trusted: true))
        let triggers = AutoTriggerController(
            state: state, coordinator: coordinator, probe: TestProbe(), debounceInterval: 0)
        let recorder = ActivationRecorder()
        triggers.onActivateLayout = {
            recorder.ids.append($0)
            recorder.snapshotCountAtActivation.append(probe.snapshotCalls)
        }

        let (fired, result) = await triggers.applyLayoutTriggersIfMatching(reasonList: "launch")

        #expect(fired == true)
        #expect(result != nil)
        #expect(recorder.ids == [docked.id]) // persisted the matched layout
        // Persistence fired AFTER the restore probed (snapshot already counted),
        // not before it as the pre-fix code did.
        #expect(recorder.snapshotCountAtActivation == [1])
    }

    // MARK: - C4: a user layout switch during the restore is not clobbered

    @Test(.disabled(if: !hasActiveDisplays, "requires at least one active display"))
    func concurrentUserSwitchDuringRestoreIsNotClobbered() async throws {
        // The trait guarantees a display; a missing one is a real failure.
        let displays = try DisplayProbe.snapshot()
        try #require(!displays.isEmpty)

        var config = Config.bootstrap()
        config.autoTriggers = AutoTriggerSettings(
            onDisplayChange: true, onAppLaunch: false, onWake: false, onPutLaunch: false)
        let base = PutCore.Layout(name: "Base")
        let trigger = ScreenConfigTrigger(displays: displays, arrangementStrict: true, autoActivate: true)
        let docked = PutCore.Layout(name: "Docked", screenConfigs: [trigger])
        let userChoice = PutCore.Layout(name: "UserChoice")
        config.layouts = [base, docked, userChoice]
        config.activeLayoutID = base.id
        let state = AppState(config: config)
        let store = try makeStore()
        // blockFirst parks the trigger's own restore mid-flight, opening a window
        // to simulate the user switching layouts while it runs.
        let probe = TestProbe(handles: [makeHandle(bundleID: "com.example.one")], blockFirst: true)
        let coordinator = ActionCoordinator(
            state: state, store: store, probe: probe,
            mutator: TestMutator(), gate: TestGate(trusted: true))
        let triggers = AutoTriggerController(
            state: state, coordinator: coordinator, probe: TestProbe(), debounceInterval: 0)
        let recorder = ActivationRecorder()
        // Mirror production: activation both records and writes activeLayoutID, so
        // an unguarded re-assert would clobber the user's choice here too.
        triggers.onActivateLayout = {
            recorder.ids.append($0)
            state.config.activeLayoutID = $0
        }

        // Fire the trigger; it sets docked in memory and parks in the restore.
        let task = Task { await triggers.applyLayoutTriggersIfMatching(reasonList: "test") }
        defer { probe.release() }
        try await poll(until: { probe.snapshotCalls >= 1 })
        #expect(state.config.activeLayoutID == docked.id)

        // The user picks a different layout mid-restore; the deferred activation
        // must respect that, not re-assert the matched layout.
        state.config.activeLayoutID = userChoice.id
        probe.release()
        _ = await task.value

        #expect(state.config.activeLayoutID == userChoice.id)
        #expect(recorder.ids.contains(docked.id) == false)

        triggers.stop()
    }

    // MARK: - Bound: the re-queue cannot ping-pong forever

    @Test
    func requeueStopsAfterConsecutiveBusyDropCap() async throws {
        var config = Config.bootstrap()
        config.autoTriggers = AutoTriggerSettings(
            onDisplayChange: false, onAppLaunch: false, onWake: true, onPutLaunch: false)
        let state = AppState(config: config)
        let store = try makeStore()
        let probe = TestProbe(handles: [makeHandle(bundleID: "com.example.one")], blockFirst: true)
        let coordinator = ActionCoordinator(
            state: state, store: store, probe: probe,
            mutator: TestMutator(), gate: TestGate(trusted: true))
        let cap = 3
        let triggers = AutoTriggerController(
            state: state, coordinator: coordinator, probe: TestProbe(),
            debounceInterval: 0, maxConsecutiveDrops: cap)

        // The coordinator stays busy for the whole test, so every re-queued pass
        // is dropped too. The re-queue must abandon after the cap is exceeded.
        let inflight = Task { await coordinator.restoreAllWindows(source: .explicit) }
        defer { probe.release() }
        try await poll(until: { probe.snapshotCalls >= 1 })

        triggers.scheduleSettledRestore(reason: .wake)

        // Attempts are bounded by cap + 1 (the final drop that trips the guard).
        // If the re-queue ping-ponged forever this would keep climbing past it.
        try await poll(until: { triggers.settleRequeueAttempts >= cap + 1 })
        let attemptsAtGiveUp = triggers.settleRequeueAttempts
        try await Task.sleep(for: .milliseconds(120))
        #expect(triggers.settleRequeueAttempts == attemptsAtGiveUp)
        #expect(triggers.settleRequeueAttempts == cap + 1)
        #expect(triggers.pendingReasons.isEmpty)
        // No re-queued pass ever began, so only the parked restore probed.
        #expect(probe.snapshotCalls == 1)

        triggers.stop()
        probe.release()
        _ = await inflight.value
    }
}
