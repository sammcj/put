import AppKit
import Foundation
import OSLog
import PutCore
import PutDisplay
import PutPlacement
import PutWindows

/// Wires the three automatic-restore triggers (display change, app launch,
/// wake) to the `ActionCoordinator`. Each trigger is gated on the
/// corresponding `AutoTriggerSettings` flag, so toggling them in Settings
/// takes effect immediately without needing to restart.
@MainActor
public final class AutoTriggerController {
    /// Reason a settle-and-restore pass was scheduled. Multiple reasons can
    /// coalesce into a single pass when they arrive inside the debounce
    /// window (typical: wake → display reconfig burst).
    enum SettleReason: String {
        case displayChange
        case wake
    }

    private let state: AppState
    private let coordinator: ActionCoordinator
    private let displayObserver: DisplayChangeObserver
    private let probe: any WindowProbing
    private let mutator: any WindowMutating
    private let debounceInterval: TimeInterval
    private let log: Logger = PutLog.logger(category: "automation.triggers")

    private let debouncer: Debouncer
    /// Reasons awaiting a settle pass. `private(set)` so tests can observe a
    /// re-queued batch; only the controller mutates it.
    private(set) var pendingReasons: Set<SettleReason> = []
    /// Consecutive settled-restore busy-drops, bounding the re-queue in
    /// `requeueDroppedReasons` so a persistently busy coordinator can't
    /// ping-pong the debouncer forever. Reset whenever a restore lands.
    private var consecutiveSettleDrops = 0
    /// Monotonic count of settled-restore re-queue attempts. Internal so tests
    /// can observe that a busy-drop was re-queued rather than silently lost.
    private(set) var settleRequeueAttempts = 0
    private var displayStreamTask: Task<Void, Never>?
    private var appLaunchObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    /// Screens powering back on (display-idle wake, or the screen half of a
    /// system wake). `didWakeNotification` only covers full system sleep, so on
    /// a lock/display-off-on the saved layout never got reasserted as a "return"
    /// event - it was caught, if at all, only incidentally via display reconfig.
    private var screensWakeObserver: NSObjectProtocol?
    /// Lock-screen unlock with no display power cycle (screensaver-only). Comes
    /// from the distributed centre; undocumented but delivered to a
    /// non-sandboxed app. Belt-and-braces alongside `screensWakeObserver`.
    private var unlockObserver: NSObjectProtocol?
    private var correctiveRetryTask: Task<Void, Never>?
    private let wakeRetryDelays: [TimeInterval]

    /// Monotonic clock for the wake-settle gate. Held as an instance so the
    /// timestamps below share one timeline.
    private let clock = ContinuousClock()
    /// When the most recent display-reconfigure event arrived. Drives the
    /// quiet-window check that holds a wake restore until the panels settle.
    private var lastDisplayEventAt: ContinuousClock.Instant?
    /// When the current post-disruption batch (wake or display reconfigure)
    /// first asked for a restore. Bounds how long the settle gate can defer
    /// (see `settleCap`). Cleared once the restore runs.
    private var settleStartedAt: ContinuousClock.Instant?
    private let settleQuietWindow: TimeInterval
    private let settleCap: TimeInterval
    private let retryDropBackoff: TimeInterval
    private let maxConsecutiveDrops: Int

    /// Backoff schedule for the per-app launch retry loop. See `RestoreTiming`.
    private let launchRetryDelays: [Duration]
    /// In-flight launch-retry tasks keyed by bundleID so a fresh launch of
    /// the same app cancels any previous retry that's still looping. Without
    /// this, a quit + relaunch within the retry window would let a stale
    /// task fire after the user has manually moved the new window.
    private var pendingLaunchTasks: [String: Task<Void, Never>] = [:]

    /// Invoked to persist a screen-config-triggered layout activation. The
    /// controller switches `state.config.activeLayoutID` in memory itself so
    /// the restore applies the matched layout, then calls this hook only AFTER
    /// the restore lands, so a busy-dropped restore never persists an
    /// activation that was never applied (C4). The hook re-affirms the active
    /// layout and schedules the config write; it is wired by `AppDelegate`
    /// because `ConfigPersister` lives in PutUI and can't be imported here.
    public var onActivateLayout: (@MainActor (UUID) -> Void)?

