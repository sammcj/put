import CoreGraphics
import Foundation
@testable import PutCore
@testable import PutDisplay
@testable import PutPlacement
import Testing

/// Display-only scope cases, kept in their own suite so `PlacementEngineTests`
/// stays under the type-body cap. Same helper shape as that suite.
@Suite("PlacementEngine display-only")
struct PlacementEngineDisplayOnlyTests {
    // MARK: - Helpers

    private func display(
        uuid: UUID? = nil,
        origin: CGPoint = .zero,
        point: CGSize = CGSize(width: 1920, height: 1080),
        pixel: CGSize? = nil,
        scale: Double = 1,
        primary: Bool = true,
        vendor: UInt32? = nil,
        product: UInt32? = nil,
        serial: UInt32? = nil) -> DisplayFingerprint
    {
        DisplayFingerprint(
            uuid: uuid,
            vendorID: vendor,
            productID: product,
            serialNumber: serial,
            pointSize: point,
            pixelSize: pixel ?? CGSize(width: point.width * CGFloat(scale), height: point.height * CGFloat(scale)),
            scaleFactor: scale,
            globalOrigin: origin,
            isPrimary: primary)
    }

    private func rule(
        onDisplay display: DisplayFingerprint,
        localFrame: CGRect,
        normalised: UnitRect? = nil,
        policy: MissingDisplayPolicy = .primaryProportional,
        scope: RestoreComponents = .sizeAndPosition,
        bundle: String = "com.apple.Safari") -> Rule
    {
        let unit = normalised ?? Coordinates.normalise(localFrame, onDisplay: display)
        return Rule(
            descriptiveLabel: "test",
            matchCriteria: MatchCriteria(bundleID: bundle),
            targetDisplay: display,
            frame: WindowFrame(absolute: localFrame, normalised: unit),
            missingDisplayPolicy: policy,
            restoreComponents: scope)
    }

    // MARK: - Scenarios

    @Test
    func displayOnlyMovesWindowKeepingItsSize() {
        // The window is on the laptop; the rule targets the external panel.
        // Size is untouched and the window's centre maps proportionally.
        let laptopID = UUID()
        let externalID = UUID()
        let laptop = display(uuid: laptopID, origin: .zero, point: CGSize(width: 1600, height: 1000), primary: true)
        let external = display(
            uuid: externalID,
            origin: CGPoint(x: 1600, y: 0),
            point: CGSize(width: 3200, height: 2000),
            primary: false)
        let testRule = rule(
            onDisplay: external,
            localFrame: CGRect(x: 0, y: 0, width: 900, height: 700),
            scope: .displayOnly)

        guard case let .applyFrame(frame, displayPicked, _, fidelity) = PlacementEngine.resolve(
            rule: testRule,
            displays: [laptop, external],
            currentFrame: CGRect(x: 400, y: 200, width: 900, height: 700))
        else {
            Issue.record("Expected applyFrame")
            return
        }
        #expect(displayPicked.uuid == externalID)
        #expect(fidelity == .exact)
        // Centre (850, 550) is 53.125% / 55% into the laptop, so it lands at
        // (1700, 1100) on the external panel; origin is that less half the size.
        #expect(frame == CGRect(x: 1600 + 1250, y: 750, width: 900, height: 700))
    }

    @Test
    func displayOnlyIsNoOpWhenWindowIsAlreadyOnTarget() {
        // Baseline for the whole path: a contained window on its target display
        // resolves to its own frame. (The same-display short-circuit isn't what
        // makes this pass - a same-display proportional map is 1:1 anyway - so
        // `displayOnlyLeavesAnOverhangingWindowAlone` is the case that pins it.)
        let externalID = UUID()
        let laptop = display(uuid: UUID(), origin: .zero, point: CGSize(width: 1600, height: 1000), primary: true)
        let external = display(
            uuid: externalID,
            origin: CGPoint(x: 1600, y: 0),
            point: CGSize(width: 3200, height: 2000),
            primary: false)
        let testRule = rule(
            onDisplay: external,
            localFrame: CGRect(x: 0, y: 0, width: 900, height: 700),
            scope: .displayOnly)
        let current = CGRect(x: 2100, y: 640, width: 900, height: 700)

        guard case let .applyFrame(frame, _, _, _) = PlacementEngine.resolve(
            rule: testRule,
            displays: [laptop, external],
            currentFrame: current)
        else {
            Issue.record("Expected applyFrame")
            return
        }
        #expect(frame == current)
    }

