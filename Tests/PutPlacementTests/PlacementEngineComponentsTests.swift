import CoreGraphics
import Foundation
@testable import PutCore
@testable import PutDisplay
@testable import PutPlacement
import Testing

/// Combinations the superseded three-way scope couldn't express: size on a
/// target display, and a saved position without a saved size. Same helper shape
/// as `PlacementEngineTests`, kept separate so each suite stays under the
/// type-body cap.
@Suite("PlacementEngine restore components")
struct PlacementEngineComponentsTests {
    // MARK: - Helpers

    private let laptop = DisplayFingerprint(
        uuid: UUID(),
        vendorID: nil,
        productID: nil,
        serialNumber: nil,
        pointSize: CGSize(width: 1600, height: 1000),
        pixelSize: CGSize(width: 1600, height: 1000),
        scaleFactor: 1,
        globalOrigin: .zero,
        isPrimary: true)

    private let external = DisplayFingerprint(
        uuid: UUID(),
        vendorID: nil,
        productID: nil,
        serialNumber: nil,
        pointSize: CGSize(width: 3200, height: 2000),
        pixelSize: CGSize(width: 3200, height: 2000),
        scaleFactor: 1,
        globalOrigin: CGPoint(x: 1600, y: 0),
        isPrimary: false)

    private func rule(
        onDisplay display: DisplayFingerprint,
        localFrame: CGRect,
        components: RestoreComponents) -> Rule
    {
        Rule(
            descriptiveLabel: "test",
            matchCriteria: MatchCriteria(bundleID: "com.apple.Safari"),
            targetDisplay: display,
            frame: WindowFrame(
                absolute: localFrame,
                normalised: Coordinates.normalise(localFrame, onDisplay: display)),
            restoreComponents: components)
    }

    private static let sizeAndDisplay = RestoreComponents(size: true, position: false, display: true)
    private static let positionOnly = RestoreComponents(size: false, position: true, display: true)

    // MARK: - Size on a target display

    @Test
    func sizeWithDisplayMovesAndResizes() {
        // The window is on the laptop at 600x400; the rule wants it on the
        // external panel at its saved 900x700, positioned by where it sat.
        let testRule = rule(
            onDisplay: external,
            localFrame: CGRect(x: 0, y: 0, width: 900, height: 700),
            components: Self.sizeAndDisplay)

        guard case let .applyFrame(frame, displayPicked, _, fidelity) = PlacementEngine.resolve(
            rule: testRule,
            displays: [laptop, external],
            currentFrame: CGRect(x: 400, y: 200, width: 600, height: 400))
        else {
            Issue.record("Expected applyFrame")
            return
        }
        #expect(displayPicked.uuid == external.uuid)
        #expect(fidelity == .exact)
        // Centre (700, 400) is 43.75% / 40% into the laptop, so it lands at
        // (1400, 800) on the external panel. The origin is that less half the
        // *saved* size, not the size the window arrived with.
        #expect(frame == CGRect(x: 1600 + 950, y: 450, width: 900, height: 700))
    }

    @Test
    func sizeWithDisplayResizesInPlaceOnTheTargetDisplay() {
        // Already on the right display: the position is left exactly alone and
        // only the size changes. Same guarantee display-only relies on, minus
        // the resize this rule asked for.
        let testRule = rule(
            onDisplay: external,
            localFrame: CGRect(x: 0, y: 0, width: 900, height: 700),
            components: Self.sizeAndDisplay)

        guard case let .applyFrame(frame, _, _, _) = PlacementEngine.resolve(
            rule: testRule,
            displays: [laptop, external],
            currentFrame: CGRect(x: 2100, y: 640, width: 600, height: 400))
        else {
            Issue.record("Expected applyFrame")
            return
        }
        #expect(frame == CGRect(x: 2100, y: 640, width: 900, height: 700))
    }

    @Test
    func sizeWithDisplayClampsAGrowingWindowBackOntoTheDisplay() {
        // Parked near the bottom-right of the target panel and about to grow:
        // keeping the origin would push most of the window off the display. The
        // rule asked for a size, not for the window to leave.
        let testRule = rule(
            onDisplay: external,
            localFrame: CGRect(x: 0, y: 0, width: 900, height: 700),
            components: Self.sizeAndDisplay)

        guard case let .applyFrame(frame, _, _, _) = PlacementEngine.resolve(
            rule: testRule,
            displays: [laptop, external],
            // Local (2700, 1700) on the 3200x2000 external panel.
            currentFrame: CGRect(x: 1600 + 2700, y: 1700, width: 500, height: 200))
        else {
            Issue.record("Expected applyFrame")
            return
        }
        // Pulled back to local (2300, 1300): 3200 - 900 and 2000 - 700.
        #expect(frame == CGRect(x: 1600 + 2300, y: 1300, width: 900, height: 700))
    }

