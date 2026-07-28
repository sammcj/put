import CoreGraphics
import PutCore
import PutTestSupport
@testable import PutUI
import Testing

@MainActor
@Suite("RulePlacementForm.recomputeNormalised")
struct RulePlacementFormTests {
    @Test
    func derivesUnitRectFromAbsoluteAndPointSize() {
        // Dyadic sizes so the ratios are exactly representable as Double.
        let display = makeDisplayFingerprint(pointSize: CGSize(width: 1024, height: 512))
        let absolute = CGRect(x: 256, y: 128, width: 512, height: 256)

        let result = RulePlacementForm.recomputeNormalised(absolute: absolute, on: display)

        #expect(result == UnitRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
    }

    @Test
    func returnsNilForZeroWidthDisplay() {
        let display = makeDisplayFingerprint(pointSize: CGSize(width: 0, height: 1000))

        let result = RulePlacementForm.recomputeNormalised(
            absolute: CGRect(x: 0, y: 0, width: 100, height: 100),
            on: display)

        #expect(result == nil)
    }

    @Test
    func returnsNilForZeroHeightDisplay() {
        let display = makeDisplayFingerprint(pointSize: CGSize(width: 1000, height: 0))

        let result = RulePlacementForm.recomputeNormalised(
            absolute: CGRect(x: 0, y: 0, width: 100, height: 100),
            on: display)

        #expect(result == nil)
    }
}