    @Test
    func displayOnlyLeavesAnOverhangingWindowAlone() {
        // A window the user deliberately parked hanging off the left edge of
        // the target display must not be tugged back inside. Without the
        // same-display short-circuit the clamp would move it, and because
        // display-only rules are exempt from moved-by-user suppression, every
        // wake and display change would move it again.
        let externalID = UUID()
        let laptop = display(uuid: UUID(), origin: .zero, point: CGSize(width: 1600, height: 1000), primary: true)
        let external = display(
            uuid: externalID,
            origin: CGPoint(x: 1600, y: 0),
            point: CGSize(width: 3200, height: 2000),
            primary: false)
        let testRule = rule(
            onDisplay: external,
            localFrame: CGRect(x: 0, y: 0, width: 900, height: 700),
            scope: .displayOnly)
        // Straddles the seam, but two thirds of it is on the external panel.
        let current = CGRect(x: 1300, y: 400, width: 900, height: 700)

        guard case let .applyFrame(frame, displayPicked, _, _) = PlacementEngine.resolve(
            rule: testRule,
            displays: [laptop, external],
            currentFrame: current)
        else {
            Issue.record("Expected applyFrame")
            return
        }
        #expect(displayPicked.uuid == externalID)
        #expect(frame == current)
    }

    @Test
    func displayOnlyFallsBackToSubstituteDisplayWhenTargetMissing() {
        // Target unplugged, policy is primaryProportional: the window still
        // gets moved from the panel it's on (the laptop) onto the substitute
        // (the wide secondary) at its current size, flagged proportional so the
        // wake-retry re-checks once displays settle.
        let laptop = display(uuid: UUID(), origin: .zero, point: CGSize(width: 1600, height: 1000), primary: true)
        let substitute = display(
            uuid: UUID(),
            origin: CGPoint(x: 1600, y: 0),
            point: CGSize(width: 3000, height: 1900),
            primary: false)
        let absent = display(
            uuid: UUID(),
            origin: CGPoint(x: -3200, y: 0),
            point: CGSize(width: 3200, height: 2000),
            primary: false)
        let testRule = rule(
            onDisplay: absent,
            localFrame: CGRect(x: 0, y: 0, width: 900, height: 700),
            scope: .displayOnly)

        guard case let .applyFrame(frame, displayPicked, _, fidelity) = PlacementEngine.resolve(
            rule: testRule,
            displays: [laptop, substitute],
            currentFrame: CGRect(x: 160, y: 100, width: 900, height: 700))
        else {
            Issue.record("Expected applyFrame")
            return
        }
        // Closest point size wins the substitution, not the primary.
        #expect(displayPicked.uuid == substitute.uuid)
        #expect(fidelity == .proportional)
        // Centre (610, 450) maps to (1143.75, 855) on the substitute; origin is
        // that less half the (unchanged) window size.
        #expect(frame == CGRect(x: 1600 + 693.75, y: 505, width: 900, height: 700))
    }

    @Test
    func displayOnlyWithoutALiveWindowSkipsRatherThanResizing() {
        // Nothing to move, so do nothing. Falling back to the saved frame would
        // resize the window, which is the one thing this scope promises never
        // to do.
        let saved = display(uuid: UUID(), origin: .zero, point: CGSize(width: 1600, height: 1000))
        let testRule = rule(
            onDisplay: saved,
            localFrame: CGRect(x: 120, y: 80, width: 900, height: 700),
            scope: .displayOnly)

        guard case .skipped = PlacementEngine.resolve(rule: testRule, displays: [saved]) else {
            Issue.record("Expected skipped")
            return
        }
    }

    @Test
    func displayOnlyWithANonFiniteCurrentFrameSkips() {
        // A garbage frame must not reach `Coordinates.moving`, whose division
        // would propagate NaN into an AX position write.
        let saved = display(uuid: UUID(), origin: .zero, point: CGSize(width: 1600, height: 1000))
        let testRule = rule(
            onDisplay: saved,
            localFrame: CGRect(x: 120, y: 80, width: 900, height: 700),
            scope: .displayOnly)

        guard case .skipped = PlacementEngine.resolve(
            rule: testRule,
            displays: [saved],
            currentFrame: CGRect(x: CGFloat.nan, y: 0, width: 900, height: 700))
        else {
            Issue.record("Expected skipped")
            return
        }
    }

    @Test
    func displayOnlyWithAWindowOffEveryDisplaySkips() {
        // `Coordinates.displayContaining` answers a save-time question and
        // falls back to primary for a frame overlapping nothing. Translating
        // from a display the window isn't on would invent an origin - a failed
        // AX read gives CGRect.zero, which would land the window on the
        // target's top-left corner.
        let primary = display(uuid: UUID(), origin: .zero, point: CGSize(width: 1600, height: 1000), primary: true)
        let testRule = rule(
            onDisplay: primary,
            localFrame: CGRect(x: 120, y: 80, width: 900, height: 700),
            scope: .displayOnly)

        guard case .skipped = PlacementEngine.resolve(
            rule: testRule,
            displays: [primary],
            currentFrame: .zero)
        else {
            Issue.record("Expected skipped")
            return
        }
    }
}
