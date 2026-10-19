import CoreGraphics
import Foundation
@testable import PutAutomation
@testable import PutCore
import PutTestSupport
@testable import PutWindows
import Testing

@MainActor
@Suite("ActionCoordinator learned minimum sizes")
struct ActionCoordinatorMinimumSizeTests {
    private let bundle = "com.example.one"

    private func makeCoordinator() throws -> ActionCoordinator {
        try ActionCoordinator(
            state: AppState(config: .bootstrap()),
            store: makeTempStore(prefix: "put-minsize").store,
            probe: StubWindowProbe(),
            mutator: RecordingWindowMutator(),
            gate: StubAccessibilityGate(trusted: true))
    }

    private func makeRule(id: UUID = UUID(), components: RestoreComponents = .sizeAndPosition) -> Rule {
        Rule(
            id: id,
            matchCriteria: MatchCriteria(bundleID: bundle, applyToAllWindows: true),
            targetDisplay: DisplayFingerprint(
                uuid: UUID(), vendorID: 1, productID: 2, serialNumber: 3,
                pointSize: CGSize(width: 1920, height: 1080), pixelSize: CGSize(width: 3840, height: 2160),
                scaleFactor: 2, globalOrigin: .zero, isPrimary: true),
            frame: WindowFrame(
                absolute: CGRect(x: 0, y: 0, width: 500, height: 400),
                normalised: UnitRect(x: 0, y: 0, width: 0.26, height: 0.37)),
            restoreComponents: components)
    }

    /// The app shrank the window from 1200 wide to 700 and refused to go further.
    private func learnWidthFloor(_ coordinator: ActionCoordinator, rule: Rule) async {
        let handle = makeWindowHandle(bundleID: bundle, frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        await coordinator.learnMinimum(
            rule: rule,
            handle: handle,
            target: CGRect(x: 10, y: 20, width: 500, height: 400),
            actual: CGRect(x: 10, y: 20, width: 700, height: 400))
    }

    @Test
    func driftLearnedFromSnapshotFrameRaisesLaterTargets() async throws {
        let coordinator = try makeCoordinator()
        let rule = makeRule()
        await learnWidthFloor(coordinator, rule: rule)

        let next = CGRect(x: 30, y: 40, width: 500, height: 400)
        #expect(coordinator.respectingLearnedMinimum(next, rule: rule) == CGRect(x: 30, y: 40, width: 700, height: 400))
        let sizeOnly = makeRule(id: rule.id, components: .sizeOnly)
        #expect(coordinator.respectingLearnedMinimum(next, rule: sizeOnly).width == 700)
    }

    @Test
    func positionOnlyWritesAreLeftAlone() async throws {
        let coordinator = try makeCoordinator()
        let rule = makeRule()
        await learnWidthFloor(coordinator, rule: rule)
        let positionOnly = makeRule(id: rule.id, components: RestoreComponents(size: false, position: true))
        let next = CGRect(x: 30, y: 40, width: 500, height: 400)
        #expect(coordinator.respectingLearnedMinimum(next, rule: positionOnly) == next)
    }

    @Test
    func floorStaysWithTheRuleThatLearnedIt() async throws {
        // Two rules for the same app: a floor from one window must not enlarge
        // the other's target.
        let coordinator = try makeCoordinator()
        let learner = makeRule()
        await learnWidthFloor(coordinator, rule: learner)
        let next = CGRect(x: 30, y: 40, width: 500, height: 400)
        #expect(coordinator.respectingLearnedMinimum(next, rule: makeRule()) == next)
    }
}
