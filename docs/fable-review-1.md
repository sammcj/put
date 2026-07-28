# Code Review: Fable Review 1

Full-codebase review conducted 2026-06-11 across all ten targets. Four parallel reviewers covered core/storage/placement, display/windows (AX), automation/hotkeys, and UI/app wiring. Every finding was then independently re-verified by an adversarial validation pass instructed to refute rather than confirm. 16 findings were raised; 15 were confirmed and 1 was refuted (a claimed `NSPanel` over-release in `SaveFlashPresenter` - `NSPanel` defaults `isReleasedWhenClosed` to false, unlike `NSWindow`, so no defect exists). Only confirmed findings appear below.

## Action checklist

Eight findings were actioned in the 2026-06-11 follow-up pass, chosen as the high-value, low-regression-risk subset: the contained correctness/data-loss/privacy fixes. The three concurrency-model changes (H1, H2, M2) and the harder structural fixes (L1-L4) were deliberately deferred - they rewrite actor-boundary behaviour or display-pairing logic and warrant their own focused change with dedicated testing. See "Follow-up status" below for per-item notes.

### High

- [ ] Move restore-path AX writes off the main actor in `ActionCoordinator.applyPlacement` (H1) - _deferred_
- [ ] Re-queue or retry display/wake triggers dropped while a restore is in flight; activate layouts only after their restore succeeds (H2) - _deferred_

### Medium

