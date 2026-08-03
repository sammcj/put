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
            restoreComponents: .displayOnly)
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
