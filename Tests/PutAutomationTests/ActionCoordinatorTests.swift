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

@MainActor
@Suite("ActionCoordinator")
struct ActionCoordinatorTests {
    // MARK: - Test doubles

    private final class RecordingFlash: SaveFlashing, @unchecked Sendable {
        var calls: [[CGRect]] = []
        func flash(rects: [CGRect]) {
            calls.append(rects)
        }
    }

    private final class RecordingScopeNotice: SaveScopeNotifying, @unchecked Sendable {
        var calls: [(layoutName: String, skipped: [OutOfScopeSave])] = []
        func warnOutOfScopeSaves(layoutName: String, skipped: [OutOfScopeSave]) {
            calls.append((layoutName, skipped))
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
        flash: any SaveFlashing = NoopSaveFlashing(),
        scopeNotice: any SaveScopeNotifying = NoopSaveScopeNotifying()) -> ActionCoordinator
    {
        ActionCoordinator(
            state: state,
            store: store,
            probe: probe,
            mutator: mutator,
            gate: StubAccessibilityGate(trusted: trusted),
            saveFlash: flash,
            saveScopeNotice: scopeNotice)
    }

    // MARK: - Gate-trusted paths

    @Test
    func saveFlashFiresOncePerSuccessfulSaveCall() async throws {
        // Drive a save with a real probe that returns a single window whose
        // frame sits inside the running test host's primary display.
        // PlacementEngine builds a rule against the live displays and the
        // coordinator hands the saved frames to the recording flash.
        let state = makeState()
        let store = try makeStore()
        let frame = CGRect(x: 100, y: 100, width: 400, height: 300)
        let probe = StubWindowProbe(handles: [makeHandle(frame: frame)])
        let mutator = RecordingWindowMutator()
        let flash = RecordingFlash()
        let coordinator = makeCoordinator(
            state: state,
            store: store,
            probe: probe,
            mutator: mutator,
            trusted: true,
            flash: flash)

        await coordinator.saveFocusedWindowAllApp()

        // The probe is exercised; whether a rule actually lands depends on
        // whether the test host has at least one display, so we assert the
        // weaker invariant: if a rule was created, exactly one flash fired
        // with that rule's frame; if not, no flash fired.
        if let rules = state.activeLayout?.rules, !rules.isEmpty {
            #expect(flash.calls.count == 1)
            #expect(flash.calls.first?.first == frame)
        } else {
            #expect(flash.calls.isEmpty)
        }
    }

    @Test
    func saveSizeOnlyStampsRestoresPositionFalse() async throws {
        // A size-only save (restoresPosition: false) must create rules that
        // restore size but not position. A rule only lands when the test host
        // has a usable display, so gate the assertion the way the save-flash
        // test does. A default save is the control: same window, same layout,
        // but restoresPosition stays true.
        let frame = CGRect(x: 100, y: 100, width: 400, height: 300)

        let defaultState = makeState()
        let defaultStore = try makeStore()
        let defaultCoordinator = makeCoordinator(
            state: defaultState,
            store: defaultStore,
            probe: StubWindowProbe(handles: [makeHandle(frame: frame)]),
            mutator: RecordingWindowMutator(),
            trusted: true)
        await defaultCoordinator.saveAllWindows()

        let sizeOnlyState = makeState()
        let sizeOnlyStore = try makeStore()
        let sizeOnlyCoordinator = makeCoordinator(
            state: sizeOnlyState,
            store: sizeOnlyStore,
            probe: StubWindowProbe(handles: [makeHandle(frame: frame)]),
            mutator: RecordingWindowMutator(),
            trusted: true)
        await sizeOnlyCoordinator.saveAllWindows(restoresPosition: false)

        if let defaultRule = defaultState.activeLayout?.rules.first {
            #expect(defaultRule.restoresPosition == true)
            let sizeOnlyRule = try #require(sizeOnlyState.activeLayout?.rules.first)
            #expect(sizeOnlyRule.restoresPosition == false)
        }
    }

    @Test
    func saveSizeOnlyOverExistingRuleClearsPositionRestore() async throws {
        // Re-saving an app as size-only over a rule that previously restored
        // position must flip the existing rule's flag, not append a duplicate.
        let frame = CGRect(x: 100, y: 100, width: 400, height: 300)
        let state = makeState()
        let store = try makeStore()
        let coordinator = makeCoordinator(
            state: state,
            store: store,
            probe: StubWindowProbe(handles: [makeHandle(frame: frame)]),
            mutator: RecordingWindowMutator(),
            trusted: true)

        await coordinator.saveFocusedWindowAllApp()
        guard let seeded = state.activeLayout?.rules.first else {
            return // headless host: no rule landed, nothing to re-save
        }
        #expect(seeded.restoresPosition == true)

        await coordinator.saveFocusedWindowAllApp(restoresPosition: false)
        let rules = try #require(state.activeLayout?.rules)
        #expect(rules.count == 1)
        #expect(rules.first?.restoresPosition == false)
    }

