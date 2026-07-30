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

// `hasActiveDisplays` (the `.disabled(if:)` gate for the proportional-retry
// tests) lives in PutTestSupport, shared with the other display-dependent suites.

// MARK: - Wake / display-change corrective retry

/// Lives in its own file so the main controller suite stays under the
/// type-body and file-length caps (mirrors the ActionCoordinator test split).
/// Minimal doubles are duplicated because the main suite's are private to it.
@MainActor
@Suite("AutoTriggerController corrective retry")
struct AutoTriggerControllerWakeRetryTests {
    private func makeHandle(bundleID: String) -> WindowHandle {
        makeWindowHandle(bundleID: bundleID)
    }

    private func makeStore() throws -> ConfigStore {
        try makeTempStore(prefix: "put-wake").store
    }

    @Test(.disabled(if: !hasActiveDisplays, "requires at least one active display"))
    func proportionalPlacementDrivesRetrySchedule() async throws {
        // Regression guard for "Ghostty restored small in the top-left after
        // unlock". When wake fires while an external panel is still at a
        // transient resolution, the window is placed proportionally onto the
        // wrong geometry. That placement reports no AX error, so the old
        // errors-only retry gate never re-checked. The gate must now also arm
        // on a proportional placement and re-probe until the panel settles
        // (here it never matches, so the full short schedule runs).
        let bundleID = "com.example.one"
        // Target a display the host can't match, with primaryProportional, so
        // every placement resolves proportionally and deterministically.
        let absent = DisplayFingerprint(
            uuid: UUID(),
            vendorID: 60001,
            productID: 60002,
            serialNumber: 60003,
            pointSize: CGSize(width: 5120, height: 2880),
            pixelSize: CGSize(width: 5120, height: 2880),
            scaleFactor: 1,
            globalOrigin: CGPoint(x: 99999, y: 99999),
            isPrimary: false)
        let rule = Rule(
            descriptiveLabel: "test",
            matchCriteria: MatchCriteria(bundleID: bundleID, applyToAllWindows: true),
            targetDisplay: absent,
            frame: WindowFrame(
                absolute: CGRect(x: 0, y: 0, width: 100, height: 100),
                normalised: UnitRect(x: 0, y: 0, width: 0.1, height: 0.1)),
            missingDisplayPolicy: .primaryProportional)
        var config = Config.bootstrap()
        config.autoTriggers = AutoTriggerSettings(onDisplayChange: false, onAppLaunch: false, onWake: true)
        config.layouts = [PutCore.Layout(name: "Test", rules: [rule])]
        config.activeLayoutID = config.layouts[0].id

        let state = AppState(config: config)
        let store = try makeStore()
        let probe = StubWindowProbe(handles: [makeHandle(bundleID: bundleID)])
        let coordinator = ActionCoordinator(
            state: state,
            store: store,
            probe: probe,
            mutator: RecordingWindowMutator(),
            gate: StubAccessibilityGate())
        let triggers = AutoTriggerController(
            state: state,
            coordinator: coordinator,
            probe: probe,
            debounceInterval: 0,
            wakeRetryDelays: [0.02, 0.02, 0.02])

        // The trait guarantees a display is present; a missing one here is a
        // genuine failure, not a silent skip.
        let displays = try DisplayProbe.snapshot()
        try #require(!displays.isEmpty)

        triggers.start()
        defer { triggers.stop() }

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: NSWorkspace.shared)
        try await Task.sleep(for: .milliseconds(300))

