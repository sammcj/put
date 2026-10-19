import Foundation
@testable import PutAutomation
@testable import PutCore
import PutTestSupport
@testable import PutWindows
import Testing

@MainActor
@Suite("Mission Control pauses automatic restores")
struct MissionControlPauseTests {
    private struct PollTimeout: Error {}

    private func makeCoordinator(
        missionControl: StubMissionControl,
        probe: StubWindowProbe,
        config: Config = .bootstrap()) throws -> ActionCoordinator
    {
        try ActionCoordinator(
            state: AppState(config: config),
            store: makeTempStore(prefix: "put-mission-control").store,
            probe: probe,
            mutator: RecordingWindowMutator(),
            gate: StubAccessibilityGate(trusted: true),
            missionControl: missionControl)
    }

    private func poll(timeout: Duration = .seconds(5), until condition: () -> Bool) async throws {
        let deadline = ContinuousClock().now.advanced(by: timeout)
        while !condition() {
            if ContinuousClock().now >= deadline { throw PollTimeout() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test
    func automaticRestoreAllIsDroppedWithoutProbing() async throws {
        let probe = StubWindowProbe(handles: [makeWindowHandle(bundleID: "com.example.one")])
        let coordinator = try makeCoordinator(missionControl: StubMissionControl(active: true), probe: probe)
        #expect(await coordinator.restoreAllWindows(source: .auto) == nil)
        #expect(probe.snapshotCalls == 0)
    }

    @Test
    func automaticPerAppRestoreReportsBusySoLaunchRetriesContinue() async throws {
        let probe = StubWindowProbe()
        let coordinator = try makeCoordinator(missionControl: StubMissionControl(active: true), probe: probe)
        let handles = [makeWindowHandle(bundleID: "com.example.one")]
        #expect(await coordinator.restore(windowsForUI: handles, source: .auto) == .droppedBusy)
    }

    @Test
    func explicitRestoresStillRun() async throws {
        let probe = StubWindowProbe(handles: [makeWindowHandle(bundleID: "com.example.one")])
        let coordinator = try makeCoordinator(missionControl: StubMissionControl(active: true), probe: probe)
        #expect(await coordinator.restoreAllWindows(source: .explicitAll) != nil)
        #expect(await coordinator.restoreAllWindows(source: .explicit) != nil)
        #expect(probe.snapshotCalls == 2)
    }

    @Test
    func automaticRestoreRunsOnceClosed() async throws {
        let missionControl = StubMissionControl(active: true)
        let probe = StubWindowProbe(handles: [makeWindowHandle(bundleID: "com.example.one")])
        let coordinator = try makeCoordinator(missionControl: missionControl, probe: probe)
        #expect(await coordinator.restoreAllWindows(source: .auto) == nil)
        missionControl.isMissionControlActive = false
        #expect(await coordinator.restoreAllWindows(source: .auto) != nil)
    }

    @Test
    func correctiveRetrySurvivesAPauseLongerThanItsDropCap() async throws {
        let missionControl = StubMissionControl(active: true)
        let probe = StubWindowProbe(handles: [makeWindowHandle(bundleID: "com.example.one")])
        let coordinator = try makeCoordinator(missionControl: missionControl, probe: probe)
        let triggers = AutoTriggerController(
            state: coordinator.state,
            coordinator: coordinator,
            probe: StubWindowProbe(),
            wakeRetryDelays: [0.01],
            retryDropBackoff: 0.01,
            maxConsecutiveDrops: 2)
        defer { triggers.stop() }

        let erroring = ActionCoordinator.RestoreResult(
            applied: 0, errors: 1, drifted: 0, queued: 0, proportional: 0,
            erroredBundles: ["com.example.one"], unmatchedBundles: [])
        triggers.scheduleCorrectiveRetryIfNeeded(reasons: [.wake], result: erroring)

        // Many times the drop cap's worth of backoff ticks, all paused.
        try await Task.sleep(for: .milliseconds(150))
        #expect(probe.snapshotCalls == 0)

        missionControl.isMissionControlActive = false
        try await poll(until: { probe.snapshotCalls >= 1 })
    }

    @Test
    func settledRestoreWaitsForMissionControlWithoutCountingDrops() async throws {
        var config = Config.bootstrap()
        config.autoTriggers = AutoTriggerSettings(
            onDisplayChange: false, onAppLaunch: false, onWake: true, onPutLaunch: false)
        let missionControl = StubMissionControl(active: true)
        let probe = StubWindowProbe(handles: [makeWindowHandle(bundleID: "com.example.one")])
        let coordinator = try makeCoordinator(missionControl: missionControl, probe: probe, config: config)
        let triggers = AutoTriggerController(
            state: coordinator.state,
            coordinator: coordinator,
            probe: StubWindowProbe(),
            debounceInterval: 0.02)
        defer { triggers.stop() }

        triggers.scheduleSettledRestore(reason: .wake)
        // Several debounce periods pass with the batch held, not consumed.
        try await Task.sleep(for: .milliseconds(150))
        #expect(probe.snapshotCalls == 0)
        #expect(triggers.pendingReasons == [.wake])
        #expect(triggers.settleRequeueAttempts == 0)

        missionControl.isMissionControlActive = false
        try await poll(until: { probe.snapshotCalls >= 1 })
        #expect(triggers.pendingReasons.isEmpty)
    }
}