    @Test
    func saveSkipsWindowOutsideActiveLayoutScopeAndNotifies() async throws {
        let store = try makeStore()
        let frame = CGRect(x: 100, y: 100, width: 400, height: 300)

        // Control: a no-scope layout imposes no display restriction, so a save
        // lands a rule iff the test host actually has a usable display. This
        // gates the assertions below so the test is robust on a headless host.
        let controlState = makeState(with: Layout(name: "Anywhere"))
        let control = makeCoordinator(
            state: controlState,
            store: store,
            probe: StubWindowProbe(handles: [makeHandle(frame: frame)]),
            mutator: RecordingWindowMutator(),
            trusted: true)
        await control.saveFocusedWindowAllApp()
        let hostHasDisplay = !(controlState.activeLayout?.rules.isEmpty ?? true)

        // A phantom display the live host can't match: any real saved window is
        // therefore out of scope for this layout.
        let phantom = DisplayFingerprint(
            uuid: UUID(),
            vendorID: nil,
            productID: nil,
            serialNumber: nil,
            pointSize: CGSize(width: 1234, height: 567),
            pixelSize: CGSize(width: 2468, height: 1134),
            scaleFactor: 2,
            globalOrigin: CGPoint(x: -99999, y: -99999),
            isPrimary: false,
            localizedName: "Phantom")
        let scopedLayout = Layout(
            name: "Laptop only",
            screenConfigs: [ScreenConfigTrigger(displays: [phantom])])
        let state = makeState(with: scopedLayout)
        let notice = RecordingScopeNotice()
        let coordinator = makeCoordinator(
            state: state,
            store: store,
            probe: StubWindowProbe(handles: [makeHandle(frame: frame)]),
            mutator: RecordingWindowMutator(),
            trusted: true,
            scopeNotice: notice)

        await coordinator.saveFocusedWindowAllApp()

        // The out-of-scope window is never stamped into the layout.
        #expect(state.activeLayout?.rules.isEmpty == true)
        if hostHasDisplay {
            #expect(notice.calls.count == 1)
            #expect(notice.calls.first?.layoutName == "Laptop only")
            #expect(notice.calls.first?.skipped.count == 1)
            #expect(notice.calls.first?.skipped.first?.displayName != nil)
        } else {
            #expect(notice.calls.isEmpty)
        }
    }

    @Test
    func saveFocusedAllAppReturnsCleanlyWithNoFocusedWindow() async throws {
        let state = makeState()
        let store = try makeStore()
        let probe = StubWindowProbe(handles: [])
        let mutator = RecordingWindowMutator()
        let coordinator = makeCoordinator(state: state, store: store, probe: probe, mutator: mutator, trusted: true)

        await coordinator.saveFocusedWindowAllApp()

        #expect(probe.focusedCalls == 1)
        #expect(state.activeLayout?.rules.isEmpty == true)
        #expect(mutator.frameCalls.isEmpty)
    }

    @Test
    func saveFocusedTitleOnlyReturnsCleanlyWithNoFocusedWindow() async throws {
        let state = makeState()
        let store = try makeStore()
        let probe = StubWindowProbe(handles: [])
        let mutator = RecordingWindowMutator()
        let coordinator = makeCoordinator(state: state, store: store, probe: probe, mutator: mutator, trusted: true)

        await coordinator.saveFocusedWindowTitleOnly()

        #expect(probe.focusedCalls == 1)
        #expect(state.activeLayout?.rules.isEmpty == true)
        #expect(mutator.frameCalls.isEmpty)
    }

    @Test
    func duplicateRuleAppendsCopyWithFreshID() async throws {
        let original = Rule(
            descriptiveLabel: "Main",
            matchCriteria: MatchCriteria(bundleID: "com.example.one"),
            targetDisplay: fingerprint(),
            frame: dummyFrame())
        let layout = Layout(id: UUID(), name: "L", rules: [original])
        let state = makeState(with: layout)
        let store = try makeStore()
        let probe = StubWindowProbe(handles: [])
        let mutator = RecordingWindowMutator()
        let coordinator = makeCoordinator(state: state, store: store, probe: probe, mutator: mutator, trusted: true)

        await coordinator.duplicateRule(id: original.id)

        let rules = try #require(state.activeLayout?.rules)
        #expect(rules.count == 2)
        #expect(rules[1].id != original.id)
        #expect(rules[1].descriptiveLabel == "Main (copy)")
    }

    // MARK: - Helpers

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
}

// MARK: - Size-only restore routing

//
// Lives in its own struct so the main `ActionCoordinator` suite stays under
// the type-body-length cap. Re-uses the same fake doubles the main suite
// established (StubWindowProbe / RecordingWindowMutator / StubAccessibilityGate / RecordingFlash); the
// shared scaffolding is duplicated in minimal form because the doubles are
// `private` to the main struct.

@MainActor
@Suite("ActionCoordinator size-only routing")
struct ActionCoordinatorSizeOnlyTests {
    private func makeHandle(bundleID: String = "com.example.one") -> WindowHandle {
        makeWindowHandle(
            bundleID: bundleID,
            title: "Doc.txt",
            frame: CGRect(x: 100, y: 100, width: 600, height: 400))
    }

