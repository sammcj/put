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

// Navigation ("jump to window") coverage. Kept in its own file with minimal
// local doubles, mirroring the size-only suite, because the doubles in
// ActionCoordinatorTests are `private` to that struct and the combined file
// would exceed the length limit.

@MainActor
@Suite("ActionCoordinator jump-to-window")
struct ActionCoordinatorJumpTests {
    private struct Fixture {
        let coordinator: ActionCoordinator
        let probe: StubWindowProbe
        let mutator: RecordingWindowMutator
    }

    // MARK: - Fixtures

    private func makeHandle(bundleID: String, title: String = "Doc") -> WindowHandle {
        makeWindowHandle(bundleID: bundleID, title: title)
    }

    private func makeStore() throws -> ConfigStore {
        try makeTempStore(prefix: "put-jump").store
    }

    private func rule(bundleID: String) -> Rule {
        Rule(
            matchCriteria: MatchCriteria(bundleID: bundleID, applyToAllWindows: true),
            targetDisplay: DisplayFingerprint(
                uuid: UUID(),
                vendorID: 1,
                productID: 2,
                serialNumber: 3,
                pointSize: CGSize(width: 1920, height: 1080),
                pixelSize: CGSize(width: 3840, height: 2160),
                scaleFactor: 2,
                globalOrigin: .zero,
                isPrimary: true),
            frame: WindowFrame(
                absolute: CGRect(x: 0, y: 0, width: 100, height: 100),
                normalised: UnitRect(x: 0, y: 0, width: 0.1, height: 0.1)))
    }

    private func makeFixture(
        rules: [Rule],
        handles: [WindowHandle],
        trusted: Bool) throws -> Fixture
    {
        let layout = Layout(id: UUID(), name: "L", rules: rules)
        let state = AppState(config: Config(layouts: [layout], activeLayoutID: layout.id))
        let probe = StubWindowProbe(handles: handles)
        let mutator = RecordingWindowMutator()
        let coordinator = try ActionCoordinator(
            state: state,
            store: makeStore(),
            probe: probe,
            mutator: mutator,
            gate: StubAccessibilityGate(trusted: trusted))
        return Fixture(coordinator: coordinator, probe: probe, mutator: mutator)
    }

    // MARK: - Tests

    @Test
    func blockedWhenGateDenied() async throws {
        let target = rule(bundleID: "com.example.one")
        let fixture = try makeFixture(
            rules: [target],
            handles: [makeHandle(bundleID: "com.example.one")],
            trusted: false)

        let raised = await fixture.coordinator.jumpToWindow(ruleID: target.id)

        #expect(raised == false)
        #expect(fixture.probe.snapshotCalls == 0)
        #expect(fixture.mutator.raiseCalls.isEmpty)
    }

    @Test
    func raisesFirstMatchingWindow() async throws {
        let target = rule(bundleID: "com.example.two")
        let fixture = try makeFixture(
            rules: [target],
            handles: [makeHandle(bundleID: "com.example.one"), makeHandle(bundleID: "com.example.two")],
            trusted: true)

        let raised = await fixture.coordinator.jumpToWindow(ruleID: target.id)

        #expect(raised == true)
        #expect(fixture.mutator.raiseCalls.count == 1)
        #expect(fixture.mutator.raiseCalls.first?.descriptor.bundleID == "com.example.two")
    }

    @Test
    func returnsFalseWhenNoLiveWindowMatches() async throws {
        let target = rule(bundleID: "com.other.app")
        let fixture = try makeFixture(
            rules: [target],
            handles: [makeHandle(bundleID: "com.example.one")],
            trusted: true)

        let raised = await fixture.coordinator.jumpToWindow(ruleID: target.id)

        #expect(raised == false)
        #expect(fixture.mutator.raiseCalls.isEmpty)
    }

    @Test
    func returnsFalseForUnknownRule() async throws {
        let fixture = try makeFixture(
            rules: [],
            handles: [makeHandle(bundleID: "com.example.one")],
            trusted: true)

        let raised = await fixture.coordinator.jumpToWindow(ruleID: UUID())

        #expect(raised == false)
        #expect(fixture.probe.snapshotCalls == 0)
        #expect(fixture.mutator.raiseCalls.isEmpty)
    }

    @Test
    func firstWindowPicksEarliestMatchInOrder() {
        let target = rule(bundleID: "com.example.one")
        let first = makeHandle(bundleID: "com.example.one", title: "First")
        let second = makeHandle(bundleID: "com.example.one", title: "Second")
        let other = makeHandle(bundleID: "com.other.app", title: "Other")

        let match = ActionCoordinator.firstWindow(matching: target, among: [other, first, second])

        #expect(match?.descriptor.title == "First")
    }

    @Test
    func defaultInjectionSurfacesCompile() {
        _ = DefaultWindowProbe()
        _ = DefaultWindowMutator()
        _ = DefaultAccessibilityGate()
    }
}
