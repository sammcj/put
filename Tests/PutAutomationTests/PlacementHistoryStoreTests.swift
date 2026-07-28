import CoreGraphics
import Foundation
@testable import PutAutomation
@testable import PutCore
import PutTestSupport
@testable import PutWindows
import Testing

@MainActor
@Suite("PlacementHistoryStore")
struct PlacementHistoryStoreTests {
    /// A display whose global-AX bounds are large enough to contain every frame
    /// these tests place, so the cross-display reflow guard passes unless a test
    /// deliberately moves a window off it.
    private func wideDisplay() -> DisplayFingerprint {
        makeDisplayFingerprint(
            pointSize: CGSize(width: 3000, height: 3000),
            globalOrigin: .zero)
    }

    private func makeRule(restoresPosition: Bool = true) -> Rule {
        Rule(
            matchCriteria: MatchCriteria(bundleID: "com.example.one"),
            targetDisplay: wideDisplay(),
            frame: WindowFrame(
                absolute: CGRect(x: 0, y: 0, width: 100, height: 100),
                normalised: UnitRect(x: 0, y: 0, width: 0.1, height: 0.1)),
            restoresPosition: restoresPosition)
    }

    private func handle(at frame: CGRect) -> WindowHandle {
        makeWindowHandle(bundleID: "com.example.one", frame: frame)
    }

    private let target = CGRect(x: 100, y: 100, width: 600, height: 400)
    private let movedAway = CGRect(x: 500, y: 500, width: 600, height: 400)

    @Test
    func noRecordDoesNotSuppress() {
        let store = PlacementHistoryStore()
        let rule = makeRule()
        let suppressed = store.shouldSuppressAutoReplay(
            rule: rule,
            handle: handle(at: movedAway),
            targetFrame: target,
            targetDisplay: wideDisplay(),
            source: .auto)
        #expect(suppressed == false)
    }

    @Test
    func autoReplaySuppressedAfterUserMovesWindow() {
        let store = PlacementHistoryStore()
        let rule = makeRule()
        // Recorded at `target`, but the window now sits well beyond the drift
        // threshold: the user moved it, so an auto replay must be suppressed.
        let window = handle(at: movedAway)
        store.record(handle: window, rule: rule, frame: target)

        let suppressed = store.shouldSuppressAutoReplay(
            rule: rule,
            handle: window,
            targetFrame: target,
            targetDisplay: wideDisplay(),
            source: .auto)
        #expect(suppressed)
    }

    @Test
    func windowStillOnTargetIsNotSuppressed() {
        let store = PlacementHistoryStore()
        let rule = makeRule()
        // A few points of drift is below the threshold, so this is not a move.
        let window = handle(at: CGRect(x: 110, y: 108, width: 600, height: 400))
        store.record(handle: window, rule: rule, frame: target)

        let suppressed = store.shouldSuppressAutoReplay(
            rule: rule,
            handle: window,
            targetFrame: target,
            targetDisplay: wideDisplay(),
            source: .auto)
        #expect(suppressed == false)
    }

    @Test
    func explicitSourceNeverSuppresses() {
        let store = PlacementHistoryStore()
        let rule = makeRule()
        let window = handle(at: movedAway)
        store.record(handle: window, rule: rule, frame: target)

        let suppressed = store.shouldSuppressAutoReplay(
            rule: rule,
            handle: window,
            targetFrame: target,
            targetDisplay: wideDisplay(),
            source: .explicit)
        #expect(suppressed == false)
    }

    @Test
    func sizeOnlyRuleNeverSuppresses() {
        let store = PlacementHistoryStore()
        let rule = makeRule(restoresPosition: false)
        let window = handle(at: movedAway)
        store.record(handle: window, rule: rule, frame: target)

        let suppressed = store.shouldSuppressAutoReplay(
            rule: rule,
            handle: window,
            targetFrame: target,
            targetDisplay: wideDisplay(),
            source: .auto)
        #expect(suppressed == false)
    }