    @Test
    func displayOnlyStillLeavesAnOverhangingWindowExactlyWhereItIs() {
        // The clamp above must not reach the no-resize case: a window the user
        // parked hanging off an edge stays put, which is what lets display-only
        // rules skip moved-by-user suppression.
        let testRule = rule(
            onDisplay: external,
            localFrame: CGRect(x: 0, y: 0, width: 900, height: 700),
            components: .displayOnly)
        let overhanging = CGRect(x: 1600 + 2900, y: 1900, width: 500, height: 200)

        guard case let .applyFrame(frame, _, _, _) = PlacementEngine.resolve(
            rule: testRule,
            displays: [laptop, external],
            currentFrame: overhanging)
        else {
            Issue.record("Expected applyFrame")
            return
        }
        #expect(frame == overhanging)
    }

    @Test
    func sizeWithDisplaySkipsWhenTheWindowIsOnNoDisplay() {
        // No live frame to derive a position from, and this rule has no saved
        // position of its own. Resizing at the saved origin would move the
        // window somewhere it never asked to be.
        let testRule = rule(
            onDisplay: external,
            localFrame: CGRect(x: 0, y: 0, width: 900, height: 700),
            components: Self.sizeAndDisplay)

        guard case let .skipped(reason) = PlacementEngine.resolve(
            rule: testRule,
            displays: [laptop, external],
            currentFrame: nil)
        else {
            Issue.record("Expected skipped")
            return
        }
        #expect(reason == PlacementEngine.derivedPositionSkipReason)
    }

    @Test
    func sizeWithDisplayFallsBackProportionallyWhenTargetIsAbsent() {
        // External unplugged, policy is the proportional fallback: the saved
        // size is denormalised onto the substitute panel (900/3200 of its
        // width), and the window keeps where it sits on that panel.
        let testRule = rule(
            onDisplay: external,
            localFrame: CGRect(x: 0, y: 0, width: 900, height: 700),
            components: Self.sizeAndDisplay)

        guard case let .applyFrame(frame, displayPicked, _, fidelity) = PlacementEngine.resolve(
            rule: testRule,
            displays: [laptop],
            currentFrame: CGRect(x: 400, y: 200, width: 600, height: 400))
        else {
            Issue.record("Expected applyFrame")
            return
        }
        #expect(displayPicked.uuid == laptop.uuid)
        #expect(fidelity == .proportional)
        #expect(frame == CGRect(x: 400, y: 200, width: 450, height: 350))
    }

    // MARK: - Saved position without saved size

    @Test
    func positionWithoutSizeKeepsTheWindowsCurrentSize() {
        let testRule = rule(
            onDisplay: external,
            localFrame: CGRect(x: 100, y: 50, width: 900, height: 700),
            components: Self.positionOnly)

        guard case let .applyFrame(frame, _, _, _) = PlacementEngine.resolve(
            rule: testRule,
            displays: [laptop, external],
            currentFrame: CGRect(x: 400, y: 200, width: 600, height: 400))
        else {
            Issue.record("Expected applyFrame")
            return
        }
        #expect(frame == CGRect(x: 1700, y: 50, width: 600, height: 400))
    }

    @Test
    func positionWithoutSizeFallsBackToTheSavedSizeWithNoLiveWindow() {
        // The UI preview resolves without a live window. Only the origin is
        // written at restore time, so the size here just has to be sane.
        let testRule = rule(
            onDisplay: external,
            localFrame: CGRect(x: 100, y: 50, width: 900, height: 700),
            components: Self.positionOnly)

        guard case let .applyFrame(frame, _, _, _) = PlacementEngine.resolve(
            rule: testRule,
            displays: [laptop, external],
            currentFrame: nil)
        else {
            Issue.record("Expected applyFrame")
            return
        }
        #expect(frame == CGRect(x: 1700, y: 50, width: 900, height: 700))
    }

    // MARK: - Unchanged shapes

    @Test
    func sizeOnlyStillResolvesTheSavedFrame() {
        // Only the size is written, so the origin the engine returns is the
        // saved one and the window doesn't move.
        let testRule = rule(
            onDisplay: external,
            localFrame: CGRect(x: 100, y: 50, width: 900, height: 700),
            components: .sizeOnly)

        guard case let .applyFrame(frame, _, _, _) = PlacementEngine.resolve(
            rule: testRule,
            displays: [laptop, external],
            currentFrame: CGRect(x: 400, y: 200, width: 600, height: 400))
        else {
            Issue.record("Expected applyFrame")
            return
        }
        #expect(frame == CGRect(x: 1700, y: 50, width: 900, height: 700))
    }

    @Test
    func noComponentsSkipsBeforeResolvingADisplay() {
        let testRule = rule(
            onDisplay: external,
            localFrame: CGRect(x: 100, y: 50, width: 900, height: 700),
            components: RestoreComponents(size: false, position: false, display: false))

        guard case let .skipped(reason) = PlacementEngine.resolve(
            rule: testRule,
            displays: [laptop, external],
            currentFrame: CGRect(x: 400, y: 200, width: 600, height: 400))
        else {
            Issue.record("Expected skipped")
            return
        }
        #expect(reason == PlacementEngine.inertRuleSkipReason)
    }
}