    public init(
        state: AppState,
        coordinator: ActionCoordinator,
        displayObserver: DisplayChangeObserver = DisplayChangeObserver(),
        probe: any WindowProbing = DefaultWindowProbe(),
        mutator: any WindowMutating = DefaultWindowMutator(),
        debounceInterval: TimeInterval = RestoreTiming.debounceInterval,
        launchRetryDelays: [Duration] = AutoTriggerController.defaultLaunchRetryDelays,
        wakeRetryDelays: [TimeInterval] = RestoreTiming.wakeRetryDelays,
        settleQuietWindow: TimeInterval = RestoreTiming.wakeSettleQuietWindow,
        settleCap: TimeInterval = RestoreTiming.wakeSettleCap,
        retryDropBackoff: TimeInterval = RestoreTiming.wakeRetryDropBackoff,
        maxConsecutiveDrops: Int = RestoreTiming.wakeRetryMaxConsecutiveDrops)
    {
        self.state = state
        self.coordinator = coordinator
        self.displayObserver = displayObserver
        self.probe = probe
        self.mutator = mutator
        self.debounceInterval = debounceInterval
        self.launchRetryDelays = launchRetryDelays
        self.wakeRetryDelays = wakeRetryDelays
        self.settleQuietWindow = settleQuietWindow
        self.settleCap = settleCap
        self.retryDropBackoff = retryDropBackoff
        self.maxConsecutiveDrops = maxConsecutiveDrops
        debouncer = Debouncer(interval: debounceInterval)
    }

    public static let defaultLaunchRetryDelays: [Duration] = RestoreTiming.launchRetryDelays

    // MARK: - Lifecycle

    public func start() {
        displayObserver.start()
        displayStreamTask = Task { [weak self] in
            guard let self else { return }
            for await event in displayObserver.events {
                if case .configurationChanged = event {
                    scheduleSettledRestore(reason: .displayChange)
                }
            }
        }

        appLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main)
        { [weak self] notification in
            // Extract only Sendable information before crossing the actor hop.
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            Task { @MainActor in self?.onAppLaunched(bundleID: bundleID) }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main)
        { [weak self] _ in
            Task { @MainActor in self?.scheduleSettledRestore(reason: .wake) }
        }