    @Test
    func differentRuleDoesNotSuppress() {
        let store = PlacementHistoryStore()
        let recordedRule = makeRule()
        let otherRule = makeRule()
        let window = handle(at: movedAway)
        store.record(handle: window, rule: recordedRule, frame: target)

        // A different rule now resolves onto the same window: the recorded
        // baseline belongs to another rule, so suppression must not apply.
        let suppressed = store.shouldSuppressAutoReplay(
            rule: otherRule,
            handle: window,
            targetFrame: target,
            targetDisplay: wideDisplay(),
            source: .auto)
        #expect(suppressed == false)
    }

    @Test
    func shiftedTargetLetsWriteThrough() {
        let store = PlacementHistoryStore()
        let rule = makeRule()
        let window = handle(at: movedAway)
        store.record(handle: window, rule: rule, frame: target)

        // The resolved target moved (layout edit / display change), so the
        // record's target no longer matches and the write is allowed.
        let shiftedTarget = CGRect(x: 900, y: 900, width: 600, height: 400)
        let suppressed = store.shouldSuppressAutoReplay(
            rule: rule,
            handle: window,
            targetFrame: shiftedTarget,
            targetDisplay: wideDisplay(),
            source: .auto)
        #expect(suppressed == false)
    }

    @Test
    func windowReflowedOntoAnotherDisplayIsNotSuppressed() {
        let store = PlacementHistoryStore()
        let rule = makeRule()
        // The window is far from target (looks moved) but its centre now sits
        // outside the target display: a system reflow, not a user move.
        let window = handle(at: CGRect(x: 2500, y: 2500, width: 600, height: 400))
        store.record(handle: window, rule: rule, frame: target)

        let smallDisplay = makeDisplayFingerprint(
            pointSize: CGSize(width: 1000, height: 1000),
            globalOrigin: .zero)
        let suppressed = store.shouldSuppressAutoReplay(
            rule: rule,
            handle: window,
            targetFrame: target,
            targetDisplay: smallDisplay,
            source: .auto)
        #expect(suppressed == false)
    }

    @Test
    func pruneDropsRecordsForClosedWindows() {
        let store = PlacementHistoryStore()
        let rule = makeRule()
        let window = handle(at: movedAway)
        store.record(handle: window, rule: rule, frame: target)

        // Keeping the live identity retains suppression.
        store.prune(keeping: [window.identity])
        #expect(store.shouldSuppressAutoReplay(
            rule: rule,
            handle: window,
            targetFrame: target,
            targetDisplay: wideDisplay(),
            source: .auto))

        // Pruning against a snapshot that no longer contains the window drops
        // its record, so nothing is suppressed afterwards.
        store.prune(keeping: [])
        #expect(store.shouldSuppressAutoReplay(
            rule: rule,
            handle: window,
            targetFrame: target,
            targetDisplay: wideDisplay(),
            source: .auto) == false)
    }

    /// `prune` only runs on a full-snapshot restore, which an onAppLaunch-only
    /// user never triggers, so `record` must bound the cache by itself.
    @Test
    func recordEvictsOldestOnceOverCapacity() {
        let store = PlacementHistoryStore()
        let rule = makeRule()
        let overflow = 10

        // Distinct pids give distinct AX elements, hence distinct identities.
        for index in 0..<(PlacementHistoryStore.maxRecords + overflow) {
            let window = makeWindowHandle(
                bundleID: "com.example.one",
                frame: target,
                processID: pid_t(10000 + index))
            store.record(handle: window, rule: rule, frame: target)
        }

        #expect(store.records.count == PlacementHistoryStore.maxRecords)
    }

    @Test
    func recordBelowCapacityKeepsEveryRecord() {
        let store = PlacementHistoryStore()
        let rule = makeRule()
        let count = 25

        for index in 0..<count {
            let window = makeWindowHandle(
                bundleID: "com.example.one",
                frame: target,
                processID: pid_t(20000 + index))
            store.record(handle: window, rule: rule, frame: target)
        }

        #expect(store.records.count == count)
    }
}
