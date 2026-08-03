import AppKit
import CoreGraphics
import Foundation
import OSLog
import PutCore
import PutDisplay
import PutPlacement
import PutStorage
import PutWindows

/// High-level orchestrator for save and restore operations. Composes
/// `WindowProbe`, `PlacementEngine`, `WindowMutator`, and `ConfigStore` into
/// the four primary user-facing actions.
@MainActor
public final class ActionCoordinator {
    public let state: AppState
    private let store: ConfigStore
    // Internal (not private) so the same-module ActionCoordinator+Unreachable
    // and ActionCoordinator+Save extensions can reach them; private is
    // file-scoped and would hide them from a sibling-file extension.
    let log: Logger = PutLog.logger(category: "actions")
    let fileLog: FileLog
    let probe: any WindowProbing
    private let mutator: any WindowMutating
    let gate: any AccessibilityGateProviding
    let saveFlash: any SaveFlashing
    let saveScopeNotice: any SaveScopeNotifying
    /// Which app the user was in before a Put window took focus. Consulted by
    /// the focused-window capture path so the Rules tab "+" targets that app,
    /// not Put's own Settings window. Nil in tests that don't wire it.
    let activationHistory: ActivationHistory?

    /// Serialises overlapping restore calls. Wake, app-launch, and
    /// display-change triggers can all fire within a second; without this
    /// guard their `await` points let them interleave and produce
    /// contradictory `setFrame` calls plus duplicate log lines.
    private var isRestoring = false

    /// Per-window memory of successful placements. Consulted by
    /// `applyPlacement` for `.auto` triggers so a window the user has moved or
    /// resized away from where Put put it doesn't get snapped back by the next
    /// wake/launch retry. See `PlacementHistoryStore` for the cache and
    /// `PlacementHistory` for the decision rule.
    let history = PlacementHistoryStore()

    public init(
        state: AppState,
        store: ConfigStore,
        fileLog: FileLog = FileLog(),
        probe: any WindowProbing = DefaultWindowProbe(),
        mutator: any WindowMutating = DefaultWindowMutator(),
        gate: any AccessibilityGateProviding = DefaultAccessibilityGate(),
        activationHistory: ActivationHistory? = nil,
        saveFlash: any SaveFlashing = NoopSaveFlashing(),
        saveScopeNotice: any SaveScopeNotifying = NoopSaveScopeNotifying())
    {
        self.state = state
        self.store = store
        self.fileLog = fileLog
        self.probe = probe
        self.mutator = mutator
        self.gate = gate
        self.activationHistory = activationHistory
        self.saveFlash = saveFlash
        self.saveScopeNotice = saveScopeNotice
    }

    // MARK: - Public actions

    /// Save the currently focused window as a rule that applies to every
    /// window of that app (bundle-wide, title-agnostic). Bound to the
    /// default Shift+F5 hotkey.
    public func saveFocusedWindowAllApp(restoreComponents: RestoreComponents? = nil) async {
        guard gate.isTrusted else {
            log.warning("Accessibility not granted; saveFocusedWindowAllApp aborted")
            return
        }
        guard let handle = await resolveFocusedWindow(action: "saveFocusedWindowAllApp") else { return }
        await save(windows: [handle], applyToAll: true, restoreComponents: restoreComponents)
    }

    /// Save the currently focused window as a rule that matches only windows
    /// with the same title. Opt-in hotkey (no default binding).
    public func saveFocusedWindowTitleOnly(restoreComponents: RestoreComponents? = nil) async {
        guard gate.isTrusted else {
            log.warning("Accessibility not granted; saveFocusedWindowTitleOnly aborted")
            return
        }
        guard let handle = await resolveFocusedWindow(action: "saveFocusedWindowTitleOnly") else { return }
        await save(windows: [handle], applyToAll: false, restoreComponents: restoreComponents)
    }

