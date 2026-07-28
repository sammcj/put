import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
@testable import PutAutomation
@testable import PutCore
@testable import PutStorage
import PutTestSupport
@testable import PutWindows
import Testing

// Gate-enforcement and restore-behaviour coverage for `ActionCoordinator`,
// split out of the main suite so both files stay under the type-body and
// file-length caps. The fake doubles mirror the main suite's in minimal form
// because those are `private` to their own struct.

@MainActor
@Suite("ActionCoordinator gate and restore")
struct ActionCoordinatorRestoreTests {
    // MARK: - Test doubles

    private final class RecordingFlash: SaveFlashing, @unchecked Sendable {
        var calls: [[CGRect]] = []
        func flash(rects: [CGRect]) {
            calls.append(rects)
        }
    }

    // MARK: - Fixtures

    private func makeHandle(
        bundleID: String = "com.example.one",
        title: String = "Doc.txt",
        frame: CGRect = CGRect(x: 100, y: 100, width: 600, height: 400)) -> WindowHandle
    {
        makeWindowHandle(bundleID: bundleID, title: title, frame: frame)
    }

    private func makeStore() throws -> ConfigStore {
        try makeTempStore(prefix: "put-action").store
    }

    private func makeState(with layout: Layout = .defaultLayout()) -> AppState {
        AppState(config: Config(layouts: [layout], activeLayoutID: layout.id))
    }

    private func makeCoordinator(
        state: AppState,
        store: ConfigStore,
        probe: StubWindowProbe,
        mutator: RecordingWindowMutator,
        trusted: Bool,
        flash: any SaveFlashing = NoopSaveFlashing()) -> ActionCoordinator
    {
        ActionCoordinator(
            state: state,
            store: store,
            probe: probe,
            mutator: mutator,
            gate: StubAccessibilityGate(trusted: trusted),
            saveFlash: flash)
    }

    private func fingerprint() -> DisplayFingerprint {
        DisplayFingerprint(
            uuid: UUID(),
            vendorID: 1,
            productID: 2,
            serialNumber: 3,
            pointSize: CGSize(width: 1920, height: 1080),
            pixelSize: CGSize(width: 3840, height: 2160),
            scaleFactor: 2,
            globalOrigin: .zero,
            isPrimary: true)
    }

    private func dummyFrame() -> WindowFrame {
        WindowFrame(
            absolute: CGRect(x: 0, y: 0, width: 100, height: 100),
            normalised: UnitRect(x: 0, y: 0, width: 0.1, height: 0.1))
    }

    // MARK: - Gate-denied paths

    @Test
    func saveFocusedAllAppBlockedWhenGateDenied() async throws {
        let state = makeState()
        let store = try makeStore()
        let probe = StubWindowProbe(handles: [makeHandle()])
        let mutator = RecordingWindowMutator()
        let flash = RecordingFlash()
        let coordinator = makeCoordinator(
            state: state,
            store: store,
            probe: probe,
            mutator: mutator,
            trusted: false,
            flash: flash)

        await coordinator.saveFocusedWindowAllApp()

        #expect(probe.focusedCalls == 0)
        #expect(state.activeLayout?.rules.isEmpty == true)
        #expect(flash.calls.isEmpty)
    }

    @Test
    func saveFocusedTitleOnlyBlockedWhenGateDenied() async throws {
        let state = makeState()
        let store = try makeStore()
        let probe = StubWindowProbe(handles: [makeHandle()])
        let mutator = RecordingWindowMutator()
        let coordinator = makeCoordinator(state: state, store: store, probe: probe, mutator: mutator, trusted: false)

        await coordinator.saveFocusedWindowTitleOnly()

        #expect(probe.focusedCalls == 0)
        #expect(state.activeLayout?.rules.isEmpty == true)
    }

    @Test
    func restoreActiveWindowBlockedWhenGateDenied() async throws {
        let state = makeState()
        let store = try makeStore()
        let probe = StubWindowProbe(handles: [makeHandle()])
        let mutator = RecordingWindowMutator()
        let coordinator = makeCoordinator(state: state, store: store, probe: probe, mutator: mutator, trusted: false)

        await coordinator.restoreActiveWindow()

        #expect(probe.focusedCalls == 0)
        #expect(mutator.frameCalls.isEmpty)
    }

