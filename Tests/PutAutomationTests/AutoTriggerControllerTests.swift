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

@MainActor
@Suite("AutoTriggerController")
struct AutoTriggerControllerTests {
    private func makeHandle(bundleID: String) -> WindowHandle {
        makeWindowHandle(bundleID: bundleID)
    }

    private func makeStore() throws -> ConfigStore {
        try makeTempStore(prefix: "put-auto").store
    }

    @Test
    func startThenStopIsSymmetric() throws {
        let state = AppState(config: .bootstrap())
        let store = try makeStore()
        let probe = StubWindowProbe()
        let coordinator = ActionCoordinator(
            state: state,
            store: store,
            probe: probe,
            mutator: RecordingWindowMutator(),
            gate: StubAccessibilityGate(trusted: false))
        let triggers = AutoTriggerController(
            state: state,
            coordinator: coordinator,
            probe: probe,
            debounceInterval: 0)

        triggers.start()
        triggers.stop()
        // No exception thrown and the controller can be started again without
        // double-registering NSWorkspace observers.
        triggers.start()
        triggers.stop()
    }

    @Test
    func appLaunchIgnoredWhenFlagOff() async throws {
        var config = Config.bootstrap()
        config.autoTriggers = AutoTriggerSettings(onDisplayChange: true, onAppLaunch: false, onWake: true)
        let state = AppState(config: config)
        let store = try makeStore()
        let probe = StubWindowProbe(handles: [makeHandle(bundleID: "com.example.one")])
        let mutator = RecordingWindowMutator()
        let coordinator = ActionCoordinator(
            state: state,
            store: store,
            probe: probe,
            mutator: mutator,
            gate: StubAccessibilityGate(trusted: true))
        let triggers = AutoTriggerController(
            state: state,
            coordinator: coordinator,
            probe: probe,
            debounceInterval: 0)

        // Post a synthesised app-launch notification with the user-info shape
        // the real NSWorkspace notification uses.
        triggers.start()
        defer { triggers.stop() }

        let fakeApp = NSRunningApplication.current
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didLaunchApplicationNotification,
            object: NSWorkspace.shared,
            userInfo: [NSWorkspace.applicationUserInfoKey: fakeApp])
        // The handler spawns a detached Task that sleeps 500 ms; give it a
        // window to run. With the flag off we expect bundleCalls to stay at 0.
        try await Task.sleep(for: .milliseconds(750))
        #expect(probe.bundleCalls.isEmpty)
    }

    @Test
    func wakeCoalescesIntoSingleRestore() async throws {
        // Regression guard for "windows don't all place back after wake from
        // sleep". Previously onWake fired a fixed-delay restore that racing
        // CGDisplayReconfiguration events would then find in-flight, causing
        // the display-change restore to be dropped by ActionCoordinator's
        // isRestoring guard. With the unified debouncer, wake and display
        // events coalesce into exactly one restore.
        var config = Config.bootstrap()
        config.autoTriggers = AutoTriggerSettings(
            onDisplayChange: true,
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
            gate: StubAccessibilityGate(trusted: true))
        let triggers = AutoTriggerController(
            state: state,
            coordinator: coordinator,
            probe: probe,
            debounceInterval: 0.2)

        triggers.start()
        defer { triggers.stop() }

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: NSWorkspace.shared)
        try await Task.sleep(for: .milliseconds(50))
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: NSWorkspace.shared)
        try await Task.sleep(for: .milliseconds(500))
        #expect(probe.snapshotCalls == 1)
    }

    @Test
    func wakeSkippedWhenFlagOff() async throws {
        var config = Config.bootstrap()
        config.autoTriggers = AutoTriggerSettings(
            onDisplayChange: false,
            onAppLaunch: false,
            onWake: false,
            onPutLaunch: false)
        let state = AppState(config: config)
        let store = try makeStore()
        let probe = StubWindowProbe(handles: [makeHandle(bundleID: "com.example.one")])
        let coordinator = ActionCoordinator(
            state: state,
            store: store,
            probe: probe,
            mutator: RecordingWindowMutator(),
            gate: StubAccessibilityGate(trusted: true))
        let triggers = AutoTriggerController(
            state: state,
            coordinator: coordinator,
            probe: probe,
            debounceInterval: 0.1)

        triggers.start()
        defer { triggers.stop() }

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: NSWorkspace.shared)
        try await Task.sleep(for: .milliseconds(300))
        #expect(probe.snapshotCalls == 0)
    }

    @Test
    func appLaunchRunsProbeWhenFlagOn() async throws {
        // This test confirms the probe wiring. NSRunningApplication.current
        // has a known bundleIdentifier that we can filter on.
        var config = Config.bootstrap()
        config.autoTriggers = AutoTriggerSettings(onDisplayChange: true, onAppLaunch: true, onWake: true)
        let state = AppState(config: config)
        let store = try makeStore()
        let probe = StubWindowProbe()
        let mutator = RecordingWindowMutator()
        let coordinator = ActionCoordinator(
            state: state,
            store: store,
            probe: probe,
            mutator: mutator,
            gate: StubAccessibilityGate(trusted: true))
        let triggers = AutoTriggerController(
            state: state,
            coordinator: coordinator,
            probe: probe,
            debounceInterval: 0)

        triggers.start()
        defer { triggers.stop() }

        guard let bundleID = NSRunningApplication.current.bundleIdentifier else {
            // Test host without a bundleIdentifier (ephemeral xctest). Skip
            // the probe assertion; the important part is the dispatch path
            // compiles and start/stop is stable.
            return
        }
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didLaunchApplicationNotification,
            object: NSWorkspace.shared,
            userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
        try await Task.sleep(for: .milliseconds(750))
        #expect(probe.bundleCalls.contains(bundleID))
    }

    @Test
    func appLaunchRetriesUntilBudgetExhausted() async throws {
        // Regression guard for "Messages didn't move on launch": a one-shot
        // 500 ms probe is too short for cold-launched apps. The retry loop
        // re-probes on every backoff step until something applies or the
        // budget runs out.
        var config = Config.bootstrap()
        config.autoTriggers = AutoTriggerSettings(onDisplayChange: false, onAppLaunch: true, onWake: false)

        let bundleID = NSRunningApplication.current.bundleIdentifier ?? "com.example.test"
        let rule = Rule(
            descriptiveLabel: "test",
            matchCriteria: MatchCriteria(bundleID: bundleID, applyToAllWindows: true),
            targetDisplay: DisplayFingerprint(
                uuid: nil,
                vendorID: nil,
                productID: nil,
                serialNumber: nil,
                pointSize: CGSize(width: 1000, height: 800),
                pixelSize: CGSize(width: 1000, height: 800),
                scaleFactor: 1,
                globalOrigin: .zero,
                isPrimary: true,
                localizedName: "Stub"),
            frame: WindowFrame(
                absolute: CGRect(x: 0, y: 0, width: 100, height: 100),
                normalised: UnitRect(x: 0, y: 0, width: 0.1, height: 0.1)))
        config.layouts = [PutCore.Layout(name: "Test", rules: [rule])]
        config.activeLayoutID = config.layouts[0].id

        let state = AppState(config: config)
        let store = try makeStore()
        let probe = StubWindowProbe()
        let coordinator = ActionCoordinator(
            state: state,
            store: store,
            probe: probe,
            mutator: RecordingWindowMutator(),
            gate: StubAccessibilityGate(trusted: true))
        let triggers = AutoTriggerController(
            state: state,
            coordinator: coordinator,
            probe: probe,
            debounceInterval: 0,
            launchRetryDelays: [
                .milliseconds(20),
                .milliseconds(20),
                .milliseconds(20)
            ])

        triggers.start()
        defer { triggers.stop() }

        triggers.onAppLaunched(bundleID: bundleID)
        try await Task.sleep(for: .milliseconds(200))
        #expect(probe.bundleCalls.count(where: { $0 == bundleID }) == 3)
    }

    @Test
    func appLaunchRetryCancelsOnRelaunch() async throws {
        // A second launch of the same bundleID before the first retry loop
        // finishes must cancel the in-flight task. Otherwise stacked tasks
        // would each fire a restore long after the user has moved the new
        // window.
        var config = Config.bootstrap()
        config.autoTriggers = AutoTriggerSettings(onDisplayChange: false, onAppLaunch: true, onWake: false)

        let bundleID = NSRunningApplication.current.bundleIdentifier ?? "com.example.test"
        let rule = Rule(
            descriptiveLabel: "test",
            matchCriteria: MatchCriteria(bundleID: bundleID, applyToAllWindows: true),
            targetDisplay: DisplayFingerprint(
                uuid: nil,
                vendorID: nil,
                productID: nil,
                serialNumber: nil,
                pointSize: CGSize(width: 1000, height: 800),
                pixelSize: CGSize(width: 1000, height: 800),
                scaleFactor: 1,
                globalOrigin: .zero,
                isPrimary: true,
                localizedName: "Stub"),
            frame: WindowFrame(
                absolute: CGRect(x: 0, y: 0, width: 100, height: 100),
                normalised: UnitRect(x: 0, y: 0, width: 0.1, height: 0.1)))
        config.layouts = [PutCore.Layout(name: "Test", rules: [rule])]
        config.activeLayoutID = config.layouts[0].id

        let state = AppState(config: config)
        let store = try makeStore()
        let probe = StubWindowProbe()
        let coordinator = ActionCoordinator(
            state: state,
            store: store,
            probe: probe,
            mutator: RecordingWindowMutator(),
            gate: StubAccessibilityGate(trusted: true))
        let triggers = AutoTriggerController(
            state: state,
            coordinator: coordinator,
            probe: probe,
            debounceInterval: 0,
            launchRetryDelays: Array(repeating: .milliseconds(50), count: 6))

        triggers.start()
        defer { triggers.stop() }

        triggers.onAppLaunched(bundleID: bundleID)
        try await Task.sleep(for: .milliseconds(75))
        let countAfterFirstLaunch = probe.bundleCalls.count(where: { $0 == bundleID })

        triggers.onAppLaunched(bundleID: bundleID)
        try await Task.sleep(for: .milliseconds(400))
        let total = probe.bundleCalls.count(where: { $0 == bundleID })
        // Without cancellation, two stacked schedules of 6 attempts each
        // would compound to 12+. Cancellation caps the total near one full
        // schedule plus the partial first run.
        //
        // The upper bound carries slack because the split between "attempt
        // belongs to the cancelled schedule" and "cancellation has taken
        // effect" is not observable: a 50ms tick can land between sampling
        // countAfterFirstLaunch and the relaunch that cancels it, counting an
        // attempt this arithmetic attributes to neither run. One full schedule
        // plus two straddling attempts still separates cancelled (<= 8) from
        // uncancelled (12+), which is the whole point of the test. Tightening
        // this to +6 makes it fail roughly one run in six.
        #expect(total >= countAfterFirstLaunch + 4)
        #expect(total <= countAfterFirstLaunch + 8)
    }

    @Test
    func queuedDisplayOnlyRuleWritesPositionOnlyAndDrainsTheQueue() async throws {
        // The reconnect path resolves per window and picks the write from the
        // rule's scope. A display-only rule must reach setPosition and neither
        // setFrame nor setSize, and the rule must leave the queue.
        guard let primary = try? DisplayProbe.snapshot().first(where: { $0.isPrimary }) else { return }
        let handle = makeWindowHandle(
            bundleID: "com.example.one",
            frame: CGRect(x: 120, y: 140, width: 600, height: 400))
        let rule = Rule(
            matchCriteria: MatchCriteria(bundleID: "com.example.one", applyToAllWindows: true),
            targetDisplay: primary,
            frame: WindowFrame(
                absolute: CGRect(x: 0, y: 0, width: 100, height: 100),
                normalised: UnitRect(x: 0, y: 0, width: 0.1, height: 0.1)),
            missingDisplayPolicy: .queueForReconnect,
            restoreScope: .displayOnly)
        let layout = Layout(id: UUID(), name: "L", rules: [rule])
        let state = AppState(
            config: Config(layouts: [layout], activeLayoutID: layout.id),
            queuedRuleIDs: [rule.id])
        let store = try makeStore()
        let probe = StubWindowProbe(handles: [handle])
        let mutator = RecordingWindowMutator()
        let coordinator = ActionCoordinator(
            state: state,
            store: store,
            probe: probe,
            mutator: mutator,
            gate: StubAccessibilityGate(trusted: true))
        let triggers = AutoTriggerController(
            state: state,
            coordinator: coordinator,
            probe: probe,
            mutator: mutator,
            debounceInterval: 0)

        await triggers.fulfilQueuedRules()

        #expect(mutator.frameCalls.isEmpty)
        #expect(mutator.sizeCalls.isEmpty)
        #expect(mutator.positionCalls.count == 1)
        // Already on the target display, so the write is the window's own
        // origin - the no-op the suppression exemption relies on.
        #expect(mutator.positionCalls.first?.1 == handle.descriptor.frame.origin)
        #expect(state.queuedRuleIDs.isEmpty)
    }
}