        // The wake restore places the window proportionally (errors=0), which
        // under the old errors-only gate would NOT have retried at all (exactly
        // one snapshot). The fix arms a retry on the proportional signal, so at
        // least one more snapshot runs. The exact count past that depends on how
        // many retry passes the moved-by-user guard suppresses before the loop
        // stops, which varies with the host's real display geometry - so assert
        // only the decisive boundary: a retry happened.
        #expect(probe.snapshotCalls >= 2)
    }

    @Test
    func screensDidWakeTriggersRestore() async throws {
        // Display-idle wake (no system sleep) must reassert the layout. Before
        // adding this observer, only full-system `didWake` was a return signal,
        // so a lock/display-off-on never fired a "return" restore.
        var config = Config.bootstrap()
        config.autoTriggers = AutoTriggerSettings(
            onDisplayChange: false,
            onAppLaunch: false,
            onWake: true,
            onPutLaunch: false)
        let state = AppState(config: config)
        let store = try makeStore()
        let probe = StubWindowProbe(handles: [makeHandle(bundleID: "com.example.one")])
        let coordinator = ActionCoordinator(
            state: state,
            store: store,
            probe: probe,
            mutator: RecordingWindowMutator(),
            gate: StubAccessibilityGate())
        let triggers = AutoTriggerController(
            state: state,
            coordinator: coordinator,
            probe: probe,
            debounceInterval: 0.05)

        triggers.start()
        defer { triggers.stop() }

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.screensDidWakeNotification,
            object: NSWorkspace.shared)
        try await Task.sleep(for: .milliseconds(300))
        // At least one, not exactly one. The post goes to the real shared
        // workspace notification centre, so a genuine system wake or unlock on
        // the host during this window delivers a second event and a second
        // restore - which is correct behaviour, but made this fail in CI. The
        // regression guarded here is zero restores (no observer registered);
        // coalescing is covered by `wakeCoalescesIntoSingleRestore`.
        #expect(probe.snapshotCalls >= 1)
    }

    @Test
    func wakeWaitsForDisplayEventsToQuiesce() async throws {
        // Change #1: a wake restore must not run while the display set is still
        // churning. We drive the controller directly (no real CG observer) by
        // calling scheduleSettledRestore, churning displayChange events inside
        // the quiet window, and asserting the restore holds off until they stop.
        var config = Config.bootstrap()
        config.autoTriggers = AutoTriggerSettings(onDisplayChange: false, onAppLaunch: false, onWake: true)
        let state = AppState(config: config)
        let store = try makeStore()
        let probe = StubWindowProbe(handles: [makeHandle(bundleID: "com.example.one")])
        let coordinator = ActionCoordinator(
            state: state,
            store: store,
            probe: probe,
            mutator: RecordingWindowMutator(),
            gate: StubAccessibilityGate())
        let triggers = AutoTriggerController(
            state: state,
            coordinator: coordinator,
            probe: probe,
            debounceInterval: 0.05,
            settleQuietWindow: 0.4,
            settleCap: 5.0)
        defer { triggers.stop() }

        // Wake plus an immediate display event so the settle gate has a recent
        // reconfigure to wait on.
        triggers.scheduleSettledRestore(reason: .wake)
        triggers.scheduleSettledRestore(reason: .displayChange)
        for _ in 0..<4 {
            try await Task.sleep(for: .milliseconds(100))
            triggers.scheduleSettledRestore(reason: .displayChange)
        }
        // Still churning (gaps < quiet window): the restore must not have run.
        #expect(probe.snapshotCalls == 0)

        // Stop churning; after the quiet window the deferred restore runs once.
        try await Task.sleep(for: .milliseconds(700))
        #expect(probe.snapshotCalls == 1)
    }

    @Test
    func correctivePassSettledTreatsErroredBundleFlippedToUnmatchedAsUnsettled() {
        // Change #2: a bundle that errored on the original pass is only
        // "settled" once it is neither erroring nor unmatched. The
        // errored->unmatched flip (display transiently absent) must read as
        // not-yet-settled.
        let pending: Set = ["com.ghostty"]

        let flippedToUnmatched = ActionCoordinator.RestoreResult(
            applied: 3, errors: 0, drifted: 0, queued: 0, proportional: 0,
            erroredBundles: [], unmatchedBundles: ["com.ghostty"])
        #expect(AutoTriggerController.correctivePassSettled(flippedToUnmatched, pendingBundles: pending) == false)

        let stillErroring = ActionCoordinator.RestoreResult(
            applied: 0, errors: 1, drifted: 0, queued: 0, proportional: 0,
            erroredBundles: ["com.ghostty"], unmatchedBundles: [])
        #expect(AutoTriggerController.correctivePassSettled(stillErroring, pendingBundles: pending) == false)

        let proportionalRemains = ActionCoordinator.RestoreResult(
            applied: 1, errors: 0, drifted: 0, queued: 0, proportional: 1,
            erroredBundles: [], unmatchedBundles: [])
        #expect(AutoTriggerController.correctivePassSettled(proportionalRemains, pendingBundles: pending) == false)

        // Ghostty placed cleanly; other apps being unmatched is normal noise.
        let placed = ActionCoordinator.RestoreResult(
            applied: 4, errors: 0, drifted: 0, queued: 0, proportional: 0,
            erroredBundles: [], unmatchedBundles: ["com.finder", "com.safari"])
        #expect(AutoTriggerController.correctivePassSettled(placed, pendingBundles: pending) == true)
    }

    @Test(.disabled(if: !hasActiveDisplays, "requires at least one active display"))
    func displayChangeProportionalDrivesCorrectiveRetry() async throws {
        // A display-on / lock-resume restore (no sleep, so the wake path never
        // fires) must now get the same corrective-retry safety net as wake.
        // Previously the retry was gated on wake only, so a display-change
        // restore that hit transient AX errors got no second pass. Here the
        // target display is absent so every placement is proportional, arming
        // the retry; settle is disabled so the path runs deterministically.
        let bundleID = "com.example.one"
        let absent = DisplayFingerprint(
            uuid: UUID(),
            vendorID: 60001,
            productID: 60002,
            serialNumber: 60003,
            pointSize: CGSize(width: 5120, height: 2880),
            pixelSize: CGSize(width: 5120, height: 2880),
            scaleFactor: 1,
            globalOrigin: CGPoint(x: 99999, y: 99999),
            isPrimary: false)
        let rule = Rule(
            descriptiveLabel: "test",
            matchCriteria: MatchCriteria(bundleID: bundleID, applyToAllWindows: true),
            targetDisplay: absent,
            frame: WindowFrame(
                absolute: CGRect(x: 0, y: 0, width: 100, height: 100),
                normalised: UnitRect(x: 0, y: 0, width: 0.1, height: 0.1)),
            missingDisplayPolicy: .primaryProportional)
        var config = Config.bootstrap()
        config.autoTriggers = AutoTriggerSettings(onDisplayChange: true, onAppLaunch: false, onWake: false)
        config.layouts = [PutCore.Layout(name: "Test", rules: [rule])]
        config.activeLayoutID = config.layouts[0].id

        let state = AppState(config: config)
        let store = try makeStore()
        let probe = StubWindowProbe(handles: [makeHandle(bundleID: bundleID)])
        let coordinator = ActionCoordinator(
            state: state,
            store: store,
            probe: probe,
            mutator: RecordingWindowMutator(),
            gate: StubAccessibilityGate())
        let triggers = AutoTriggerController(
            state: state,
            coordinator: coordinator,
            probe: probe,
            debounceInterval: 0,
            wakeRetryDelays: [0.02, 0.02, 0.02],
            settleQuietWindow: 0,
            settleCap: 0)
        defer { triggers.stop() }

        // The trait guarantees a display is present; a missing one here is a
        // genuine failure, not a silent skip.
        let displays = try DisplayProbe.snapshot()
        try #require(!displays.isEmpty)

        triggers.scheduleSettledRestore(reason: .displayChange)
        try await Task.sleep(for: .milliseconds(300))

        // The first display-change restore places proportionally (errors=0),
        // which under the old wake-only gate would never retry. The fix arms a
        // corrective retry on the proportional signal for display-change too.
        #expect(probe.snapshotCalls >= 2)
    }
}