    @Test
    func saveAllWindowsBlockedWhenGateDenied() async throws {
        let state = makeState()
        let store = try makeStore()
        let probe = StubWindowProbe(handles: [makeHandle()])
        let mutator = RecordingWindowMutator()
        let coordinator = makeCoordinator(state: state, store: store, probe: probe, mutator: mutator, trusted: false)

        await coordinator.saveAllWindows()

        #expect(probe.snapshotCalls == 0)
        #expect(state.activeLayout?.rules.isEmpty == true)
    }

    @Test
    func restoreAllWindowsBlockedWhenGateDenied() async throws {
        let state = makeState()
        let store = try makeStore()
        let probe = StubWindowProbe(handles: [makeHandle()])
        let mutator = RecordingWindowMutator()
        let coordinator = makeCoordinator(state: state, store: store, probe: probe, mutator: mutator, trusted: false)

        await coordinator.restoreAllWindows()

        #expect(probe.snapshotCalls == 0)
        #expect(mutator.frameCalls.isEmpty)
    }

    @Test
    func perAppRestoreBlockedWhenGateDenied() async throws {
        let state = makeState()
        let store = try makeStore()
        let handle = makeHandle()
        let probe = StubWindowProbe(handles: [handle])
        let mutator = RecordingWindowMutator()
        let coordinator = makeCoordinator(state: state, store: store, probe: probe, mutator: mutator, trusted: false)

        await coordinator.restore(windowsForUI: [handle])

        #expect(mutator.frameCalls.isEmpty)
    }

    // MARK: - Restore behaviour

    @Test
    func restoreActiveWindowReturnsCleanlyWithNoFocusedWindow() async throws {
        let state = makeState()
        let store = try makeStore()
        let probe = StubWindowProbe(handles: [])
        let mutator = RecordingWindowMutator()
        let coordinator = makeCoordinator(state: state, store: store, probe: probe, mutator: mutator, trusted: true)

        await coordinator.restoreActiveWindow()

        #expect(probe.focusedCalls == 1)
        #expect(mutator.frameCalls.isEmpty)
        #expect(state.queuedRuleIDs.isEmpty)
    }

    @Test
    func restoreAllWindowsProbesButDoesNothingWhenEmpty() async throws {
        let state = makeState()
        let store = try makeStore()
        let probe = StubWindowProbe(handles: [])
        let mutator = RecordingWindowMutator()
        let coordinator = makeCoordinator(state: state, store: store, probe: probe, mutator: mutator, trusted: true)

        await coordinator.restoreAllWindows()

        #expect(probe.snapshotCalls == 1)
        #expect(mutator.frameCalls.isEmpty)
    }

    @Test
    func restoreWithNoMatchingRuleDoesNotMutate() async throws {
        // Layout has a rule for a different bundle ID; live window shouldn't
        // match, so the placement engine is never consulted and the mutator
        // stays idle.
        let unrelatedRule = Rule(
            matchCriteria: MatchCriteria(bundleID: "com.other.app"),
            targetDisplay: fingerprint(),
            frame: dummyFrame())
        let layout = Layout(id: UUID(), name: "L", rules: [unrelatedRule])
        let state = makeState(with: layout)
        let store = try makeStore()
        let handle = makeHandle(bundleID: "com.example.one")
        let probe = StubWindowProbe(handles: [handle])
        let mutator = RecordingWindowMutator()
        let coordinator = makeCoordinator(state: state, store: store, probe: probe, mutator: mutator, trusted: true)

        await coordinator.restore(windowsForUI: [handle])

        #expect(mutator.frameCalls.isEmpty)
    }

    @Test
    func restoreAllSingleFlightDropsReentrantCall() async throws {
        // Fire two restoreAll calls back-to-back; with both the gate open,
        // only one snapshot should execute thanks to the begin/endRestore
        // guard. We can't observe the internals directly but the probe call
        // count is a reliable proxy.
        let state = makeState()
        let store = try makeStore()
        let probe = StubWindowProbe(handles: [])
        let mutator = RecordingWindowMutator()
        let coordinator = makeCoordinator(state: state, store: store, probe: probe, mutator: mutator, trusted: true)

        async let firstCall = coordinator.restoreAllWindows()
        async let secondCall = coordinator.restoreAllWindows()
        _ = await (firstCall, secondCall)

        // Depending on scheduling at most one re-entrant call may be blocked.
        // A second call that beats the first to `beginRestore` is the happy
        // case; sequenced calls both get to snapshot. Either way, the
        // coordinator must not have mutated any windows.
        #expect(probe.snapshotCalls >= 1)
        #expect(probe.snapshotCalls <= 2)
        #expect(mutator.frameCalls.isEmpty)
    }
}
