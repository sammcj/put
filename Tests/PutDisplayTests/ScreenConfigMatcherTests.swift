import CoreGraphics
import Foundation
@testable import PutCore
@testable import PutDisplay
import PutTestSupport
import Testing

@Suite("ScreenConfigMatcher")
struct ScreenConfigMatcherTests {
    private func makeFingerprint(
        uuid: UUID? = UUID(),
        origin: CGPoint = .zero,
        isPrimary: Bool = false,
        name: String? = nil) -> DisplayFingerprint
    {
        makeDisplayFingerprint(
            uuid: uuid,
            vendorID: 0x0610,
            productID: 0xA123,
            serialNumber: 1,
            pointSize: CGSize(width: 1920, height: 1080),
            globalOrigin: origin,
            isPrimary: isPrimary,
            localizedName: name)
    }

    /// A twin display: same vendor+product, nil serial, nil UUID, so two of
    /// them share one fingerprint `id`. Only `globalOrigin` distinguishes them.
    private func makeTwin(origin: CGPoint, isPrimary: Bool = false) -> DisplayFingerprint {
        makeDisplayFingerprint(
            uuid: nil,
            vendorID: 0x0610,
            productID: 0xA123,
            serialNumber: nil,
            pointSize: CGSize(width: 1920, height: 1080),
            globalOrigin: origin,
            isPrimary: isPrimary)
    }

    @Test
    func emptyTriggerNeverMatches() {
        let trigger = ScreenConfigTrigger(displays: [])
        #expect(ScreenConfigMatcher.evaluate(trigger: trigger, against: [makeFingerprint()]) == .noMatch)
    }

    @Test
    func mismatchedSizesNoMatch() {
        let display = makeFingerprint()
        let trigger = ScreenConfigTrigger(displays: [display, makeFingerprint()])
        #expect(ScreenConfigMatcher.evaluate(trigger: trigger, against: [display]) == .noMatch)
    }

    @Test
    func sameUUIDsMatchWithoutArrangement() {
        let primary = makeFingerprint(uuid: UUID(), origin: .zero, isPrimary: true)
        let secondary = makeFingerprint(uuid: UUID(), origin: CGPoint(x: 1920, y: 0))
        let trigger = ScreenConfigTrigger(
            displays: [primary, secondary],
            arrangementStrict: false)
        #expect(ScreenConfigMatcher.evaluate(trigger: trigger, against: [secondary, primary]) == .matched)
    }

    @Test
    func arrangementStrictRejectsRearrangedDisplays() {
        let aID = UUID()
        let bID = UUID()
        let capturedA = makeFingerprint(uuid: aID, origin: .zero)
        let capturedB = makeFingerprint(uuid: bID, origin: CGPoint(x: 1920, y: 0))
        let liveA = makeFingerprint(uuid: aID, origin: .zero)
        let liveB = makeFingerprint(uuid: bID, origin: CGPoint(x: -1920, y: 0))

        let trigger = ScreenConfigTrigger(displays: [capturedA, capturedB], arrangementStrict: true)
        #expect(ScreenConfigMatcher.evaluate(trigger: trigger, against: [liveA, liveB]) == .noMatch)
    }

    @Test
    func arrangementStrictAcceptsTranslatedButRelativelyIdenticalArrangement() {
        // The whole display set has shifted by a constant offset (e.g. macOS
        // re-anchored after primary changed). Relative positions still match,
        // so the trigger should fire.
        let aID = UUID()
        let bID = UUID()
        let capturedA = makeFingerprint(uuid: aID, origin: .zero)
        let capturedB = makeFingerprint(uuid: bID, origin: CGPoint(x: 1920, y: 0))
        let liveA = makeFingerprint(uuid: aID, origin: CGPoint(x: 100, y: 200))
        let liveB = makeFingerprint(uuid: bID, origin: CGPoint(x: 2020, y: 200))

        let trigger = ScreenConfigTrigger(displays: [capturedA, capturedB], arrangementStrict: true)
        #expect(ScreenConfigMatcher.evaluate(trigger: trigger, against: [liveA, liveB]) == .matched)
    }

