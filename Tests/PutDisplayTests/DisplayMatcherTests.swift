import CoreGraphics
import Foundation
@testable import PutCore
@testable import PutDisplay
import PutTestSupport
import Testing

@Suite("DisplayMatcher")
struct DisplayMatcherTests {
    private func makeFingerprint(
        uuid: UUID? = nil,
        vendor: UInt32? = nil,
        product: UInt32? = nil,
        serial: UInt32? = nil,
        point: CGSize = CGSize(width: 1920, height: 1080),
        pixel: CGSize = CGSize(width: 1920, height: 1080),
        scale: Double = 1,
        origin: CGPoint = .zero,
        primary: Bool = false) -> DisplayFingerprint
    {
        makeDisplayFingerprint(
            uuid: uuid,
            vendorID: vendor,
            productID: product,
            serialNumber: serial,
            pointSize: point,
            pixelSize: pixel,
            scaleFactor: scale,
            globalOrigin: origin,
            isPrimary: primary)
    }

    @Test
    func noCandidatesReturnsNil() {
        let target = makeFingerprint(uuid: UUID())
        #expect(DisplayMatcher.resolve(target: target, among: []) == nil)
    }

    @Test
    func uuidMatchBeatsEverythingElse() {
        let uuid = UUID()
        let target = makeFingerprint(uuid: uuid, vendor: 1, product: 1)
        let candidates = [
            makeFingerprint(uuid: UUID(), vendor: 1, product: 1, point: .zero),
            makeFingerprint(uuid: uuid, vendor: 9, product: 9, point: CGSize(width: 100, height: 100)),
            makeFingerprint(uuid: nil, vendor: 1, product: 1)
        ]
        let result = DisplayMatcher.resolve(target: target, among: candidates)
        #expect(result?.quality == .exact)
        #expect(result?.display.uuid == uuid)
    }

    @Test
    func vendorProductSerialIsPreferredWhenNoUUIDMatch() {
        let target = makeFingerprint(vendor: 5, product: 6, serial: 7)
        let candidates = [
            makeFingerprint(vendor: 5, product: 6, serial: 99),
            makeFingerprint(vendor: 5, product: 6, serial: 7, point: CGSize(width: 3000, height: 1500))
        ]
        let result = DisplayMatcher.resolve(target: target, among: candidates)
        #expect(result?.quality == .equivalent)
        #expect(result?.display.serialNumber == 7)
    }

    @Test
    func vendorProductMatchWithoutSerialStillCounts() {
        let target = makeFingerprint(vendor: 5, product: 6, serial: nil)
        let candidates = [
            makeFingerprint(vendor: 9, product: 9),
            makeFingerprint(vendor: 5, product: 6, serial: 42)
        ]
        let result = DisplayMatcher.resolve(target: target, among: candidates)
        #expect(result?.quality == .equivalent)
    }

    @Test
    func closestPointSizeUsedWhenIdentityFails() {
        let target = makeFingerprint(point: CGSize(width: 2560, height: 1440))
        let candidates = [
            makeFingerprint(point: CGSize(width: 1920, height: 1080), primary: true),
            makeFingerprint(point: CGSize(width: 2560, height: 1600))
        ]
        let result = DisplayMatcher.resolve(target: target, among: candidates)
        #expect(result?.quality == .similar)
        #expect(result?.display.pointSize.height == 1600)
    }

    @Test
    func primaryUsedOnlyWhenNothingElseRemains() {
        // Target has zero identity AND no size overlap at all; the closest
        // heuristic still wins because it is unconditional when identity fails.
        let target = makeFingerprint(point: CGSize(width: 800, height: 600))
        let primary = makeFingerprint(point: CGSize(width: 1920, height: 1080), primary: true)
        let result = DisplayMatcher.resolve(target: target, among: [primary])
        #expect(result?.quality == .similar)
        #expect(result?.display.isPrimary == true)
    }

    @Test
    func primaryHelperPrefersPrimaryFlag() {
        let secondary = makeFingerprint(point: CGSize(width: 100, height: 100))
        let primary = makeFingerprint(point: CGSize(width: 200, height: 200), primary: true)
        #expect(DisplayMatcher.primary(among: [secondary, primary])?.isPrimary == true)
    }

    @Test
    func qualityOrderingIsMonotonic() {
        #expect(DisplayMatchQuality.exact < .equivalent)
        #expect(DisplayMatchQuality.equivalent < .similar)
        #expect(DisplayMatchQuality.similar < .primary)
    }

    @Test
    func vendorProductTieBreaksByGeometryForTwins() {
        // Twins: same vendor+product, nil serial, nil UUID, so they share one
        // fingerprint id. The array lists the non-matching twin first, so a
        // plain first(where:) would return the wrong display. The tie-break
        // must prefer the candidate whose origin and point size match target.
        let target = makeFingerprint(vendor: 5, product: 6, serial: nil, origin: CGPoint(x: 1920, y: 0))
        let twinAtZero = makeFingerprint(vendor: 5, product: 6, serial: nil, origin: .zero)
        let twinAtRight = makeFingerprint(vendor: 5, product: 6, serial: nil, origin: CGPoint(x: 1920, y: 0))
        let result = DisplayMatcher.resolve(target: target, among: [twinAtZero, twinAtRight])
        #expect(result?.quality == .equivalent)
        #expect(result?.display.globalOrigin == CGPoint(x: 1920, y: 0))
    }

    @Test
    func vendorProductWithDistinctSerialsKeepsFirstInOrder() {
        // Distinct serials -> distinct ids -> no ambiguity -> the tie-break
        // must NOT engage; behaviour stays "first vendor+product match in
        // array order", even though target geometry matches the second.
        let target = makeFingerprint(vendor: 5, product: 6, serial: nil, origin: CGPoint(x: 1920, y: 0))
        let first = makeFingerprint(vendor: 5, product: 6, serial: 1, origin: .zero)
        let second = makeFingerprint(vendor: 5, product: 6, serial: 2, origin: CGPoint(x: 1920, y: 0))
        let result = DisplayMatcher.resolve(target: target, among: [first, second])
        #expect(result?.display.serialNumber == 1)
    }
}
