import CoreGraphics
import Foundation
@testable import PutCore
@testable import PutDisplay
@testable import PutPlacement
import Testing

@Suite("PlacementEngine")
struct PlacementEngineTests {
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
        bundle: String = "com.apple.Safari") -> Rule
    {
        let unit = normalised ?? Coordinates.normalise(localFrame, onDisplay: display)
        return Rule(
            descriptiveLabel: "test",
            matchCriteria: MatchCriteria(bundleID: bundle),
            targetDisplay: display,
            frame: WindowFrame(absolute: localFrame, normalised: unit),
            missingDisplayPolicy: policy)
    }

    // MARK: - Scenarios

    @Test
    func noDisplaysProducesNoDisplay() {
        let disp = display()
        let testRule = rule(onDisplay: disp, localFrame: CGRect(x: 10, y: 20, width: 100, height: 50))
        #expect(PlacementEngine.resolve(rule: testRule, displays: []) == .noDisplay)
    }

    @Test
    func sameResolutionReplayUsesAbsolute() {
        let uuid = UUID()
        let saved = display(uuid: uuid, origin: .zero, point: CGSize(width: 1920, height: 1080))
        let current = display(uuid: uuid, origin: .zero, point: CGSize(width: 1920, height: 1080))
        let testRule = rule(onDisplay: saved, localFrame: CGRect(x: 100, y: 50, width: 800, height: 600))

        guard case let .applyFrame(frame, displayPicked, quality, fidelity) = PlacementEngine.resolve(
            rule: testRule,
            displays: [current])
        else {
            Issue.record("Expected applyFrame")
            return
        }
        #expect(quality == .exact)
        #expect(fidelity == .exact)
        #expect(displayPicked.uuid == uuid)
        #expect(frame == CGRect(x: 100, y: 50, width: 800, height: 600))
    }

    @Test
    func samePanelOnShiftedArrangementReapplyRelativeToCurrentOrigin() {
        let uuid = UUID()
        let saved = display(uuid: uuid, origin: .zero, point: CGSize(width: 1920, height: 1080))
        // Same panel but arranged so its top-left is now at (-1728, 720).
        let current = display(uuid: uuid, origin: CGPoint(x: -1728, y: 720), point: CGSize(width: 1920, height: 1080))
        let testRule = rule(onDisplay: saved, localFrame: CGRect(x: 100, y: 50, width: 800, height: 600))

        guard case let .applyFrame(frame, _, quality, fidelity) = PlacementEngine
            .resolve(rule: testRule, displays: [current])
        else {
            Issue.record("Expected applyFrame")
            return
        }
        #expect(quality == .exact)
        #expect(fidelity == .exact)
        #expect(frame == CGRect(x: 100 - 1728, y: 50 + 720, width: 800, height: 600))
    }

    @Test
    func downscaledReplayUsesProportional() {
        let uuid = UUID()
        let saved = display(uuid: uuid, point: CGSize(width: 3840, height: 2160))
        let current = display(uuid: uuid, point: CGSize(width: 1920, height: 1080))
        // Saved as a rect covering the left half of the saved display.
        let testRule = rule(onDisplay: saved, localFrame: CGRect(x: 0, y: 0, width: 1920, height: 2160))

        guard case let .applyFrame(frame, _, quality, fidelity) = PlacementEngine
            .resolve(rule: testRule, displays: [current])
        else {
            Issue.record("Expected applyFrame")
            return
        }
        // UUID identity match but the resolution changed, so the absolute frame
        // no longer fits and the engine remaps proportionally.
        #expect(quality == .exact)
        #expect(fidelity == .proportional)
        #expect(frame == CGRect(x: 0, y: 0, width: 960, height: 1080))
    }

    @Test
    func looksLikeScaleChangeTriggersProportional() {
        let uuid = UUID()
        // Saved with scale 2, restoring under scale 1.5. Same point size but
        // different pixel size -> sameGeometry returns false.
        let saved = display(
            uuid: uuid,
            point: CGSize(width: 1920, height: 1080),
            pixel: CGSize(width: 3840, height: 2160),
            scale: 2)
        let current = display(
            uuid: uuid,
            point: CGSize(width: 1920, height: 1080),
            pixel: CGSize(width: 2880, height: 1620),
            scale: 1.5)
        let testRule = rule(onDisplay: saved, localFrame: CGRect(x: 0, y: 0, width: 960, height: 540))

        guard case let .applyFrame(frame, _, _, fidelity) = PlacementEngine
            .resolve(rule: testRule, displays: [current])
        else {
            Issue.record("Expected applyFrame")
            return
        }
        // Point size is identical, so proportional denormalise round-trips
        // to (approximately) the same point-rect - but the differing pixel
        // size/scale still marks the placement proportional.
        #expect(fidelity == .proportional)
        #expect(abs(frame.width - 960) < 1e-6)
        #expect(abs(frame.height - 540) < 1e-6)
    }

    @Test
    func missingDisplayFallsBackToPrimaryProportional() {
        let savedTarget = display(uuid: UUID(), point: CGSize(width: 3840, height: 2160), primary: false)
        let primary = display(uuid: UUID(), point: CGSize(width: 1920, height: 1080), primary: true)

        let testRule = rule(onDisplay: savedTarget, localFrame: CGRect(x: 0, y: 0, width: 3840, height: 1080))

        guard case let .applyFrame(frame, chosen, quality, fidelity) = PlacementEngine
            .resolve(rule: testRule, displays: [primary])
        else {
            Issue.record("Expected applyFrame")
            return
        }
        // The matcher returns `.similar` for the closest-size candidate, which
        // PlacementEngine now prefers over `.primary` under
        // `.primaryProportional`. When the closest candidate happens to also
        // be the primary, the `.similar` label still applies.
        #expect(quality == .similar)
        #expect(fidelity == .proportional)
        #expect(chosen.uuid == primary.uuid)
        // Full width of saved -> full width of similar; half height of saved -> half height of similar.
        #expect(frame == CGRect(x: 0, y: 0, width: 1920, height: 540))
    }

    @Test
    func missingDisplayWithSkipPolicyProducesSkipped() {
        let savedTarget = display(uuid: UUID(), primary: false)
        let primary = display(uuid: UUID(), primary: true)
        let testRule = rule(
            onDisplay: savedTarget,
            localFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            policy: .skip)

        let decision = PlacementEngine.resolve(rule: testRule, displays: [primary])
        guard case .skipped = decision else {
            Issue.record("Expected skipped, got \(decision)")
            return
        }
    }

    @Test
    func missingDisplayWithQueuePolicyProducesQueued() {
        let savedTarget = display(uuid: UUID(), primary: false)
        let primary = display(uuid: UUID(), primary: true)
        let testRule = rule(
            onDisplay: savedTarget,
            localFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            policy: .queueForReconnect)

        let decision = PlacementEngine.resolve(rule: testRule, displays: [primary])
        guard case let .queuedForReconnect(targetID) = decision else {
            Issue.record("Expected queued, got \(decision)")
            return
        }
        #expect(targetID == savedTarget.id)
    }

    @Test
    func vendorMatchAcceptsReplugAsEquivalent() {
        let savedUUID = UUID()
        let saved = display(
            uuid: savedUUID,
            point: CGSize(width: 2560, height: 1440),
            primary: false,
            vendor: 7,
            product: 9,
            serial: 100)
        // On replug the UUID may change; vendor/product/serial stay stable.
        let current = display(
            uuid: UUID(),
            point: CGSize(width: 2560, height: 1440),
            primary: false,
            vendor: 7,
            product: 9,
            serial: 100)

        let testRule = rule(onDisplay: saved, localFrame: CGRect(x: 100, y: 100, width: 500, height: 500))
        guard case let .applyFrame(_, _, quality, fidelity) = PlacementEngine
            .resolve(rule: testRule, displays: [current])
        else {
            Issue.record("Expected applyFrame")
            return
        }
        // Replug keeps the same geometry, so the saved absolute frame replays.
        #expect(quality == .equivalent)
        #expect(fidelity == .exact)
    }

    @Test
    func queuedReconnectWithEmptyDisplaysShortCircuitsToNoDisplay() {
        let savedTarget = display(uuid: UUID(), primary: false)
        let testRule = rule(
            onDisplay: savedTarget,
            localFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            policy: .queueForReconnect)
        let decision = PlacementEngine.resolve(rule: testRule, displays: [])
        guard case .noDisplay = decision else {
            Issue.record("Expected noDisplay when no displays are connected, got \(decision)")
            return
        }
    }

    @Test
    func equivalentMatchWithChangedPointSizeUsesProportional() {
        // Same panel (vendor/product/serial), but user changed the resolution,
        // so pointSize differs. Engine must denormalise rather than replay
        // absolute coords.
        let saved = display(
            uuid: UUID(),
            point: CGSize(width: 2560, height: 1440),
            primary: true,
            vendor: 1,
            product: 2,
            serial: 3)
        let current = display(
            uuid: UUID(),
            point: CGSize(width: 1920, height: 1080),
            primary: true,
            vendor: 1,
            product: 2,
            serial: 3)
        // Rule saved at x:1280, width:1280 on a 2560-wide display (right half).
        let testRule = rule(
            onDisplay: saved,
            localFrame: CGRect(x: 1280, y: 0, width: 1280, height: 720))
        guard case let .applyFrame(frame, _, quality, fidelity) = PlacementEngine
            .resolve(rule: testRule, displays: [current])
        else {
            Issue.record("Expected applyFrame")
            return
        }
        #expect(quality == .equivalent)
        #expect(fidelity == .proportional)
        // Denormalised onto the smaller panel: right half of 1920x1080.
        #expect(abs(frame.width - 960) < 1e-6)
        #expect(abs(frame.origin.x - 960) < 1e-6)
    }

    @Test
    func vendorProductMatchWithoutSerialOnCurrentDisplay() {
        // Saved rule has serial; current display has matching vendor/product
        // but the serial field is missing (some displays don't report one).
        // Matcher should still recognise as equivalent.
        let saved = display(uuid: UUID(), primary: false, vendor: 7, product: 9, serial: 100)
        let current = display(uuid: UUID(), primary: false, vendor: 7, product: 9, serial: nil)

        let testRule = rule(onDisplay: saved, localFrame: CGRect(x: 0, y: 0, width: 500, height: 500))
        let decision = PlacementEngine.resolve(rule: testRule, displays: [current])
        guard case let .applyFrame(_, _, quality, fidelity) = decision else {
            Issue.record("Expected applyFrame, got \(decision)")
            return
        }
        #expect(quality == .equivalent)
        #expect(fidelity == .exact)
    }

    @Test
    func buildRuleFromGlobalFrameCapturesTargetAndNormalised() {
        let laptop = display(
            uuid: UUID(),
            origin: CGPoint(x: -1728, y: 720),
            point: CGSize(width: 1728, height: 1117),
            primary: false)
        let primary = display(
            uuid: UUID(),
            origin: .zero,
            point: CGSize(width: 3840, height: 2160),
            primary: true)
        let globalFrame = CGRect(x: -1628, y: 820, width: 800, height: 600)

        let built = PlacementEngine.buildRule(
            matchCriteria: MatchCriteria(bundleID: "com.apple.Safari"),
            descriptiveLabel: "",
            globalFrame: globalFrame,
            displays: [laptop, primary])
        guard let built else {
            Issue.record("Expected buildRule to succeed")
            return
        }
        #expect(built.targetDisplay.uuid == laptop.uuid)
        #expect(built.frame.absolute == CGRect(x: 100, y: 100, width: 800, height: 600))
        #expect(built.frame.normalised.isNormalised)
    }
}