        // Display-idle wake (system never slept) and the screen half of a full
        // wake. Routed as `.wake` so it inherits the wake gating, settle, and
        // corrective retry; the debouncer coalesces it with `didWake` on a full
        // wake so only one restore runs.
        screensWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main)
        { [weak self] _ in
            Task { @MainActor in self?.scheduleSettledRestore(reason: .wake) }
        }

        // Lock-screen unlock with no display power cycle. Distributed centre,
        // main queue; same `.wake` routing and coalescing as above.
        unlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main)
        { [weak self] _ in
            Task { @MainActor in self?.scheduleSettledRestore(reason: .wake) }
        }

        log.info("Auto triggers started")
    }

    public func stop() {
        debouncer.cancel()
        pendingReasons.removeAll()
        consecutiveSettleDrops = 0
        settleStartedAt = nil
        lastDisplayEventAt = nil
        correctiveRetryTask?.cancel()
        correctiveRetryTask = nil
        for task in pendingLaunchTasks.values {
            task.cancel()
        }
        pendingLaunchTasks.removeAll()
        displayStreamTask?.cancel()
        displayStreamTask = nil
        displayObserver.stop()
        if let appLaunchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appLaunchObserver)
            self.appLaunchObserver = nil
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if let screensWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(screensWakeObserver)
            self.screensWakeObserver = nil
        }
        if let unlockObserver {
            DistributedNotificationCenter.default().removeObserver(unlockObserver)
            self.unlockObserver = nil
        }
        log.info("Auto triggers stopped")
    }

    // MARK: - Handlers

    /// Records that something happened which may warrant a restore (wake or
    /// display reconfiguration) and schedules a debounced settle pass. Wake
    /// and display events coalesce: a reconfiguration burst that arrives
    /// shortly after `didWakeNotification` extends the debounce window and
    /// folds into one restore. This is deliberate — firing wake's restore
    /// early (before external panels have finished reconnecting) and then
    /// having the display-change restore dropped by the in-flight
    /// `isRestoring` guard was the cause of "some windows didn't place back
    /// after wake".
    func scheduleSettledRestore(reason: SettleReason) {
        if reason == .displayChange { lastDisplayEventAt = clock.now }
        // Both wake and display reconfiguration can race AX servers and a
        // still-settling display set, so both arm the settle gate.
        if settleStartedAt == nil { settleStartedAt = clock.now }
        pendingReasons.insert(reason)
        debouncer.schedule { [weak self] in
            guard let self else { return }
            await runSettledRestore()
        }
    }

    private func runSettledRestore() async {
        guard !pendingReasons.isEmpty else { return }

        // Hold the restore until the display-reconfigure burst has gone quiet,
        // so the first pass runs against the settled geometry instead of racing
        // mid-reconfigure (which collides with a concurrent restore and gets one
        // dropped by the single-flight guard). Applies to both wake and
        // display-change batches - a lock/display-on storm needs this just as
        // much as a wake. A wake with no display events doesn't defer
        // (`lastDisplayEventAt` is nil). Reuse the debouncer as the poll timer
        // rather than a separate loop, so only one restore is ever in flight.
        // Reasons are kept, not consumed, while we wait.
        if shouldDeferForDisplaySettle() {
            debouncer.schedule { [weak self] in
                guard let self else { return }
                await runSettledRestore()
            }
            return
        }

        let reasons = pendingReasons
        pendingReasons.removeAll()
        settleStartedAt = nil
        guard !reasons.isEmpty else { return }

        let reasonList = reasons.map(\.rawValue).sorted().joined(separator: ",")

        // Layout-trigger pass first when a display reconfigure is part of this
        // batch. A layout that owns the event short-circuits the global path:
        // on a successful apply we don't double-restore, and on a busy-drop we
        // re-queue rather than fall through and risk applying the wrong layout
        // (C3/C4). Layout triggers are NOT gated on `autoTriggers.onDisplayChange`
        // - the per-layout `autoActivate` flag is the kill switch, letting users
        // opt into layout-driven behaviour while keeping the global toggle off.
        if reasons.contains(.displayChange) {
            switch await evaluateAndApplyLayoutTrigger(reasonList: reasonList) {
            case .noAction:
                break
            case let .applied(result):
                consecutiveSettleDrops = 0
                // Layout-fired restore inherits the same corrective-retry safety
                // net as the global path so transient AX errors after a wake or
                // a display reconfigure still get a second pass.
                scheduleCorrectiveRetryIfNeeded(reasons: reasons, result: result)
                await fulfilQueuedRules()
                return
            case .droppedBusy:
                requeueDroppedReasons(reasons)
                await fulfilQueuedRules()
                return
            }
        }

        await runGlobalRestore(reasons: reasons, reasonList: reasonList)
        await fulfilQueuedRules()
    }

    /// If any rules are awaiting a reconnect and their display is now
    /// present, apply them and clear them from the queue. AX and display
    /// probes run detached so the menu bar doesn't block on XPC.
    private func fulfilQueuedRules() async {
        guard !state.queuedRuleIDs.isEmpty else { return }
        guard let activeLayout = state.activeLayout else { return }
        let queuedIDs = state.queuedRuleIDs

        guard let (displays, liveWindows) = await probeDisplaysAndWindows() else { return }

        var fulfilled: Set<UUID> = []
        for ruleID in queuedIDs {
            let didFulfil = await tryFulfil(
                ruleID: ruleID,
                in: activeLayout,
                displays: displays,
                liveWindows: liveWindows)
            if didFulfil {
                fulfilled.insert(ruleID)
            }
        }

        if !fulfilled.isEmpty {
            state.queuedRuleIDs.subtract(fulfilled)
            log.info("Fulfilled \(fulfilled.count, privacy: .public) queued rules after reconnect")
        }
    }

    private func probeDisplaysAndWindows() async -> (displays: [DisplayFingerprint], windows: [WindowHandle])? {
        // Displays read NSScreen, so probe them on the main actor (C10); the AX
        // window probe blocks on XPC, so keep only that half detached.
        guard let displays = try? DisplayProbe.snapshot() else { return nil }
        let probe = probe
        let windows = await Task.detached(priority: .userInitiated) {
            probe.snapshot()
        }.value
        return (displays, windows)
    }

    /// Attempts to fulfil a single queued rule. Returns true when the rule
    /// has been applied (or dropped because it no longer exists) and should
    /// be removed from the queue.
    private func tryFulfil(
        ruleID: UUID,
        in activeLayout: PutCore.Layout,
        displays: [DisplayFingerprint],
        liveWindows: [WindowHandle]) async -> Bool
    {
        guard let rule = activeLayout.rules.first(where: { $0.id == ruleID }) else {
            // Rule was deleted; drop from queue.
            return true
        }
        let match = DisplayMatcher.resolve(target: rule.targetDisplay, among: displays)
        guard let match, match.quality <= .equivalent else { return false }

        let matchingWindows = liveWindows.filter { RuleMatcher.matches(rule, against: $0.descriptor) }
        guard !matchingWindows.isEmpty else { return false }

        switch PlacementEngine.resolve(rule: rule, displays: displays) {
        case let .applyFrame(frame, _, _, _):
            let handlesToMove = matchingWindows
            let mutator = mutator
            // Honour the rule's `restoresPosition` contract (a size-only rule
            // must not have its position rewritten on reconnect), route through
            // the injected mutator seam, and surface write failures instead of
            // swallowing them with `try?`.
            let restoresPosition = rule.restoresPosition
            let failures = await Task.detached(priority: .userInitiated) { () -> Int in
                var failed = 0
                for handle in handlesToMove {
                    do {
                        if restoresPosition {
                            try mutator.setFrame(handle, to: frame)
                        } else {
                            try mutator.setSize(handle, to: frame.size)
                        }
                    } catch {
                        failed += 1
                    }
                }
                return failed
            }.value
            if failures > 0 {
                log.warning(
                    """
                    Queued-rule fulfilment: \(failures, privacy: .public) of \
                    \(handlesToMove.count, privacy: .public) writes failed \
                    for rule \(ruleID.uuidString, privacy: .public)
                    """)
            }
            return true
        default:
            return false
        }
    }
}

