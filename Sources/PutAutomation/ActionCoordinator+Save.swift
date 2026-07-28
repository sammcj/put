import CoreGraphics
import Foundation
import PutCore
import PutPlacement
import PutWindows

extension ActionCoordinator {
    /// `restoresPosition`: `nil` preserves existing behaviour (new rules
    /// default to restoring position; matched existing rules keep their
    /// current setting). A non-nil value is an explicit user choice - e.g. a
    /// "Save Size Only" action passes `false` - and is applied to both newly
    /// created rules and any matched existing rule. The window's origin is
    /// still captured in `frame.absolute` either way, so position restore can
    /// be re-enabled later without resaving.
    func save(windows: [WindowHandle], applyToAll: Bool, restoresPosition: Bool? = nil) async {
        // Never capture Put's own windows. The Rules tab "+" makes Put
        // frontmost, so a focused-window save would otherwise create a
        // self-rule for the Settings window that "Restore All" then applies
        // back to Put itself.
        let windows = windows.filter { $0.descriptor.bundleID != Bundle.main.bundleIdentifier }
        guard !windows.isEmpty else { return }

        let displays = probeDisplays()
        guard !displays.isEmpty else {
            log.warning("No displays available; save aborted")
            return
        }

        guard var activeLayout = state.activeLayout else {
            log.warning("No active layout; save aborted")
            return
        }

        let outcome = buildRules(
            for: windows,
            applyToAll: applyToAll,
            restoresPosition: restoresPosition,
            displays: displays,
            into: &activeLayout)

        state.replaceActiveLayout(activeLayout)
        await finishSave(outcome: outcome, layoutName: activeLayout.name)
    }

    /// Turn each eligible window into a created-or-updated rule on `activeLayout`
    /// and tally what happened. Skips minimised or zero-sized windows, and
    /// collects windows targeting a display this layout doesn't cover into
    /// `outOfScope` for a single notice instead of dropping them silently.
    private func buildRules(
        for windows: [WindowHandle],
        applyToAll: Bool,
        restoresPosition: Bool?,
        displays: [DisplayFingerprint],
        into activeLayout: inout PutCore.Layout) -> SaveOutcome
    {
        var outcome = SaveOutcome()
        for handle in windows {
            let descriptor = handle.descriptor
            guard !descriptor.isMinimised else { continue }
            guard descriptor.frame.width > 0, descriptor.frame.height > 0 else { continue }

            let criteria = RuleFactory.criteria(for: descriptor, applyToAll: applyToAll)
            guard let newRule = PlacementEngine.buildRule(
                matchCriteria: criteria,
                descriptiveLabel: RuleFactory.defaultLabel(for: descriptor, applyToAll: criteria.applyToAllWindows),
                globalFrame: descriptor.frame,
                displays: displays,
                defaultMissingDisplayPolicy: state.config.defaultMissingDisplayPolicy,
                restoresPosition: restoresPosition ?? true)
            else {
                continue
            }

            // Don't stamp a rule for a window on a monitor this layout isn't
            // meant to cover. Otherwise saving while docked into a laptop-only
            // layout writes a rule targeting the external display, which then
            // can't restore (and fights the user) once undocked.
            guard activeLayout.coversDisplay(newRule.targetDisplay.id) else {
                outcome.outOfScope.append(OutOfScopeSave(
                    appLabel: newRule.descriptiveLabel,
                    displayName: newRule.targetDisplay.localizedName ?? newRule.targetDisplay.id))
                continue
            }

            upsert(
                newRule,
                criteria: criteria,
                restoresPosition: restoresPosition,
                into: &activeLayout,
                outcome: &outcome)
            outcome.flashedRects.append(descriptor.frame)
        }
        return outcome
    }

    /// Replace a matching existing rule in place (preserving its position-restore
    /// choice unless `restoresPosition` is an explicit override) or append the
    /// new rule, updating the created/updated tally.
    private func upsert(
        _ newRule: Rule,
        criteria: MatchCriteria,
        restoresPosition: Bool?,
        into activeLayout: inout PutCore.Layout,
        outcome: inout SaveOutcome)
    {
        if let index = activeLayout.rules
            .firstIndex(where: { $0.matchCriteria.identityKey == criteria.identityKey })
        {
            var existing = activeLayout.rules[index]
            existing.targetDisplay = newRule.targetDisplay
            existing.frame = newRule.frame
            // nil preserves the existing rule's choice; an explicit value
            // (e.g. a Save Size Only action) overrides it.
            existing.restoresPosition = restoresPosition ?? existing.restoresPosition
            activeLayout.rules[index] = existing
            outcome.updatedCount += 1
        } else {
            activeLayout.rules.append(newRule)
            outcome.createdCount += 1
        }
    }

    /// Persist, flash the saved frames, emit any out-of-scope notice, and log
    /// the created/updated summary. The layout is already committed to `state`
    /// by the caller before this runs.
    private func finishSave(outcome: SaveOutcome, layoutName: String) async {
        await persistConfig(reason: "save")
        if !outcome.flashedRects.isEmpty {
            saveFlash.flash(rects: outcome.flashedRects)
        }
        if !outcome.outOfScope.isEmpty {
            await notifyOutOfScope(outcome.outOfScope, layoutName: layoutName)
        }
        log.info(
            """
            Saved windows: created=\(outcome.createdCount, privacy: .public), \
            updated=\(outcome.updatedCount, privacy: .public)
            """)
        await fileLog.append(
            level: .info,
            category: "actions",
            message: "Saved windows",
            metadata: ["created": "\(outcome.createdCount)", "updated": "\(outcome.updatedCount)"])
    }

    /// Surface the windows skipped as out of the active layout's display scope,
    /// both as a user-facing notice and a structured log entry.
    private func notifyOutOfScope(_ skipped: [OutOfScopeSave], layoutName: String) async {
        saveScopeNotice.warnOutOfScopeSaves(layoutName: layoutName, skipped: skipped)
        let skippedSummary = skipped.map { "\($0.appLabel)@\($0.displayName)" }.sorted().joined(separator: ",")
        log.warning(
            """
            Save skipped \(skipped.count, privacy: .public) out-of-scope window(s) \
            for layout \(layoutName, privacy: .public): [\(skippedSummary, privacy: .public)]
            """)
        await fileLog.append(
            level: .warn,
            category: "actions",
            message: "Save skipped out-of-scope windows",
            metadata: ["layout": layoutName, "skipped": skippedSummary, "count": "\(skipped.count)"])
    }
}

/// Running totals for one `save` pass: how many rules were created versus
/// updated, the frames to flash on success, and any windows skipped for being
/// outside the active layout's display scope.
private struct SaveOutcome {
    var updatedCount = 0
    var createdCount = 0
    var flashedRects: [CGRect] = []
    var outOfScope: [OutOfScopeSave] = []
}
