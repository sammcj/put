import CoreGraphics
import Foundation
import PutCore
import PutPlacement
import PutWindows

/// Per-window memory of successful placements. `ActionCoordinator` consults it
/// for `.auto` triggers so a window the user has moved or resized away from
/// where Put put it doesn't get snapped back by the next wake/launch retry.
///
/// Suppression is durable (no time limit); it resets when the rule's resolved
/// target changes, when an `.explicit` caller (hotkey, menu) re-applies, or
/// when the window closes (pruned on the next full snapshot). The pure decision
/// rule lives in `PlacementHistory` (PutPlacement); this type owns the live
/// cache and the `WindowIdentity` keying.
@MainActor
final class PlacementHistoryStore {
    /// Readable (not writable) outside the type so tests can assert the cache
    /// stays bounded without reaching through a bespoke test-only accessor.
    private(set) var records: [WindowIdentity: PlacementHistory.Record] = [:]

    /// Hard ceiling on retained records. `prune(keeping:)` is the primary bound,
    /// but it only runs on a full-snapshot restore: a user whose only enabled
    /// trigger is `onAppLaunch` never takes that path, so records for windows
    /// that have since closed would accumulate for the whole process lifetime,
    /// each key retaining a dead `AXUIElement`. Set well above any realistic
    /// live-window count, so eviction only bites long after pruning should have
    /// happened and costs at most the manual-move suppression for the least
    /// recently placed window.
    static let maxRecords = 512

    /// Drop placement records for windows that are no longer live, keeping the
    /// cache bounded without a time horizon (suppression is durable, so records
    /// can't expire by age). `liveIdentities` must come from a full window
    /// snapshot, otherwise records for windows merely absent from a partial
    /// probe would be discarded.
    func prune(keeping liveIdentities: Set<WindowIdentity>) {
        records = records.filter { liveIdentities.contains($0.key) }
    }

    /// Record where a window was just put (or drift-attempted), as the baseline
    /// the moved-by-user check compares against. Called on both clean and
    /// drifted position writes so suppression works even for apps that never
    /// land exactly on target.
    func record(handle: WindowHandle, rule: Rule, frame: CGRect) {
        records[handle.identity] = PlacementHistory.Record(
            ruleID: rule.id,
            targetFrame: frame,
            placedAt: Date())
        evictOldestIfOverCapacity()
    }

    /// Drop the least recently placed records once the cache exceeds
    /// `maxRecords`. The sort only runs on the rare over-capacity insert, so the
    /// common path stays a single dictionary write.
    private func evictOldestIfOverCapacity() {
        guard records.count > Self.maxRecords else { return }
        let excess = records.count - Self.maxRecords
        let oldest = records
            .sorted { $0.value.placedAt < $1.value.placedAt }
            .prefix(excess)
            .map(\.key)
        for identity in oldest {
            records.removeValue(forKey: identity)
        }
    }

    /// Whether an `.auto` replay of `rule` should be suppressed because the user
    /// moved or resized the window away from where Put last placed it. Only
    /// `.sizeAndPosition` rules suppress, because only they write a full target
    /// frame for the moved-by-user check to compare against. Size-only rules are
    /// a deliberate "force this size" choice; display-only rules recompute their
    /// target from the window's current frame, so a window already on the right
    /// display resolves to a no-op and needs no suppression. The caller gates
    /// this on `autoTriggers.respectManualMoves`, so it isn't a parameter here.
    func shouldSuppressAutoReplay(
        rule: Rule,
        handle: WindowHandle,
        targetFrame: CGRect,
        targetDisplay: DisplayFingerprint,
        source: RestoreSource) -> Bool
    {
        guard source == .auto, rule.restoreScope == .sizeAndPosition else {
            return false
        }
        return PlacementHistory.shouldSkipReplay(
            record: records[handle.identity],
            currentFrame: handle.descriptor.frame,
            nextRuleID: rule.id,
            nextTargetFrame: targetFrame,
            targetDisplayBounds: CGRect(origin: targetDisplay.globalOrigin, size: targetDisplay.pointSize))
    }
}