// MARK: - App launch retries

extension AutoTriggerController {
    /// Internal so tests can drive the launch path with a synthetic bundleID;
    /// `NSRunningApplication.current` posted via NotificationCenter has no
    /// settable bundleIdentifier in the xctest host.
    func onAppLaunched(bundleID: String?) {
        guard state.config.autoTriggers.onAppLaunch else { return }
        guard let bundleID, !bundleID.isEmpty else { return }
        // Skip the restore pass if no rule targets this app. Previously we
        // fired a restore for every launching app, which filled the log with
        // applied=0 Restore summaries for Finder, Safari, Terminal, etc. and
        // made it hard to spot genuine rule-matching failures.
        guard state.activeLayout?.rules.contains(where: { $0.matchCriteria.bundleID == bundleID }) == true else {
            return
        }
        log.info("App launched: \(bundleID, privacy: .public); scheduling restore")
        pendingLaunchTasks[bundleID]?.cancel()
        pendingLaunchTasks[bundleID] = Task { [weak self] in
            await self?.runLaunchRetries(bundleID: bundleID)
        }
    }

    /// Backoff retry loop driving the per-app launch restore. Cold launches
    /// and `isRestoring` collisions with wake/display restores both look
    /// identical to a one-shot trigger; this loop tells them apart via the
    /// `RestoreOutcome` returned by `coordinator.restore(windowsForUI:)`.
    private func runLaunchRetries(bundleID: String) async {
        let probe = probe
        for (index, delay) in launchRetryDelays.enumerated() {
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            if Task.isCancelled { return }

            let handles = await Task.detached(priority: .userInitiated) {
                probe.windows(forBundleID: bundleID)
            }.value
            let outcome = await coordinator.restore(windowsForUI: handles, source: .auto)
            switch outcome {
            case .applied:
                log.info(
                    "App launch restore applied for \(bundleID, privacy: .public) on attempt \(index + 1, privacy: .public)")
                return
            case .untrusted:
                log.info(
                    "App launch restore halting for \(bundleID, privacy: .public); accessibility not trusted")
                return
            case .noMatch, .droppedBusy:
                continue
            }
        }
        log.info(
            "App launch restore exhausted retries for \(bundleID, privacy: .public)")
    }
}

// MARK: - Wake settle & retry

extension AutoTriggerController {
    /// True while a restore should keep waiting for the display set to go
    /// quiet. Bounded by `settleCap` so a panel that never stops dribbling
    /// reconfigure events can't block the restore forever.
    func shouldDeferForDisplaySettle() -> Bool {
        let now = clock.now
        if let start = settleStartedAt, start.duration(to: now) >= .seconds(settleCap) {
            return false
        }
        guard let last = lastDisplayEventAt else { return false }
        return last.duration(to: now) < .seconds(settleQuietWindow)
    }