    public func restoreActiveWindow() async {
        guard gate.isTrusted else {
            log.warning("Accessibility not granted; restoreActiveWindow aborted")
            return
        }
        guard beginRestore(reason: "restoreActiveWindow") else { return }
        defer { endRestore() }
        guard let handle = await resolveFocusedWindow(action: "restoreActiveWindow") else { return }
        _ = await restore(windows: [handle], source: .explicit)
    }

    public func saveAllWindows(restoreComponents: RestoreComponents? = nil) async {
        guard gate.isTrusted else {
            log.warning("Accessibility not granted; saveAllWindows aborted")
            return
        }
        let probe = probe
        let handles = await Task.detached(priority: .userInitiated, operation: {
            probe.snapshot()
        }).value
        await save(windows: handles, applyToAll: false, restoreComponents: restoreComponents)
    }

    /// `source` has no default: `.explicitAll` and `.explicit` consult different
    /// per-rule trigger flags, and which one a caller means is never obvious
    /// from the call site.
    @discardableResult
    public func restoreAllWindows(source: RestoreSource) async -> RestoreResult? {
        guard gate.isTrusted else {
            log.warning("Accessibility not granted; restoreAllWindows aborted")
            return nil
        }
        guard beginRestore(reason: "restoreAllWindows") else { return nil }
        defer { endRestore() }
        let probe = probe
        let handles = await Task.detached(priority: .userInitiated, operation: {
            probe.snapshot()
        }).value
        // A full snapshot enumerates every live window, so it's the safe point
        // to drop placement records for windows that have since closed. The
        // per-app launch path sees only one app's windows and must not prune.
        history.prune(keeping: Set(handles.map(\.identity)))
        let tally = await restore(windows: handles, source: source)
        refreshUnreachableWindows(snapshot: handles)
        return RestoreResult(
            applied: tally.applied,
            errors: tally.errors,
            drifted: tally.drifted,
            queued: tally.queued.count,
            proportional: tally.proportional,
            erroredBundles: tally.erroredBundles,
            unmatchedBundles: tally.unmatchedBundles)
    }

    /// Save a specific set of windows. Used by the menu bar "Save All Windows
    /// for <App>" action. Each window becomes its own title-specific rule so
    /// the exact arrangement is captured.
    public func save(windowsForUI handles: [WindowHandle], restoreComponents: RestoreComponents? = nil) async {
        guard gate.isTrusted else {
            log.warning("Accessibility not granted; per-app save aborted")
            return
        }
        await save(windows: handles, applyToAll: false, restoreComponents: restoreComponents)
    }

    /// Append a copy of an existing rule with a new UUID and a "(copy)"
    /// suffix on the descriptive label.
    public func duplicateRule(id: UUID) async {
        guard var activeLayout = state.activeLayout else { return }
        guard let existing = activeLayout.rules.first(where: { $0.id == id }) else { return }
        var copy = existing
        copy.id = UUID()
        copy.descriptiveLabel = existing.descriptiveLabel.isEmpty
            ? "(copy)"
            : "\(existing.descriptiveLabel) (copy)"
        activeLayout.rules.append(copy)
        state.replaceActiveLayout(activeLayout)
        await persistConfig(reason: "duplicate")
    }

    // MARK: - Internal helpers

    fileprivate struct RestoreTally {
        var applied = 0
        var skipped = 0
        var queued: Set<UUID> = []
        var errors = 0
        var drifted = 0
        var unmatched = 0
        var unmatchedBundles: Set<String> = []
        var erroredBundles: Set<String> = []
        /// Windows placed via the proportional fallback (the resolved display's
        /// geometry differed from the rule's saved target, or no identity match
        /// existed). Counts both successful and drifted writes: either way the
        /// frame is a guess that should be re-checked once displays settle.
        var proportional = 0
    }