- [x] Quarantine (don't clobber) configs that fail `load()` for non-decoding reasons, especially future schema versions (M1)
- [ ] Run `DisplayProbe.snapshot()`'s NSScreen reads on the main actor (M2) - _deferred_
- [x] Make queued-rule fulfilment honour `restoresPosition`, use the injected mutator, and report errors (M3)
- [x] Flush `ConfigPersister` on app termination (M4)
- [x] Exclude Put's own windows from `saveFocusedWindowAllApp` (M5) - _self-exclusion done; capture-previously-frontmost-app deferred_
- [x] Register the `LoginItemController` activation observer on `NotificationCenter.default` (M6)

### Low

- [ ] Make `ConfigStore.save()`'s fallback branch crash-safe, or teach `load()` to recover from `config.json.backup` (L1) - _deferred_
- [ ] Detect external deletion of `put.log` and recreate the file/handle (L2) - _deferred_
- [ ] Fix or remove the unreachable defensive teardown in `DisplayChangeObserver.deinit` (L3) - _deferred_
- [ ] Handle identity-ambiguous displays in `ScreenConfigMatcher` pairing (L4) - _deferred_
- [x] Stop fabricating `actual` frames in `WindowMutator` drift errors when readback fails (L5)
- [x] Redact `DisplayFingerprint.localizedName` in `DiagnosticsExport.sanitise` (L6)
- [x] Guard pre-bootstrap entry points (`applicationShouldHandleReopen`) against nil app state (L7)

## Follow-up status (2026-06-11)

- **M1 - done.** `ConfigStore.load()` now quarantines on any decode/migrate failure (not only `DecodingError`), so a future-schema config written by a newer Put is moved aside as `config.corrupt-*.json` and a fresh bootstrap is written rather than the file being clobbered with no copy. Test `futureSchemaVersionQuarantinesAndBootstraps` replaces the old throw-expectation. Took the quarantine option over the refuse-to-save option as the more contained fix.
- **M3 - done.** `AutoTriggerController` now takes an injected `WindowMutating` (default `DefaultWindowMutator`); `tryFulfil` branches on `rule.restoresPosition` (size-only rules no longer have position rewritten on reconnect) and logs failed writes instead of swallowing them with `try?`. Dequeue semantics unchanged (still dequeues, now with diagnostics).
- **M4 - done.** `AppDelegate.applicationShouldTerminate` returns `.terminateLater`, flushes the `ConfigPersister`, then replies - so a layout/settings change made inside the 400ms debounce window survives quit.
- **M5 - partial.** `ActionCoordinator.save(windows:applyToAll:)` filters out windows whose bundle is `Bundle.main.bundleIdentifier`, so the Rules tab "+" can no longer create a self-rule. The UX improvement of capturing the previously-frontmost app (so the button does something useful when Settings is key) is deferred - it needs activation-history tracking.
- **M6 - done.** `LoginItemController` registers/removes its `didBecomeActiveNotification` observer on `NotificationCenter.default` instead of the workspace centre, so the cached `isEnabled` refreshes after a System Settings toggle.
- **L5 - done.** `WindowMutator.setFrame`/`setSize` throw `AXOperationError.elementGone` when the final readback fails, instead of fabricating an `actual` frame (target / zero-origin) that polluted the "Window drifted" NDJSON diagnostic.
- **L6 - done.** `DiagnosticsExport.sanitise` now strips `localizedName` from every `DisplayFingerprint` on both `rule.targetDisplay` and `layout.screenConfigs[].displays`. Covered by `sanitiseRemovesDisplayLocalizedNames`.
- **L7 - done.** `AppDelegate.showSettings` guards against nil bootstrap dependencies, so a relaunch during a slow `await store.load()` no longer fatally unwraps nil state.

## High severity

### H1. Restore executes blocking AX writes with sleep-based retries on the main actor

`Sources/PutAutomation/ActionCoordinator.swift` (`applyPlacement`)

`ActionCoordinator` is `@MainActor`, and `applyPlacement` calls `mutator.setFrame` / `mutator.setSize` synchronously. `WindowMutator.setFrame` is a synchronous XPC round-trip loop with up to three attempts and `Thread.sleep(forTimeInterval: 0.35)` between them, so a single drifting window blocks the main thread for roughly 0.7s of sleep plus several XPC writes and readbacks, serially per window across a restore pass. During display-change storms (exactly when auto restores fire) this freezes the menu bar and Settings UI and stalls every other main-actor task, including the debounce timers. The probe reads are correctly dispatched via `Task.detached`; the write path is not, and `AutoTriggerController.tryFulfil` already detaches its own identical `setFrame` calls, confirming the inconsistency. This also directly aggravates H2 by making in-flight restores routinely outlast the 1s trigger debounce.

**Fix direction:** route the write loop through the same `Task.detached` pattern the reads use, re-entering the main actor only for state mutation, per the documented project pattern.

### H2. Display/wake triggers arriving mid-restore are permanently dropped; a layout can be activated without ever being applied

`Sources/PutAutomation/AutoTriggerController.swift` (`runSettledRestore`, `applyLayoutTriggersIfMatching`)

`runSettledRestore` consumes and clears `pendingReasons`, then calls `coordinator.restoreAllWindows`. If a previous restore is still in flight, `beginRestore` drops the trigger and returns nil, and nothing re-queues the event: `scheduleWakeRetryIfNeeded` requires a non-nil result, so the display reconfiguration is silently lost and windows stay misplaced until some unrelated future trigger. The per-app launch path explicitly retries on `.droppedBusy`, proving the collision is a known live outcome; the display/wake path has no equivalent recovery. Worse, on the layout-trigger path `onActivateLayout?(match.layoutID)` fires (switching and persisting `activeLayoutID`) before the restore call, so a busy-dropped restore leaves a newly activated layout that was never applied, with the fallback global restore suppressed because the trigger counted as fired.

**Fix direction:** when `restoreAllWindows` returns nil, restore the consumed reasons to `pendingReasons` and re-schedule the settle pass; move layout activation (or at least its persistence) to after a successful restore.

## Medium severity

### M1. A future-schema config is silently clobbered by the bootstrap fallback

`Sources/PutStorage/ConfigStore.swift` (`load`, `migrate`), `Sources/Put/PutApp.swift` (`bootstrap`)

`migrate()` throws `unsupportedSchemaVersion` for a config written by a newer Put, but that error is not a `DecodingError`, so it bypasses the quarantine branch in `load()` and nothing on disk is preserved. The sole caller catches all load errors uniformly and substitutes `Config.bootstrap()`; the next debounced or coordinator-driven `save()` then overwrites the newer-schema file with the empty bootstrap, destroying every layout and rule with no `.corrupt-*` copy. The same propagate-bootstrap-clobber path applies to a transient read failure of `Data(contentsOf:)` at launch. Manifests on app downgrade or a one-off IO error.

**Fix direction:** quarantine the existing file for any load failure (not only `DecodingError`), or refuse to auto-save over a file whose schema version was newer than `putSchemaVersion`.

### M2. `DisplayProbe.snapshot()` reads NSScreen state off the main thread

`Sources/PutDisplay/DisplayProbe.swift` (`indexedScreens`), call sites in `ActionCoordinator` and `AutoTriggerController`

`snapshot()` reads `NSScreen.screens`, `backingScaleFactor`, and `localizedName`, but PutAutomation invokes it from `Task.detached` background contexts - worst exactly during display reconfiguration, when AppKit is rebuilding its screen list on the main thread. NSScreen carries no `@MainActor` annotation in the SDK, so Swift 6 strict concurrency is silent. An off-main read that misses `screensByID[id]` silently falls back to `scaleFactor = 1` and `localizedName = nil`, defeating `DisplayFingerprint.sameGeometry` and forcing proportional remapping with no error. The probe's own doc comment ("fast enough to call on the main thread") shows it was written assuming main-thread use; the PutUI call sites honour that, the PutAutomation ones don't.

**Fix direction:** hop to the main actor for the NSScreen enumeration (the CGDirectDisplay calls can stay off-main), or capture the screen index on the main actor before detaching.

### M3. Queued-rule fulfilment ignores `restoresPosition`, bypasses the injected mutator, and swallows all errors

`Sources/PutAutomation/AutoTriggerController.swift` (`tryFulfil`)

The `.applyFrame` branch applies the static `WindowMutator.setFrame` unconditionally with `try?` for every matching window. A size-only rule (`restoresPosition == false`) therefore has its position forcibly rewritten when its display reconnects, contradicting the contract `ActionCoordinator.applyPlacement` honours. It also bypasses the test-injectable `WindowMutating` seam, and `return true` unconditionally dequeues the rule even when every write failed - no tally, no "Window drifted" NDJSON entry, no log line, losing the placement with zero diagnostics.

**Fix direction:** branch on `rule.restoresPosition`, call through the injected mutator, and only dequeue on success (or dequeue with an error log so the drift diagnostics workflow still works).

### M4. Pending debounced config writes are lost on quit

`Sources/Put/PutApp.swift` (`applicationWillTerminate`), `Sources/PutUI/Settings/ConfigPersister.swift`

`ConfigPersister.scheduleWrite()` debounces 400ms via `Task.sleep`, and its doc comment requires a `flush()` on termination - but `applicationWillTerminate` tears down hotkeys and triggers without flushing, and no `applicationShouldTerminate` exists. Picking a layout from the menu bar or via hotkey then quitting within the debounce window silently loses the change; `windowWillClose` is not reliably delivered on `NSApp.terminate`, so the same applies to the last sub-400ms of Settings edits on Cmd-Q. Window saves are unaffected (`ActionCoordinator.persistConfig` writes immediately). Note `flush()` is async, so `applicationWillTerminate` alone can't fix it - this needs `applicationShouldTerminate` returning `.terminateLater` (or a synchronous save path).

### M5. The Rules tab "+" button always captures Put's own Settings window

`Sources/PutUI/Settings/RulesTab.swift`, `Sources/PutWindows/WindowProbe.swift` (`focusedWindow`)

The "+" button (and its Cmd-N shortcut, which only fires while the Settings window is key) calls `saveFocusedWindowAllApp`, which resolves the target via `NSWorkspace.shared.frontmostApplication` with no self-exclusion anywhere in the probe or save path. Clicking the button necessarily makes Put frontmost, so the affordance always creates an `applyToAllWindows` rule for `net.smcleod.put` matching the Settings window itself - it can never do what its help text claims. The self-rule then pollutes the active layout, and "Restore All" will apply it to Put's own windows whenever Settings is open.

**Fix direction:** exclude `Bundle.main.bundleIdentifier` in the probe or save path, and capture the previously active application (or prompt the user to focus the target window) instead.

### M6. Login-item activation observer is registered on the wrong notification centre

`Sources/PutAutomation/LoginItemController.swift`

The controller observes `NSApplication.didBecomeActiveNotification` on `NSWorkspace.shared.notificationCenter`, but AppKit posts application lifecycle notifications to `NotificationCenter.default`; the workspace centre only delivers `NSWorkspace.*` notifications. The observer never fires, so the documented refresh-on-activate behaviour does not exist. No other refresh path compensates: the `refresh()` calls in PutUI are DisplaysTab's own local function, and GeneralTab binds directly to `loginItem.isEnabled` without refreshing on appear. After the user toggles the login item in System Settings, the Settings toggle shows stale state, and because `setEnabled` guards on the stale cache the toggle can act in the wrong direction and the user cannot correct it from within Put.

**Fix direction:** register on `NotificationCenter.default` (and remove from the same centre in `stop()`).

## Low severity

### L1. `save()`'s fallback branch is non-atomic and its recovery artefacts are never read

`Sources/PutStorage/ConfigStore.swift` (`save`)

When `replaceItemAt` fails, the fallback deletes the live file before `moveItem`. A crash between those calls leaves no `config.json`; on next launch `load()` sees the file missing and bootstraps, even though `config.json.backup` sits beside it - the read path never consults it. In the worst-case branch (replace failed, backup copy failed, move failed) the code deletes `tempURL`, the only surviving copy of either config. Exposure is narrow but the failure mode is silent total config loss.

### L2. `FileLog` keeps writing to an unlinked inode after external deletion of `put.log`

`Sources/PutStorage/FileLog.swift` (`ensureHandle`, `rotateIfNeeded`)

If the active log file is deleted while Put runs, the cached `FileHandle` still points at the unlinked inode. `rotateIfNeeded` bails because `fileExists` is false, so rotation is permanently disabled and the inode grows unbounded; `ensureHandle` returns the stale handle without revalidating the path. Writes keep succeeding, so no error path fires, and all diagnostics until restart vanish when the process exits - defeating the sidecar's purpose.

### L3. `DisplayChangeObserver.deinit` teardown is provably unreachable

`Sources/PutDisplay/DisplayChangeObserver.swift`

`start()` does `Unmanaged.passRetained(self)`, so the observer self-retains until `stop()` releases it - `deinit` can therefore only run when `retainedPtr` is already nil, making the "defensive" teardown branch dead code. The safety net the comment promises does not exist: an owner that drops the observer without `stop()` leaks it forever, leaves the CG callback registered, and never finishes the `AsyncStream`. All current owners pair `stop()` correctly, so this is latent.

### L4. Greedy display pairing mishandles identity-ambiguous displays

`Sources/PutDisplay/ScreenConfigMatcher.swift`, `Sources/PutDisplay/DisplayMatcher.swift`

Two defects in the captured-to-live pairing loop. First, the `consumed` set is keyed on `DisplayFingerprint.id`; two live displays sharing an id (same vendor and product with nil serial and nil UUID - and macOS is known to synthesise identical UUIDs for identical EDIDs lacking serials) mean consuming one excludes both from later candidate sets, so a trigger captured against twin displays returns `.noMatch` even when the configuration matches exactly. Second, pairing is greedy in trigger order with no backtracking, and the vendor+product branch returns the first unconsumed candidate, so twin displays can pair crosswise; under `arrangementStrict` the offset comparison then spuriously fails despite a valid alternative pairing.

### L5. Drift errors fabricate the `actual` frame when readback fails

`Sources/PutWindows/WindowMutator.swift` (`setFrame`, `setSize`)

When the final frame readback fails (window closed mid-restore), `setFrame` substitutes the requested target for the actual frame: it logs `drifted=false` while throwing `AXOperationError.drifted` with identical target and actual, and `logDrift` writes that fabricated pair into the NDJSON "Window drifted" entries documented as the primary diagnostic for app-specific AX misbehaviour. The `setSize` path similarly fabricates a zero origin that was never observed. Diagnostics-only, but it actively misleads the documented debugging workflow; a distinct `elementGone` error would be honest.

### L6. Sanitised diagnostics leak `DisplayFingerprint.localizedName`

`Sources/PutAutomation/DiagnosticsExport.swift` (`sanitise`)

`sanitise()` redacts layout names, rule labels, and title patterns, but leaves `localizedName` intact in `rule.targetDisplay` and `layout.screenConfigs[].displays`. `NSScreen.localizedName` for Sidecar/AirPlay displays commonly embeds the owner's name (for example "Sam's iPad"), so the exported `config.json` carries personally identifying data the doc comment claims is removed. The log redactor doesn't apply to `config.json`, so nothing else scrubs it.

### L7. Reopen before async bootstrap completes crashes on nil app state

`Sources/Put/PutApp.swift` (`applicationShouldHandleReopen`, `showSettings`)

`state`, `coordinator`, `persister`, and `loginItem` are implicitly-unwrapped optionals populated only inside `bootstrap()`, which suspends at `await store.load()` before assigning them. `applicationShouldHandleReopen` (fired by a second launch attempt via double-click or Spotlight during a slow config load) routes through `showSettings()`, which passes nil state into `SettingsWindowController` - a fatal unwrap. The window is brief, hence low severity; a simple `guard state != nil` (or deferring the relaunch handler until bootstrap completes) closes it.

## Refuted during validation

- **FlashPanel missing `isReleasedWhenClosed = false`** (`Sources/PutUI/SaveFlashPresenter.swift`): claimed over-release on every save flash. Refuted: `NSPanel` (unlike `NSWindow`) defaults `isReleasedWhenClosed` to false, verified empirically on macOS 26. The explicit assignments elsewhere in the codebase are on `NSWindow` instances, where the default genuinely is true. No defect.