    /// Schedule corrective re-restores after a wake or display-reconfigure
    /// batch. Both disrupt AX servers and can leave a display momentarily at a
    /// transient resolution, so both get the safety net - a lock/display-on
    /// storm needs it as much as a wake from sleep.
    func scheduleCorrectiveRetryIfNeeded(
        reasons: Set<SettleReason>,
        result: ActionCoordinator.RestoreResult?)
    {
        // Arm on two signals. AX errors mean an app's Accessibility server
        // wasn't ready the instant the trigger fired. A proportional placement
        // means a panel was at a transient resolution, so a window got remapped
        // onto the wrong geometry - re-probing after the display settles lets
        // the saved absolute frame replay verbatim. Unmatched is NOT an arming
        // signal (it's non-zero in normal use); it only gates the stop
        // condition against the specific bundles that errored here.
        guard !reasons.isEmpty, correctiveRetryTask == nil,
              let result, result.errors > 0 || result.proportional > 0
        else { return }
        let pendingBundles = result.erroredBundles
        log.info(
            """
            Restore needs a corrective pass \
            (errors=\(result.errors, privacy: .public), \
            proportional=\(result.proportional, privacy: .public)); scheduling retries
            """)
        // Capture the schedule so the loop can read it before `self` unwraps.
        correctiveRetryTask = Task { [weak self, delays = wakeRetryDelays] in
            var index = 0
            var consecutiveDrops = 0
            while index < delays.count {
                try? await Task.sleep(for: .seconds(delays[index]))
                // Cancellation (from `stop()`) returns WITHOUT clearing the
                // handle: `stop()` already niled it, and a stop/start cycle may
                // have assigned a successor task we must not clobber.
                guard let self, !Task.isCancelled else { return }
                guard let retry = await coordinator.restoreAllWindows(source: .auto) else {
                    // Dropped by the single-flight guard (a concurrent restore
                    // was in flight). Don't burn this slot: wait a beat and
                    // retry the same step. Bounded so a permanently busy
                    // coordinator can't spin the loop forever.
                    consecutiveDrops += 1
                    if consecutiveDrops > maxConsecutiveDrops { break }
                    try? await Task.sleep(for: .seconds(retryDropBackoff))
                    continue
                }
                consecutiveDrops = 0
                if Self.correctivePassSettled(retry, pendingBundles: pendingBundles) { break }
                index += 1
            }
            // Reached on every non-cancellation exit (clean pass, schedule
            // exhausted, or drops capped), where the handle still points here.
            self?.correctiveRetryTask = nil
        }
    }

    /// Decide whether a corrective pass landed cleanly. Beyond "no AX errors,
    /// nothing proportional", a bundle that errored on the original pass isn't
    /// considered placed until it's neither erroring nor unmatched - this
    /// catches the errored->unmatched flip, where a window from a managed app
    /// reads as having no rule because its display was transiently absent.
    static func correctivePassSettled(
        _ result: ActionCoordinator.RestoreResult,
        pendingBundles: Set<String>) -> Bool
    {
        guard result.errors == 0, result.proportional == 0 else { return false }
        for bundle in pendingBundles
            where result.erroredBundles.contains(bundle) || result.unmatchedBundles.contains(bundle)
        {
            return false
        }
        return true
    }
}

// MARK: - Settle restore dispatch

extension AutoTriggerController {
    /// Run the global (non-layout) restore for a settled batch, gated on the
    /// relevant `autoTriggers` flags. A busy-dropped restore (nil result) is
    /// re-queued rather than silently lost (C3).
    private func runGlobalRestore(reasons: Set<SettleReason>, reasonList: String) async {
        let triggers = state.config.autoTriggers
        let shouldRestore = reasons.contains { reason in
            switch reason {
            case .displayChange:
                triggers.onDisplayChange
            case .wake:
                triggers.onWake
            }
        }
        guard shouldRestore else { return }

        log.info("Settled (\(reasonList, privacy: .public)); running restore")
        let result = await coordinator.restoreAllWindows(source: .auto)
        if result == nil {
            // Busy-dropped by the coordinator's single-flight guard. Re-queue the
            // consumed reasons so the batch isn't silently lost (C3), mirroring
            // the per-app launch path's `.droppedBusy` handling.
            requeueDroppedReasons(reasons)
        } else {
            consecutiveSettleDrops = 0
            scheduleCorrectiveRetryIfNeeded(reasons: reasons, result: result)
        }
    }