    private func makeStore() throws -> ConfigStore {
        try makeTempStore(prefix: "put-action").store
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

    @Test
    func sizeOnlyRuleRoutesToSetSize() async throws {
        // Rule with restoresPosition=false must route through mutator.setSize
        // and never call mutator.setFrame. The setSize side only fires when
        // the test host has at least one connected display, so guard with an
        // existence check the way the main suite does.
        let rule = Rule(
            matchCriteria: MatchCriteria(bundleID: "com.example.one", applyToAllWindows: true),
            targetDisplay: fingerprint(),
            frame: dummyFrame(),
            restoresPosition: false)
        let layout = Layout(id: UUID(), name: "L", rules: [rule])
        let state = AppState(config: Config(layouts: [layout], activeLayoutID: layout.id))
        let store = try makeStore()
        let handle = makeHandle()
        let mutator = RecordingWindowMutator()
        let coordinator = ActionCoordinator(
            state: state,
            store: store,
            probe: StubWindowProbe(handles: [handle]),
            mutator: mutator,
            gate: StubAccessibilityGate())

        await coordinator.restore(windowsForUI: [handle])

        #expect(mutator.frameCalls.isEmpty)
        if !mutator.sizeCalls.isEmpty {
            #expect(mutator.sizeCalls.count == 1)
            #expect(mutator.sizeCalls.first?.0.descriptor.bundleID == "com.example.one")
        }
    }

    @Test
    func positionRestoreRuleRoutesToSetFrame() async throws {
        let rule = Rule(
            matchCriteria: MatchCriteria(bundleID: "com.example.one", applyToAllWindows: true),
            targetDisplay: fingerprint(),
            frame: dummyFrame())
        let layout = Layout(id: UUID(), name: "L", rules: [rule])
        let state = AppState(config: Config(layouts: [layout], activeLayoutID: layout.id))
        let store = try makeStore()
        let handle = makeHandle()
        let mutator = RecordingWindowMutator()
        let coordinator = ActionCoordinator(
            state: state,
            store: store,
            probe: StubWindowProbe(handles: [handle]),
            mutator: mutator,
            gate: StubAccessibilityGate())

        await coordinator.restore(windowsForUI: [handle])

        #expect(mutator.sizeCalls.isEmpty)
        if !mutator.frameCalls.isEmpty {
            #expect(mutator.frameCalls.count == 1)
        }
    }

    @Test
    func restoreResultCountsProportionalPlacements() async throws {
        // A rule whose target display can't match the host (bogus identity)
        // resolves via the primaryProportional fallback, so any placement is
        // proportional. RestoreResult.proportional must reflect that - it's the
        // signal the wake-retry uses to schedule a corrective pass once a
        // transiently-mis-resolved panel settles.
        let absentDisplay = DisplayFingerprint(
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
            matchCriteria: MatchCriteria(bundleID: "com.example.one", applyToAllWindows: true),
            targetDisplay: absentDisplay,
            frame: dummyFrame(),
            missingDisplayPolicy: .primaryProportional)
        let layout = Layout(id: UUID(), name: "L", rules: [rule])
        let state = AppState(config: Config(layouts: [layout], activeLayoutID: layout.id))
        let store = try makeStore()
        let handle = makeHandle()
        let coordinator = ActionCoordinator(
            state: state,
            store: store,
            probe: StubWindowProbe(handles: [handle]),
            mutator: RecordingWindowMutator(),
            gate: StubAccessibilityGate())

        let result = await coordinator.restoreAllWindows(source: .auto)

        // Headless hosts have no displays and apply nothing; only assert when a
        // placement actually happened. Every applied placement here is forced
        // proportional, so the counts must match and be non-zero.
        if let result, result.applied > 0 {
            #expect(result.proportional == result.applied)
            #expect(result.proportional > 0)
            #expect(result.errors == 0)
        }
    }
}

@MainActor
extension ActionCoordinatorTests {
    @Test
    func saveFocusedWindowSkipsPutsOwnWindow() async throws {
        // The Rules tab "+" makes Put frontmost, so a naive focused-window save
        // captures Put itself and pollutes the layout with a self-rule. The
        // coordinator must refuse to save a window of its own bundle.
        guard let ownBundleID = Bundle.main.bundleIdentifier else {
            // Ephemeral xctest host with no bundle identifier; the exclusion
            // can't be exercised deterministically here.
            return
        }
        let state = makeState()
        let store = try makeStore()
        let probe = StubWindowProbe(handles: [makeHandle(bundleID: ownBundleID)])
        let mutator = RecordingWindowMutator()
        let flash = RecordingFlash()
        let coordinator = makeCoordinator(
            state: state,
            store: store,
            probe: probe,
            mutator: mutator,
            trusted: true,
            flash: flash)

        await coordinator.saveFocusedWindowAllApp()

        #expect(state.activeLayout?.rules.isEmpty == true, "Put's own window must not become a rule")
        #expect(flash.calls.isEmpty)
    }
}
