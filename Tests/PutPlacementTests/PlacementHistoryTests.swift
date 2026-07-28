import CoreGraphics
import Foundation
@testable import PutCore
@testable import PutPlacement
import Testing

@Suite("PlacementHistory.shouldSkipReplay")
struct PlacementHistoryTests {
    private let ruleA = UUID()
    private let ruleB = UUID()
    private let target = CGRect(x: 100, y: 100, width: 800, height: 600)
    private let placedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private func record(ruleID: UUID, target: CGRect) -> PlacementHistory.Record {
        PlacementHistory.Record(ruleID: ruleID, targetFrame: target, placedAt: placedAt)
    }

    @Test
    func noRecordMeansApply() {
        #expect(!PlacementHistory.shouldSkipReplay(
            record: nil,
            currentFrame: target,
            nextRuleID: ruleA,
            nextTargetFrame: target))
    }

    @Test
    func windowStillAtTargetIsNotTreatedAsUserMoved() {
        // Window sat where we put it; an auto replay is a no-op anyway,
        // but we must not interpret "still at target" as user intent.
        #expect(!PlacementHistory.shouldSkipReplay(
            record: record(ruleID: ruleA, target: target),
            currentFrame: target,
            nextRuleID: ruleA,
            nextTargetFrame: target))
    }

    @Test
    func windowMovedFarIsSuppressed() {
        let dragged = target.offsetBy(dx: 800, dy: 0)
        #expect(PlacementHistory.shouldSkipReplay(
            record: record(ruleID: ruleA, target: target),
            currentFrame: dragged,
            nextRuleID: ruleA,
            nextTargetFrame: target))
    }

    @Test
    func windowResizedBeyondThresholdIsSuppressed() {
        // Origin unchanged, but the user grew the window from a corner that
        // kept the top-left fixed. The size delta alone must count as a
        // manual change - this is the gap that let resized windows snap back.
        let resized = CGRect(x: target.minX, y: target.minY, width: target.width + 200, height: target.height)
        #expect(PlacementHistory.shouldSkipReplay(
            record: record(ruleID: ruleA, target: target),
            currentFrame: resized,
            nextRuleID: ruleA,
            nextTargetFrame: target))
    }

    @Test
    func suppressionIsDurableRegardlessOfRecordAge() {
        // There is no time-based cooldown: a placement recorded long ago still
        // suppresses replay as long as the window remains where the user put
        // it. This is the fix for "Put snaps my window back hours later".
        let ancient = PlacementHistory.Record(
            ruleID: ruleA,
            targetFrame: target,
            placedAt: Date(timeIntervalSince1970: 0))
        let dragged = target.offsetBy(dx: 800, dy: 0)
        #expect(PlacementHistory.shouldSkipReplay(
            record: ancient,
            currentFrame: dragged,
            nextRuleID: ruleA,
            nextTargetFrame: target))
    }

    @Test
    func ruleChangeBypassesSuppression() {
        // The rule about to be applied differs from the rule that produced
        // the prior placement (e.g. user edited rules) - never suppress.
        let dragged = target.offsetBy(dx: 800, dy: 0)
        #expect(!PlacementHistory.shouldSkipReplay(
            record: record(ruleID: ruleA, target: target),
            currentFrame: dragged,
            nextRuleID: ruleB,
            nextTargetFrame: target))
    }

    @Test
    func targetChangeBypassesSuppression() {
        // Same rule, but the resolved target frame has shifted (display
        // reconfigure, layout edit). Apply the new target.
        let newTarget = target.offsetBy(dx: 1000, dy: 0)
        #expect(!PlacementHistory.shouldSkipReplay(
            record: record(ruleID: ruleA, target: target),
            currentFrame: target,
            nextRuleID: ruleA,
            nextTargetFrame: newTarget))
    }

    @Test
    func smallDriftBelowThresholdIsNotTreatedAsUserMove() {
        // Some apps "settle" a few points off where AX wrote them. Below
        // the threshold we still consider the window placed.
        let nudged = target.offsetBy(dx: 10, dy: 5)
        #expect(!PlacementHistory.shouldSkipReplay(
            record: record(ruleID: ruleA, target: target),
            currentFrame: nudged,
            nextRuleID: ruleA,
            nextTargetFrame: target))
    }

    @Test
    func smallResizeBelowThresholdIsNotTreatedAsUserResize() {
        // A handful of points of size jitter from the AX server is not a
        // deliberate resize.
        let nudged = CGRect(x: target.minX, y: target.minY, width: target.width + 8, height: target.height - 6)
        #expect(!PlacementHistory.shouldSkipReplay(
            record: record(ruleID: ruleA, target: target),
            currentFrame: nudged,
            nextRuleID: ruleA,
            nextTargetFrame: target))
    }

    @Test
    func crossDisplayRelocationBypassesSuppression() {
        // The window now sits on a *different* display than its target (macOS
        // reflowed it across monitors on a display power-cycle). That is a
        // system move, not a user drag, so the restore must put it back even
        // though the frame delta looks like a big "manual" move.
        let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let onOtherMonitor = target.offsetBy(dx: 1200, dy: 0) // centre well outside `display`
        #expect(!PlacementHistory.shouldSkipReplay(
            record: record(ruleID: ruleA, target: target),
            currentFrame: onOtherMonitor,
            nextRuleID: ruleA,
            nextTargetFrame: target,
            targetDisplayBounds: display))
    }

    @Test
    func sameDisplayMoveIsStillSuppressedWithBounds() {
        // A genuine nudge that keeps the window on its target display still
        // counts as a manual move - the cross-display escape hatch must not
        // weaken the same-screen "don't fight my nudges" behaviour.
        let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let nudgedOnSameScreen = target.offsetBy(dx: 60, dy: 60) // centre still inside `display`
        #expect(PlacementHistory.shouldSkipReplay(
            record: record(ruleID: ruleA, target: target),
            currentFrame: nudgedOnSameScreen,
            nextRuleID: ruleA,
            nextTargetFrame: target,
            targetDisplayBounds: display))
    }

    @Test
    func driftThresholdIsConfigurable() {
        // A test wanting tighter tolerance can dial the threshold down.
        let nudged = target.offsetBy(dx: 20, dy: 0)
        #expect(PlacementHistory.shouldSkipReplay(
            record: record(ruleID: ruleA, target: target),
            currentFrame: nudged,
            nextRuleID: ruleA,
            nextTargetFrame: target,
            driftThreshold: 5))
    }
}
