import AppKit
import CoreGraphics
import Foundation
import OSLog
import PutCore
import PutPlacement
import PutWindows

// Detection and one-click recovery of windows stranded on a non-active Space.
//
// macOS reflows windows across displays and collapses Spaces during sleep/wake.
// A window exiled to a non-active Space is invisible to the Accessibility API,
// so a normal restore pass never sees it (no drift, no error - it's simply
// absent). Cross-Space window moves need SIP disabled, which Put won't require,
// so recovery is a user-initiated action: activate the app to surface the
// window onto a reachable Space, then re-place it.

public extension ActionCoordinator {
    /// Re-derive which managed windows are stranded on a non-active Space and
    /// publish them to `AppState`. Called after every full restore. Depends
    /// only on the current pass (no cross-pass state), so a stranded window
    /// stays flagged on every retry until it's recovered or returns - and a
    /// window that returns clears itself the next pass.
    func refreshUnreachableWindows(snapshot handles: [WindowHandle]) {
        guard let layout = state.activeLayout else {
            state.unreachableWindows = []
            return
        }
        // Apps with a standard window on *some* Space but none on the current
        // one: the window exists, just not here. Subtracting the snapshot's
        // bundles is what tells an exiled window apart from a closed one.
        let onCurrentSpace = Set(handles.map(\.descriptor.bundleID))
        let offSpaceBundleIDs = probe.bundleIDsWithStandardWindows().subtracting(onCurrentSpace)
        state.unreachableWindows = Self.unreachableRules(
            in: layout,
            snapshot: handles,
            runningBundleIDs: Self.runningRegularBundleIDs(),
            offSpaceBundleIDs: offSpaceBundleIDs)
    }

    /// Pure detection, factored out for testing. An enabled rule that moves its
    /// window (so not a size-only rule, which has no opinion about where the
    /// window lives) whose app is running and has a window on another Space (in
    /// `offSpaceBundleIDs`) but none matching here. Deduplicated by bundle ID
    /// so an app with several rules surfaces a single recover entry.
    static func unreachableRules(
        in layout: Layout,
        snapshot handles: [WindowHandle],
        runningBundleIDs: Set<String>,
        offSpaceBundleIDs: Set<String>) -> [UnreachableWindow]
    {
        var seenBundles: Set<String> = []
        var result: [UnreachableWindow] = []
        for rule in layout.rules {
            guard rule.isEnabled, rule.restoreScope.restoresPosition else { continue }
            let bundleID = rule.matchCriteria.bundleID
            guard runningBundleIDs.contains(bundleID) else { continue }
            // The window exists elsewhere (not closed) and isn't reachable here.
            guard offSpaceBundleIDs.contains(bundleID) else { continue }
            let reachable = handles.contains { RuleMatcher.matches(rule, against: $0.descriptor) }
            guard !reachable else { continue }
            guard seenBundles.insert(bundleID).inserted else { continue }
            result.append(UnreachableWindow(
                ruleID: rule.id,
                label: unreachableLabel(for: rule),
                displayName: rule.targetDisplay.localizedName))
        }
        return result
    }

    private static func unreachableLabel(for rule: Rule) -> String {
        let trimmed = rule.descriptiveLabel.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? rule.matchCriteria.bundleID : trimmed
    }

    /// Running, non-hidden regular apps. Hidden apps (Cmd-H) also vanish from
    /// the AX snapshot, so excluding them keeps a hidden window from reading as
    /// stranded on another Space.
    private static func runningRegularBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isHidden }
            .compactMap(\.bundleIdentifier))
    }

    /// Bring a window stranded on another Space back to its saved spot.
    /// Activating the app surfaces the window onto a reachable Space (macOS
    /// either switches to the Space holding it or pulls it onto the active
    /// one), after which an explicit restore re-places it (suppression
    /// bypassed). The entry is cleared optimistically; the next full restore
    /// re-detects it if the window is still stranded.
    func recoverUnreachable(ruleID: UUID) async {
        guard gate.isTrusted else {
            log.warning("Accessibility not granted; recoverUnreachable aborted")
            return
        }
        defer { state.unreachableWindows.removeAll { $0.ruleID == ruleID } }
        guard let rule = state.activeLayout?.rules.first(where: { $0.id == ruleID }) else { return }
        let bundleID = rule.matchCriteria.bundleID
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first
        else {
            log.info("recoverUnreachable: \(bundleID, privacy: .public) no longer running")
            return
        }
        app.activate()
        try? await Task.sleep(for: .seconds(RestoreTiming.spaceSwitchSettle))
        let probe = probe
        let handles = await Task.detached(priority: .userInitiated) {
            probe.windows(forBundleID: bundleID)
        }.value
        let outcome = await restore(windowsForUI: handles, source: .explicit)
        log.info(
            "recoverUnreachable for \(bundleID, privacy: .public): \(String(describing: outcome), privacy: .public)")
    }
}
