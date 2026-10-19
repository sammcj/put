import CoreGraphics
import Foundation
@testable import PutPlacement
import Testing

@Suite("LearnedMinimumSizes")
struct LearnedMinimumSizesTests {
    private let rule = UUID()

    @Test
    func shrinkThatStopsShortIsLearned() {
        var sizes = LearnedMinimumSizes()
        let learned = sizes.learn(
            ruleID: rule,
            initial: CGSize(width: 1200, height: 900),
            target: CGSize(width: 400, height: 300),
            actual: CGSize(width: 600, height: 300))
        // Height landed on target, so only width is a floor.
        #expect(learned == CGSize(width: 600, height: 0))
        #expect(sizes.minimum(for: rule) == CGSize(width: 600, height: 0))
    }

    @Test
    func ignoredWriteIsNotMistakenForMinimum() {
        // Firefox-after-wake: the write returns success but nothing changes.
        var sizes = LearnedMinimumSizes()
        let learned = sizes.learn(
            ruleID: rule,
            initial: CGSize(width: 1200, height: 900),
            target: CGSize(width: 400, height: 300),
            actual: CGSize(width: 1200, height: 900))
        #expect(learned == nil)
        #expect(sizes.minimum(for: rule) == nil)
    }

    @Test
    func unknownInitialSizeLearnsNothing() {
        var sizes = LearnedMinimumSizes()
        #expect(sizes.learn(
            ruleID: rule,
            initial: nil,
            target: CGSize(width: 400, height: 300),
            actual: CGSize(width: 600, height: 500)) == nil)
    }

    @Test
    func overshootFromGrowingIsNotAFloor() {
        // Growing past the target is the app snapping to a grid, not a minimum.
        var sizes = LearnedMinimumSizes()
        #expect(sizes.learn(
            ruleID: rule,
            initial: CGSize(width: 300, height: 200),
            target: CGSize(width: 800, height: 600),
            actual: CGSize(width: 810, height: 600)) == nil)
    }

    @Test
    func minimumOnlyRatchetsUp() {
        var sizes = LearnedMinimumSizes()
        sizes.learn(
            ruleID: rule,
            initial: CGSize(width: 1200, height: 900),
            target: CGSize(width: 400, height: 300),
            actual: CGSize(width: 600, height: 450))
        let second = sizes.learn(
            ruleID: rule,
            initial: CGSize(width: 1200, height: 900),
            target: CGSize(width: 400, height: 300),
            actual: CGSize(width: 500, height: 500))
        #expect(second == CGSize(width: 600, height: 500))
        // Repeating an observation already covered is not news.
        #expect(sizes.learn(
            ruleID: rule,
            initial: CGSize(width: 1200, height: 900),
            target: CGSize(width: 400, height: 300),
            actual: CGSize(width: 600, height: 500)) == nil)
    }

    @Test
    func applyingGrowsOnlyUndersizedAxesAndKeepsOrigin() {
        var sizes = LearnedMinimumSizes()
        sizes.learn(
            ruleID: rule,
            initial: CGSize(width: 1200, height: 900),
            target: CGSize(width: 400, height: 300),
            actual: CGSize(width: 600, height: 300))
        let frame = CGRect(x: 50, y: 70, width: 400, height: 300)
        #expect(sizes.applying(to: frame, ruleID: rule) == CGRect(x: 50, y: 70, width: 600, height: 300))
        let roomy = CGRect(x: 50, y: 70, width: 900, height: 300)
        #expect(sizes.applying(to: roomy, ruleID: rule) == roomy)
    }

    @Test
    func otherRulesAreUnaffected() {
        var sizes = LearnedMinimumSizes()
        sizes.learn(
            ruleID: rule,
            initial: CGSize(width: 1200, height: 900),
            target: CGSize(width: 400, height: 300),
            actual: CGSize(width: 600, height: 450))
        let frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        #expect(sizes.applying(to: frame, ruleID: UUID()) == frame)
    }
}