    @Test
    func arrangementLooseAcceptsRearrangedDisplays() {
        let aID = UUID()
        let bID = UUID()
        let capturedA = makeFingerprint(uuid: aID, origin: .zero)
        let capturedB = makeFingerprint(uuid: bID, origin: CGPoint(x: 1920, y: 0))
        let liveA = makeFingerprint(uuid: aID, origin: .zero)
        let liveB = makeFingerprint(uuid: bID, origin: CGPoint(x: -1920, y: 0))

        let trigger = ScreenConfigTrigger(displays: [capturedA, capturedB], arrangementStrict: false)
        #expect(ScreenConfigMatcher.evaluate(trigger: trigger, against: [liveA, liveB]) == .matched)
    }

    @Test
    func extraConnectedDisplayBlocksMatch() {
        // Strict identity-set semantics: a third display plugged in shouldn't
        // satisfy a captured pair. The user wants the layout for exactly that
        // arrangement, not a superset.
        let aID = UUID()
        let bID = UUID()
        let captured = [makeFingerprint(uuid: aID), makeFingerprint(uuid: bID)]
        let live = captured + [makeFingerprint(uuid: UUID())]

        let trigger = ScreenConfigTrigger(displays: captured, arrangementStrict: false)
        #expect(ScreenConfigMatcher.evaluate(trigger: trigger, against: live) == .noMatch)
    }

    @Test
    func vendorTupleStandsInForUUID() {
        let captured = DisplayFingerprint(
            uuid: nil,
            vendorID: 0x0610,
            productID: 0xA123,
            serialNumber: 7,
            pointSize: CGSize(width: 2560, height: 1440),
            pixelSize: CGSize(width: 5120, height: 2880),
            scaleFactor: 2,
            globalOrigin: .zero,
            isPrimary: true)
        let live = DisplayFingerprint(
            uuid: UUID(),
            vendorID: 0x0610,
            productID: 0xA123,
            serialNumber: 7,
            pointSize: CGSize(width: 2560, height: 1440),
            pixelSize: CGSize(width: 5120, height: 2880),
            scaleFactor: 2,
            globalOrigin: .zero,
            isPrimary: true)
        let trigger = ScreenConfigTrigger(displays: [captured], arrangementStrict: true)
        #expect(ScreenConfigMatcher.evaluate(trigger: trigger, against: [live]) == .matched)
    }

    @Test
    func twinDisplaysInExactConfigurationMatch() {
        // Two identical twins share a fingerprint id (nil serial, nil UUID).
        // Id-based consumption removed BOTH from the candidate pool after the
        // first pairing, forcing .noMatch on an exact configuration.
        // Per-instance consumption must let the second twin still pair.
        let capturedA = makeTwin(origin: .zero, isPrimary: true)
        let capturedB = makeTwin(origin: CGPoint(x: 1920, y: 0))
        let liveA = makeTwin(origin: .zero, isPrimary: true)
        let liveB = makeTwin(origin: CGPoint(x: 1920, y: 0))
        let trigger = ScreenConfigTrigger(displays: [capturedA, capturedB], arrangementStrict: false)
        #expect(ScreenConfigMatcher.evaluate(trigger: trigger, against: [liveA, liveB]) == .matched)
    }

    @Test
    func twinsCrosswiseArrangementPairsByGeometry() {
        // Twins share an id, and the live array lists them in the opposite
        // order to the captured set. A greedy first-match would pair crosswise
        // and spuriously fail arrangementsAlign. The geometry tie-break must
        // pair each captured display with the live twin at the same origin.
        let capturedA = makeTwin(origin: .zero, isPrimary: true)
        let capturedB = makeTwin(origin: CGPoint(x: 1920, y: 0))
        let liveRight = makeTwin(origin: CGPoint(x: 1920, y: 0))
        let liveLeft = makeTwin(origin: .zero, isPrimary: true)
        let trigger = ScreenConfigTrigger(displays: [capturedA, capturedB], arrangementStrict: true)
        #expect(ScreenConfigMatcher.evaluate(trigger: trigger, against: [liveRight, liveLeft]) == .matched)
    }
}