    public struct RestoreResult: Sendable {
        public let applied: Int
        public let errors: Int
        public let drifted: Int
        public let queued: Int
        /// Number of windows placed proportionally rather than from saved
        /// absolute coordinates. A non-zero count after a wake restore usually
        /// means a panel hadn't settled into its real resolution yet; the
        /// wake-retry uses it to schedule a corrective pass.
        public let proportional: Int
        /// Bundle IDs whose AX write errored this pass. The wake-retry tracks
        /// these so it keeps retrying a managed app until it stops erroring -
        /// and isn't fooled when the same app flips from errored to unmatched
        /// (a transiently-absent display can make a managed window read as
        /// having no rule on the next pass).
        public let erroredBundles: Set<String>
        /// Bundle IDs of live windows that matched no enabled rule this pass.
        /// Always non-empty in normal use (every ruleless app lands here), so
        /// it is only consulted against a known set of previously-errored
        /// bundles, never used as a standalone retry trigger.
        public let unmatchedBundles: Set<String>
    }

    private func restore(windows: [WindowHandle], source: RestoreSource) async -> RestoreTally {
        var tally = RestoreTally()
        guard !windows.isEmpty else { return tally }
        let displays = probeDisplays()
        guard !displays.isEmpty else {
            log.warning("No displays available; restore aborted")
            return tally
        }

        guard let activeLayout = state.activeLayout else { return tally }

        for handle in windows {
            let descriptor = handle.descriptor
            switch RuleSelection.resolve(for: descriptor, in: activeLayout.rules, source: source) {
            case .unmatched:
                tally.unmatched += 1
                tally.unmatchedBundles.insert(descriptor.bundleID)
            case let .optedOut(rule):
                tally.skipped += 1
                log.debug(
                    """
                    Rule \(rule.id.uuidString, privacy: .public) opted out of this trigger \
                    for \(descriptor.bundleID, privacy: .public)
                    """)
            case let .apply(rule):
                await applyPlacement(
                    rule: rule,
                    handle: handle,
                    displays: displays,
                    source: source,
                    tally: &tally)
            }
        }

        state.queuedRuleIDs.formUnion(tally.queued)
        await logRestoreSummary(tally)
        return tally
    }

    private func logRestoreSummary(_ tally: RestoreTally) async {
        let unmatchedSummary = tally.unmatchedBundles.sorted().joined(separator: ",")
        let erroredSummary = tally.erroredBundles.sorted().joined(separator: ",")
        log.info(
            """
            Restore summary: applied=\(tally.applied, privacy: .public) \
            skipped=\(tally.skipped, privacy: .public) \
            queued=\(tally.queued.count, privacy: .public) \
            errors=\(tally.errors, privacy: .public) \
            drifted=\(tally.drifted, privacy: .public) \
            unmatched=\(tally.unmatched, privacy: .public) \
            unmatchedBundles=[\(unmatchedSummary, privacy: .public)] \
            erroredBundles=[\(erroredSummary, privacy: .public)]
            """)
        await fileLog.append(
            level: .info,
            category: "actions",
            message: "Restore summary",
            metadata: [
                "applied": "\(tally.applied)",
                "skipped": "\(tally.skipped)",
                "queued": "\(tally.queued.count)",
                "errors": "\(tally.errors)",
                "drifted": "\(tally.drifted)",
                "unmatched": "\(tally.unmatched)",
                "unmatchedBundles": unmatchedSummary,
                "erroredBundles": erroredSummary
            ])
    }

    /// Persist the current config, converting any failure into a user-visible
    /// banner + structured log entry. Replaces the old silent `try?` sites.
    func persistConfig(reason: String) async {
        do {
            try await store.save(state.config)
            if state.lastSaveError != nil {
                state.lastSaveError = nil
            }
        } catch {
            let message = error.localizedDescription
            state.lastSaveError = "Put couldn't save your rules (\(reason)): \(message)"
            log.error("Config save failed (\(reason, privacy: .public)): \(message, privacy: .public)")
            await fileLog.append(
                level: .error,
                category: "storage",
                message: "Config save failed",
                metadata: ["reason": reason, "error": message])
        }
    }