    /// Re-insert a settled-restore batch that the coordinator dropped because a
    /// restore was already in flight, and re-arm the debouncer so the batch runs
    /// again once the coordinator frees up. Bounded by `maxConsecutiveDrops` (the
    /// corrective-retry cap) and paced by the existing `debounceInterval`, so a
    /// persistently busy coordinator can't ping-pong forever.
    func requeueDroppedReasons(_ reasons: Set<SettleReason>) {
        settleRequeueAttempts &+= 1
        consecutiveSettleDrops += 1
        guard consecutiveSettleDrops <= maxConsecutiveDrops else {
            let drops = consecutiveSettleDrops
            log.warning(
                "Settled restore dropped busy \(drops, privacy: .public) times; abandoning re-queue")
            consecutiveSettleDrops = 0
            return
        }
        for reason in reasons {
            pendingReasons.insert(reason)
        }
        debouncer.schedule { [weak self] in
            guard let self else { return }
            await runSettledRestore()
        }
    }

    /// Probe current displays, evaluate every layout's screen-config trigger,
    /// and activate the first match if its `autoActivate` is set. Returns
    /// `(fired, result)`: `fired == true` means the controller owned this event
    /// end-to-end (matched, activated, and the restore landed) and the caller
    /// should suppress its own restore path. A busy-dropped restore returns
    /// `(false, nil)` and does NOT persist the activation (C4). Public so
    /// launch-time evaluation (PutApp) can reuse the same path.
    public func applyLayoutTriggersIfMatching(
        reasonList: String = "launch")
        async -> (fired: Bool, result: ActionCoordinator.RestoreResult?)
    {
        switch await evaluateAndApplyLayoutTrigger(reasonList: reasonList) {
        case .noAction:
            (false, nil)
        case let .applied(result):
            (true, result)
        case .droppedBusy:
            (false, nil)
        }
    }

    /// Outcome of evaluating (and, when matched with `autoActivate`, applying) a
    /// layout screen-config trigger. Distinguishes a busy-dropped restore from
    /// "no layout matched" so the settle path can re-queue the former without
    /// falling through to the global restore.
    private enum LayoutTriggerOutcome {
        case noAction
        case applied(ActionCoordinator.RestoreResult)
        case droppedBusy
    }

    private func evaluateAndApplyLayoutTrigger(reasonList: String) async -> LayoutTriggerOutcome {
        // Displays are probed on the main actor: `DisplayProbe` reads NSScreen
        // state (C10). No AX enumeration here, so nothing needs detaching.
        let displays = try? DisplayProbe.snapshot()

        guard let displays, !displays.isEmpty else { return .noAction }

        guard let match = LayoutTriggerEvaluator.evaluate(
            layouts: state.config.layouts,
            currentDisplays: displays)
        else {
            return .noAction
        }

        let layoutID = match.layoutID.uuidString
        guard match.autoActivate else {
            log.info(
                "Layout trigger matched (id=\(layoutID, privacy: .public); reason=\(reasonList, privacy: .public)); autoActivate=false")
            return .noAction
        }

        log.info(
            "Layout trigger matched (id=\(layoutID, privacy: .public); reason=\(reasonList, privacy: .public)); activating")

        // Switch the active layout in memory so the restore applies the matched
        // layout's rules, but defer persistence (`onActivateLayout`) until the
        // restore actually lands. A busy-dropped restore must not leave the user
        // on a newly activated layout that was never applied (C4): revert the
        // in-memory switch and let the settle path re-queue.
        let previousActiveLayoutID = state.config.activeLayoutID
        state.config.activeLayoutID = match.layoutID
        // `restoreAllWindows` awaits off-main AX writes, so the main actor is
        // free during it: the user can pick a different layout from the menu or a
        // hotkey mid-restore. That choice owns `activeLayoutID` and must win, so
        // both the busy-drop revert and the deferred activation only touch it
        // while it still holds the layout we set.
        guard let result = await coordinator.restoreAllWindows(source: .auto) else {
            if state.config.activeLayoutID == match.layoutID {
                state.config.activeLayoutID = previousActiveLayoutID
            }
            return .droppedBusy
        }
        if state.config.activeLayoutID == match.layoutID {
            onActivateLayout?(match.layoutID)
        }
        return .applied(result)
    }
}
