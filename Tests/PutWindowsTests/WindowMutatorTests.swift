import CoreGraphics
import Foundation
@testable import PutWindows
import Testing

@Suite("WindowMutator helpers")
struct WindowMutatorTests {
    // MARK: - isGrowing

    @Test
    func isGrowingReturnsFalseWithoutCurrentSize() {
        #expect(!WindowMutator.isGrowing(from: nil, to: CGSize(width: 1000, height: 800)))
    }

    @Test
    func isGrowingReturnsFalseWhenShrinking() {
        #expect(!WindowMutator.isGrowing(
            from: CGSize(width: 1000, height: 800),
            to: CGSize(width: 600, height: 500)))
    }

    @Test
    func isGrowingReturnsFalseAtSameSize() {
        #expect(!WindowMutator.isGrowing(
            from: CGSize(width: 1000, height: 800),
            to: CGSize(width: 1000, height: 800)))
    }

    @Test
    func isGrowingIgnoresSubPointWidening() {
        // 1-point threshold avoids treating float-noise as growth.
        #expect(!WindowMutator.isGrowing(
            from: CGSize(width: 1000, height: 800),
            to: CGSize(width: 1000.5, height: 800.5)))
    }

    @Test
    func isGrowingDetectsWidthGrowth() {
        #expect(WindowMutator.isGrowing(
            from: CGSize(width: 800, height: 800),
            to: CGSize(width: 1200, height: 800)))
    }

    @Test
    func isGrowingDetectsHeightGrowth() {
        #expect(WindowMutator.isGrowing(
            from: CGSize(width: 800, height: 600),
            to: CGSize(width: 800, height: 900)))
    }

    @Test
    func isGrowingDetectsEitherAxisGrowth() {
        // Width grows even if height shrinks — counts as growing because
        // we need room on the wider axis before sizing.
        #expect(WindowMutator.isGrowing(
            from: CGSize(width: 800, height: 1000),
            to: CGSize(width: 1200, height: 600)))
    }

    // MARK: - writeSequence

    @Test
    func writeSequenceGrowingEndsWithSize() {
        let steps = WindowMutator.writeSequence(growing: true)
        #expect(steps.last?.kind == .size)
    }

    @Test
    func writeSequenceShrinkingEndsWithSize() {
        let steps = WindowMutator.writeSequence(growing: false)
        #expect(steps.last?.kind == .size)
    }

    @Test
    func writeSequenceGrowingStartsWithPosition() {
        // Growing inserts a leading position write so the window has room
        // before the size attribute lands.
        let steps = WindowMutator.writeSequence(growing: true)
        #expect(steps.first?.kind == .position)
    }

    @Test
    func writeSequenceShrinkingStartsWithSize() {
        // Shrinking sets size first so the target origin is reachable on
        // smaller destination displays.
        let steps = WindowMutator.writeSequence(growing: false)
        #expect(steps.first?.kind == .size)
    }

    @Test
    func writeSequenceGrowingHasFourSteps() {
        let steps = WindowMutator.writeSequence(growing: true)
        #expect(steps.map(\.kind) == [.position, .size, .position, .size])
    }

    @Test
    func writeSequenceShrinkingHasThreeSteps() {
        let steps = WindowMutator.writeSequence(growing: false)
        #expect(steps.map(\.kind) == [.size, .position, .size])
    }

    @Test
    func writeSequenceContextLabelsAreUnique() {
        // Distinct labels matter for diagnosing which write triggered a
        // .cannotComplete retry.
        let growing = WindowMutator.writeSequence(growing: true).map(\.context)
        #expect(Set(growing).count == growing.count)
        let shrinking = WindowMutator.writeSequence(growing: false).map(\.context)
        #expect(Set(shrinking).count == shrinking.count)
    }

    // MARK: - shouldBailAfterNoProgress

    @Test
    func shouldBailReturnsFalseOnFirstAttempt() {
        // First attempt has no previous to compare against.
        #expect(!WindowMutator.shouldBailAfterNoProgress(
            attempt: 1,
            previousActual: CGRect(x: 0, y: 0, width: 800, height: 600),
            currentActual: CGRect(x: 0, y: 0, width: 800, height: 600)))
    }

    @Test
    func shouldBailReturnsFalseWithoutPrevious() {
        #expect(!WindowMutator.shouldBailAfterNoProgress(
            attempt: 2,
            previousActual: nil,
            currentActual: CGRect(x: 0, y: 0, width: 800, height: 600)))
    }

    @Test
    func shouldBailReturnsFalseWithoutCurrent() {
        #expect(!WindowMutator.shouldBailAfterNoProgress(
            attempt: 2,
            previousActual: CGRect(x: 0, y: 0, width: 800, height: 600),
            currentActual: nil))
    }

    @Test
    func shouldBailReturnsTrueWhenActualsMatchAfterRetry() {
        // App has clamped to a stable geometry — no point retrying further.
        let stuck = CGRect(x: 0, y: 0, width: 600, height: 500)
        #expect(WindowMutator.shouldBailAfterNoProgress(
            attempt: 2,
            previousActual: stuck,
            currentActual: stuck))
    }

    @Test
    func shouldBailReturnsTrueWhenActualsMatchWithinTolerance() {
        // Sub-tolerance noise still counts as "no progress".
        #expect(WindowMutator.shouldBailAfterNoProgress(
            attempt: 3,
            previousActual: CGRect(x: 100, y: 100, width: 600, height: 500),
            currentActual: CGRect(x: 100.5, y: 99.5, width: 600.5, height: 499.5)))
    }

    @Test
    func shouldBailReturnsFalseWhenActualsDiverge() {
        // Frame is still moving — keep trying.
        #expect(!WindowMutator.shouldBailAfterNoProgress(
            attempt: 2,
            previousActual: CGRect(x: 0, y: 0, width: 600, height: 500),
            currentActual: CGRect(x: 0, y: 0, width: 800, height: 500)))
    }

    // MARK: - sizeMatches

    @Test
    func sizeMatchesAcceptsExact() {
        #expect(WindowMutator.sizeMatches(
            target: CGSize(width: 800, height: 600),
            actual: CGSize(width: 800, height: 600)))
    }

    @Test
    func sizeMatchesToleratesSubPointDrift() {
        // Same 2-point tolerance as frameMatches.
        #expect(WindowMutator.sizeMatches(
            target: CGSize(width: 800, height: 600),
            actual: CGSize(width: 801, height: 599)))
    }

    @Test
    func sizeMatchesRejectsLargeDelta() {
        #expect(!WindowMutator.sizeMatches(
            target: CGSize(width: 800, height: 600),
            actual: CGSize(width: 820, height: 600)))
    }
}