    private func beginRestore(reason: String) -> Bool {
        if isRestoring {
            log.info("Restore already in flight; dropping trigger from \(reason, privacy: .public)")
            return false
        }
        isRestoring = true
        return true
    }

    private func endRestore() {
        isRestoring = false
    }

    /// Snapshot the connected displays on the main actor. `DisplayProbe` reads
    /// `NSScreen`, which is main-thread state, so it is `@MainActor` and must
    /// not be probed from a detached task (the C10 defect: a missed lookup
    /// during reconfiguration defeated `sameGeometry` and forced proportional
    /// remapping). The AX window probe stays detached; only display reads move
    /// back on-main.
    func probeDisplays() -> [DisplayFingerprint] {
        do {
            return try DisplayProbe.snapshot()
        } catch {
            log.error("DisplayProbe failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}

// MARK: - Focused-window capture

extension ActionCoordinator {
    /// The window a focused-window action should target. When a Put window is
    /// frontmost - the Rules tab "+"/Cmd-N path makes Settings key - the user's
    /// real target is whichever app they were in beforehand, tracked by
    /// `ActivationHistory`. Otherwise it is the live frontmost window (unchanged
    /// behaviour). Returns nil, after surfacing a "focus a window" notice, when
    /// Put is frontmost but no prior app has been recorded.
    ///
    /// The AX read blocks on XPC, so it runs in a detached task exactly like the
    /// other probe calls.
    func resolveFocusedWindow(action: String) async -> WindowHandle? {
        let probe = probe
        guard Self.isPutFrontmost() else {
            return await Task.detached(priority: .userInitiated) { probe.focusedWindow() }.value
        }
        guard let prior = activationHistory?.previousActiveApp else {
            log.info("\(action, privacy: .public): Put frontmost with no prior app; prompting user to focus a window")
            state.lastSaveError = Self.focusTargetPrompt
            return nil
        }
        let pid = prior.processID
        let bundleID = prior.bundleID
        let handle = await Task.detached(priority: .userInitiated) {
            probe.focusedWindow(pid: pid, bundleID: bundleID)
        }.value
        if handle == nil {
            log.info("\(action, privacy: .public): no focused window for prior app \(bundleID, privacy: .public)")
            // Mirror the no-prior-app branch: a silent no-op reads as a broken
            // button, so tell the user to focus the window and retry.
            state.lastSaveError = Self.focusTargetPrompt
        }
        return handle
    }

    /// Whether one of Put's own windows (Settings, About, onboarding) is
    /// frontmost. True exactly when a focused-window action was invoked from
    /// Put's UI rather than a global hotkey pressed while another app was active.
    static func isPutFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    /// Shown via `lastSaveError` when the capture can't tell which window the
    /// user meant. Phrased to fit both the save and restore entry points.
    static var focusTargetPrompt: String {
        "Put couldn't tell which window you meant. Click the window you want to use, then try again."
    }
}

// MARK: - Navigation (jump to window)

public extension ActionCoordinator {
    /// Bring the first live window matching `ruleID` in the active layout to the
    /// front, switching Spaces to follow it. Pure public AX, no placement side
    /// effects — this never moves a window, only the user's view to wherever the
    /// window already is. Returns true if a match was raised.
    @discardableResult
    func jumpToWindow(ruleID: UUID) async -> Bool {
        guard gate.isTrusted else {
            log.warning("Accessibility not granted; jumpToWindow aborted")
            return false
        }
        // Explicit jump honours even disabled rules: the user picked this rule
        // by hand, so "disabled for auto-restore" shouldn't block navigation.
        guard let rule = state.activeLayout?.rules.first(where: { $0.id == ruleID }) else {
            log.info("jumpToWindow: no rule \(ruleID.uuidString, privacy: .public) in active layout")
            return false
        }
        let probe = probe
        let handles = await Task.detached(priority: .userInitiated, operation: {
            probe.snapshot()
        }).value
        guard let target = Self.firstWindow(matching: rule, among: handles) else {
            log.info("jumpToWindow: no live window matches rule \(ruleID.uuidString, privacy: .public)")
            return false
        }
        // raise() round-trips to the target app's AX server (activate + AXRaise
        // + kAXMain); keep it off the main actor like every other AX call so an
        // unresponsive app can't stall the menu bar.
        let mutator = mutator
        await Task.detached(priority: .userInitiated) {
            mutator.raise(target)
        }.value
        return true
    }

    /// First window whose descriptor satisfies `rule`. Factored out so the
    /// selection is unit-testable without the live Accessibility API.
    static func firstWindow(matching rule: Rule, among handles: [WindowHandle]) -> WindowHandle? {
        handles.first { RuleMatcher.matches(rule, against: $0.descriptor) }
    }
}

extension ActionCoordinator {
    private func applyPlacement(
        rule: Rule,
        handle: WindowHandle,
        displays: [DisplayFingerprint],
        source: RestoreSource,
        tally: inout RestoreTally) async
    {
        switch PlacementEngine.resolve(
            rule: rule,
            displays: displays,
            currentFrame: handle.descriptor.frame)
        {
        case let .applyFrame(resolved, display, _, fidelity):
            // Keep the target reachable: a frame above the menu bar would be
            // clamped down by macOS and drift forever (see clampToVisibleArea).
            let frame = Self.clampingIfMoving(
                resolved,
                from: handle.descriptor.frame,
                clamp: { clampToVisibleArea($0, on: display) })
            if state.config.autoTriggers.respectManualMoves,
               history.shouldSuppressAutoReplay(
                   rule: rule,
                   handle: handle,
                   targetFrame: frame,
                   targetDisplay: display,
                   source: source)
            {
                tally.skipped += 1
                log.info(
                    """
                    Skipping auto replay for \(handle.descriptor.bundleID, privacy: .public): \
                    window moved or resized since last placement (rule=\(rule.id.uuidString, privacy: .public))
                    """)
                return
            }
            await performWrite(
                frame: frame,
                proportional: fidelity == .proportional,
                rule: rule,
                handle: handle,
                tally: &tally)
        case .skipped:
            tally.skipped += 1
        case .queuedForReconnect:
            tally.queued.insert(rule.id)
        case .noDisplay:
            break
        }
    }

    /// Write a resolved frame to one window and record the outcome. A
    /// `proportional` placement (the engine remapped onto a different geometry
    /// than the rule saved - a panel at a transient resolution, or a substitute
    /// display) is counted whether the write lands cleanly or drifts, because
    /// it's a guess the wake-retry should re-check once displays settle.
    private func performWrite(
        frame: CGRect,
        proportional: Bool,
        rule: Rule,
        handle: WindowHandle,
        tally: inout RestoreTally) async
    {
        // The AX write blocks on XPC and sleeps between drift retries (up to
        // ~0.7s per window), so run it off the main actor exactly as
        // `AutoTriggerController.tryFulfil` does, then re-enter here only to
        // record the outcome. Writes stay serial: `restore` awaits one window's
        // performWrite before the next. The `isRestoring` flag, held on the main
        // actor across the pass, blocks a second *restore* from interleaving -
        // but unrelated main-actor work (menu, layout switch) still runs during
        // these awaits, so callers must not assume exclusive access to state.
        switch await Self.executeWrite(
            mutator: mutator,
            handle: handle,
            frame: frame,
            write: rule.restoreComponents.write)
        {
        case .applied:
            tally.applied += 1
            if proportional { tally.proportional += 1 }
            history.record(handle: handle, rule: rule, frame: frame)
            log.debug(
                "Applied \(rule.id.uuidString, privacy: .public) fidelity=\(proportional ? "proportional" : "exact", privacy: .public)")
        case let .drifted(target, actual, attempts):
            tally.drifted += 1
            if proportional { tally.proportional += 1 }
            // Record a baseline even though the app drifted. Otherwise a window
            // that chronically refuses its exact target (Firefox/Electron resize
            // quirks, an app that ignores a few points of position) never gets a
            // moved-by-user baseline, so `respectManualMoves` can never suppress
            // its perpetual re-placement. We record the target we asked for, not
            // the drifted actual, so the suppression target-match still holds on
            // the next pass and only a real user move (> threshold) suppresses.
            history.record(handle: handle, rule: rule, frame: frame)
            await logDrift(
                error: .drifted(target: target, actual: actual, attempts: attempts),
                bundleID: handle.descriptor.bundleID)
        case .elementGone:
            // The window closed mid-restore (app quit, window dismissed).
            // That's a no-op, not an app misbehaving — count it as skipped
            // so it neither pollutes `erroredBundles` nor triggers a
            // wake-retry pass that has nothing to retry.
            tally.skipped += 1
            log.debug("Window vanished mid-restore for \(handle.descriptor.bundleID, privacy: .public); skipping")
        case let .failed(message):
            tally.errors += 1
            tally.erroredBundles.insert(handle.descriptor.bundleID)
            log.error(
                "setFrame failed for \(handle.descriptor.bundleID, privacy: .public): \(message, privacy: .public)")
        }
    }

    /// Runs one window's AX write off the main actor and maps the result to a
    /// Sendable `WriteOutcome` the caller records on the main actor. Static so
    /// the detached closure captures only Sendable values (never `self`); the
    /// enclosing await hop is trivial while the blocking write and sleeps run in
    /// the detached task. `WindowMutator`'s internal setSize-last ordering is
    /// unaffected - only the executor moved.
    private static func executeWrite(
        mutator: any WindowMutating,
        handle: WindowHandle,
        frame: CGRect,
        write: RestoreWrite) async -> WriteOutcome
    {
        await Task.detached(priority: .userInitiated) { () -> WriteOutcome in
            do {
                switch write {
                case .frame:
                    try mutator.setFrame(handle, to: frame)
                case .size:
                    try mutator.setSize(handle, to: frame.size)
                case .position:
                    try mutator.setPosition(handle, to: frame.origin)
                case .nothing:
                    // Unreachable: the engine skips a rule with no components
                    // before it ever resolves a frame.
                    break
                }
                return .applied
            } catch let error as AXOperationError {
                switch error {
                case let .drifted(target, actual, attempts):
                    return .drifted(target: target, actual: actual, attempts: attempts)
                case .elementGone:
                    return .elementGone
                default:
                    return .failed(error.localizedDescription)
                }
            } catch {
                return .failed(error.localizedDescription)
            }
        }.value
    }

    /// Apply `clamp` only when the resolved target actually moves the window.
    ///
    /// A frame the window already occupies is by definition one macOS honours,
    /// so clamping it can only introduce movement - which is exactly what a
    /// `.displayOnly` rule promises not to do for a window already on its
    /// target display. Without this, a window straddling a display seam with
    /// its top edge above that display's menu bar gets pulled down on every
    /// restore, and `.displayOnly` rules are exempt from moved-by-user
    /// suppression, so it recurs every time the user drags it back.
    ///
    /// Shared by both write paths (`applyPlacement` here and
    /// `AutoTriggerController.tryFulfil`) so the two can't drift apart.
    static func clampingIfMoving(
        _ resolved: CGRect,
        from current: CGRect,
        clamp: (CGRect) -> CGRect) -> CGRect
    {
        resolved.equalTo(current) ? resolved : clamp(resolved)
    }

    /// Clamp a resolved global-AX target to what macOS will actually honour on
    /// `display`: a window can't sit above the menu bar, and an unreachable
    /// target there drifts on every write and keeps re-triggering. Falls back to
    /// the unclamped frame when the display isn't live (shouldn't happen for a
    /// frame the engine just resolved onto it). See `Coordinates`.
    private func clampToVisibleArea(_ frame: CGRect, on display: DisplayFingerprint) -> CGRect {
        guard let topY = DisplayProbe.visibleTopY(for: display) else { return frame }
        return Coordinates.clampingBelowMenuBar(frame, visibleTopY: topY)
    }

    /// A drift means the AX writes succeeded but the app ignored the size
    /// (classic: Firefox post-wake, some Electron apps). Surface it to the
    /// NDJSON log so users can see which app is refusing resize without
    /// having to pass `--info` to `log show`.
    func logDrift(error: AXOperationError, bundleID: String) async {
        guard case let .drifted(target, actual, attempts) = error else { return }
        let targetDesc = Self.formatDriftFrame(target)
        let actualDesc = Self.formatDriftFrame(actual)
        log.warning(
            """
            Window drifted: bundle=\(bundleID, privacy: .public) \
            target=\(targetDesc, privacy: .public) \
            actual=\(actualDesc, privacy: .public)
            """)
        await fileLog.append(
            level: .warn,
            category: "actions",
            message: "Window drifted",
            metadata: [
                "bundle": bundleID,
                "attempts": "\(attempts)",
                "target": targetDesc,
                "actual": actualDesc
            ])
    }

    /// Format a frame for the drift diagnostic as four comma-separated
    /// components `x,y,width,height`, each to one decimal place. Fixed and
    /// machine-parseable so the `Window drifted` NDJSON entry stays the
    /// dependable surface for app-specific AX misbehaviour, unlike
    /// `String(describing:)` whose layout carries no such guarantee. Pure: it
    /// reads no coordinator state, so it is unit-testable in isolation.
    nonisolated static func formatDriftFrame(_ rect: CGRect) -> String {
        String(
            format: "%.1f,%.1f,%.1f,%.1f",
            Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height))
    }
}

public extension ActionCoordinator {
    /// Outcome of `restore(windowsForUI:)`. The per-app launch retry loop
    /// uses this to decide whether to retry: `noMatch` and `droppedBusy` are
    /// retryable, `applied` and `untrusted` are terminal.
    enum RestoreOutcome: Sendable {
        case applied
        case noMatch
        case droppedBusy
        case untrusted
    }

    /// Restore a specific set of windows. Returns an outcome so the per-app
    /// launch retry loop can distinguish applied / no-match / dropped-busy /
    /// untrusted; other callers can ignore the result.
    /// `source` has no default for the same reason `restoreAllWindows` doesn't:
    /// the launch retry calls this automatically and the recover action calls it
    /// on the user's behalf, and only one of those honours a rule's opt-out.
    @discardableResult
    func restore(
        windowsForUI handles: [WindowHandle],
        source: RestoreSource) async -> RestoreOutcome
    {
        guard gate.isTrusted else {
            log.warning("Accessibility not granted; per-app restore aborted")
            return .untrusted
        }
        guard beginRestore(reason: "restore(windowsForUI:)") else { return .droppedBusy }
        defer { endRestore() }
        let tally = await restore(windows: handles, source: source)
        return tally.applied > 0 ? .applied : .noMatch
    }
}

/// Result of one off-main AX write, carried back to the main actor so
/// `performWrite` records the tally and placement history without the
/// non-Sendable `AXOperationError` crossing the actor boundary. `failed`
/// carries the error's description because the concrete error type stays in
/// the detached task. Implicitly Sendable (all payloads are), so no explicit
/// conformance.
private enum WriteOutcome {
    case applied
    case elementGone
    case drifted(target: CGRect, actual: CGRect, attempts: Int)
    case failed(String)
}
