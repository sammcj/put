# Code Review (merged)

Merge of `fable-review-1.md` (2026-06-11, adversarially validated, 15 confirmed findings) and `code-review-2026-06-18.md` (2026-06-18, four parallel reviewers, 23 findings). The later review did not reference the earlier one and omitted four findings that remain open, so neither doc stood alone.

Each item carries its origin tag: `F-` for fable-review-1, `CR-` for code-review-2026-06-18. Items found by both are noted.

**Validation pass 2026-07-10.** Every finding below was re-checked against current `main` by eight independent read-only agents. Line counts and claim details were corrected where the original reviews had drifted. Three claims did not survive; they are recorded at the bottom under "Refuted on validation" rather than deleted, so a future review does not resurrect them. No test covers any of the outstanding findings unless stated.

**Resolved 2026-07-11 on branch `fable_refactor`.** All 28 findings are fixed and the 12-change remediation plan landed in full. The finding text below is kept for provenance, not as a work list: the `_Validated: still valid._` markers record the 2026-07-10 state and no longer describe the code, so do not reopen them from those markers alone. Where each landed:

- **C1, C23, C24** - `fba4c03` config never drops to zero copies, `load()` recovers from backup, FileLog tracks bytes in-actor and revalidates its inode
- **C2, C7, C11, C12** - `a6dead9` pure placement and matching guards
- **C8, C27** - `e1e959a` per-PR CI gate, `make lint` fails when tools are missing
- **C16** - `126590e` shared `PutTestSupport` fixture target
- **C5, C10** - `633d333` AX writes off the main actor, `DisplayProbe` main-actor
- **C3, C4** - `aa9d77f` re-queue busy-dropped triggers, defer layout activation
- **C6, C13** - `41d9c97` pair twin displays by instance, compare bounds tolerantly
- **C22, C25, C26** - `36cf1a6` parseable drift frames, shared AX downcast, dead deinit
- **C15, C28** - `ff8821b` `ActionCoordinator` decomposition, `function_body_length` 50
- **C14** - `63d7284` Rules tab "+" captures the previously active window
- **C17, C18, C21** - `c5b7ef5` About view, login-item toggle and display-observer dedupe
- **C9, C19, C20** - `536ae82` PutUITests, `RuleDetailForm` decomposition, persist on commit

An external review of the finished branch followed (`0689aac` and later): it caught two regressions the refactor itself introduced - rule edits persisting only on Return, and layout auto-activation clobbering a mid-restore user switch - plus a bounded-growth gap in `PlacementHistoryStore` and several comment and test-hygiene items. Those are fixed; see `CHANGELOG.md`.

C9 stays open-ended by design: the PutUI test target exists and covers the logic extracted so far, with further extraction proceeding incrementally rather than pretending one pass reaches 80% of a 3,022-line module.

## Findings (all resolved - see the resolution map above)

### High - correctness and data safety

**C1. Config write can lose data with no backup.** _Validated: still valid._ `ConfigStore.swift:129` does `try? fileManager.removeItem(at: fileURL)` before the fallback `moveItem` (`:131`). If `replaceItemAt` throws, the backup copy earlier failed (`backupTaken == false`), and the move then throws, both copies are gone - the worst-case branch at `:137` also deletes `tempURL`, the only surviving new copy, while the restore at `:133-135` is guarded by `if backupTaken`. Separately `load()` (`:43-76`) reads only `fileURL` and never consults `config.json.backup`, so a successful backup is inert across launches. Make the backup copy mandatory before the destructive remove, or drop the pre-remove and let `moveItem` replace; teach `load()` to recover from the backup.

The existing test `saveRestoresBackupWhenReplaceMoveAllFail` (`Tests/PutStorageTests/PutStorageTests.swift:170-184`) does **not** cover this: it concedes in a comment that it cannot simulate a replace/move failure and only asserts the backup is cleaned up after a successful save. The destructive rollback path is untested.

_`Sources/PutStorage/ConfigStore.swift`. Origin: CR-1 + F-L1._

**C2. `Coordinates.denormalise` multiplies by an unguarded `pointSize`.** _Validated: still valid._ `Coordinates.swift:49-50` reads `display.pointSize.width` / `.height` directly, while `normalise` (`:38-39`) guards with `max(..., 1)`. A display reporting zero `pointSize` during the transient post-wake enumeration - the case the fidelity flag exists for - denormalises every saved rule to a 0x0 frame at the origin. Guard symmetrically. `CoordinatesTests` only round-trips non-zero sizes.

_`Sources/PutPlacement/Coordinates.swift`. Origin: CR-2._

**C3. Busy-dropped auto-trigger reasons are permanently lost.** _Validated: still valid (narrowed)._ `restoreAllWindows` returns nil when a restore is already in flight (`ActionCoordinator.swift:135`, `guard beginRestore(...) else { return nil }`). The settled path then calls only `scheduleCorrectiveRetryIfNeeded` (`AutoTriggerController.swift:275`), which bails on a nil result (`:515-517`), so the reason batch - already cleared at `:243` - is silently lost until an unrelated future trigger. The per-app launch path proves the collision is a live outcome and handles it: `case .noMatch, .droppedBusy: continue` (`:476-477`). Re-queue the consumed reasons and reschedule the settle pass when the result is nil.

The original reviews also claimed a second mechanism (reasons repopulated during the `applyLayoutTriggersIfMatching` await are never rescheduled). That half is refuted - see below.

_`Sources/PutAutomation/AutoTriggerController.swift`. Origin: CR-3 + F-H2._

**C4. A layout can be activated without ever being applied.** _Validated: still valid._ In `applyLayoutTriggersIfMatching`, `onActivateLayout?(match.layoutID)` fires - switching and persisting `activeLayoutID` (`AutoTriggerController.swift:71-76`) - before the restore, and the function returns `fired = true` unconditionally (`:320-322`). A busy-dropped restore yields `result == nil` with `layoutFired == true`, so the fallback global restore is skipped (`:262`) and the corrective retry is not armed. The user is left on a newly activated layout that was never applied. Move layout activation, or at least its persistence, to after a successful restore.

_`Sources/PutAutomation/AutoTriggerController.swift`. Origin: F-H2 (second half)._

**C5. Restore executes blocking AX writes with sleep-based retries on the main actor.** _Validated: still valid, all three sub-points._ `ActionCoordinator` is `@MainActor` (`:14`); `applyPlacement` (`:493`) to `performWrite` (`:520`) calls `mutator.setFrame` / `mutator.setSize` synchronously with no `Task.detached` (`:549-551`). `WindowMutator` still blocks - `Thread.sleep(forTimeInterval: 0.35)` in both `setFrame` (`WindowMutator.swift:62`) and `setSize` (`:123`) with `maxAttempts = 3` (`:37`), so one drifting window costs up to ~0.7s of main-thread sleep plus several XPC round trips, serially per window. During display-change storms this freezes the menu bar and stalls the debounce timers, aggravating C3. The inconsistency is confirmed: `AutoTriggerController.tryFulfil` already wraps its equivalent write loop in `await Task.detached(priority: .userInitiated)` (`:396-410`). Route the write loop the same way, re-entering the main actor only for state mutation.

_`Sources/PutAutomation/ActionCoordinator.swift`. Origin: F-H1 (deferred, absent from CR)._

**C6. `ScreenConfigMatcher` greedy pairing is order-dependent and mishandles identity-ambiguous displays.** _Validated: still valid, both sub-claims._ (i) `ScreenConfigMatcher.swift:34,41` filters and inserts on `$0.id`, and `DisplayFingerprint.swift:64-72` builds `"vps:\(vendorID):\(productID):\(serial)"` with `serial = ... ?? "x"` for nil-serial, nil-UUID displays - so twins share one id string and `consumed.insert(...)` excludes both from later candidate sets, forcing `.noMatch` even on an exact configuration match. (ii) `DisplayMatcher.swift:66-70` returns `candidates.first(where:)` on vendor+product with no geometry check or backtracking, and the pairing loop (`ScreenConfigMatcher.swift:33-42`) is greedy in trigger order, so twins can pair crosswise and `arrangementsAlign` then spuriously fails despite a valid alternative pairing. Reject configs with duplicate fingerprint ids up front, or pair by a stable per-instance handle.

`ScreenConfigMatcherTests.swift:82-124` only uses distinct UUIDs and serials - no twin or crosswise case exists.

_`Sources/PutDisplay/ScreenConfigMatcher.swift`, `Sources/PutDisplay/DisplayMatcher.swift`. Origin: CR-4 + F-L4._

**C7. `displayContaining` attributes garbage frames to the primary display.** _Validated: still valid._ `Coordinates.swift:79-101` guards only `!displays.isEmpty` (`:83`); there is no `global.isNull || !global.isFinite` check, so a null or NaN rect intersects to area 0 everywhere, leaves `best` nil, and falls through to `return displays.first(where: { $0.isPrimary })` (`:100`). A corrupt save frame silently persists against primary rather than failing. `CoordinatesTests.swift:83-87` covers the no-overlap fallback but not a garbage rect.

_`Sources/PutPlacement/Coordinates.swift`. Origin: CR-5._

### High - CI and test gaps

**C8. CI verifies nothing per-PR.** _Validated: still valid._ `.github/workflows/release.yml` is the only workflow file. Its trigger is `on: workflow_dispatch:` (`:19-20`) with push and pull_request commented out (`:39-43`), and its only verification step is `run: make test` (`:108`) - no `make lint` or `swiftformat --lint` anywhere. Style, `file_length`, and `cyclomatic_complexity` violations reach `main` ungated. Re-enable test and add lint on `pull_request`.

_Origin: CR-6._

**C9. `PutUI` has zero tests.** _Validated: still valid; module has grown to 3,022 lines across 18 files (the review said 2,988)._ `Tests/` holds 8 suites but no `Tests/PutUITests/`. View models, formatting, and state-derivation logic in `MenuBarController`, `OnboardingWizard`, and the settings tabs are extractable and unit-testable. This is the single biggest reason the 80%-new-code coverage rule is unmet on a line-weighted basis.

_Origin: CR-7._

### Medium - concurrency

**C10. `DisplayProbe.snapshot()` reads NSScreen state off the main thread.** _Validated: still valid._ `ActionCoordinator.swift:426-428` and `AutoTriggerController.swift:298-299, 355-359` invoke `DisplayProbe.snapshot()` inside `Task.detached`, off the main actor. `DisplayProbe` carries no actor annotation, and `indexedScreens()` reads `NSScreen.screens` (`DisplayProbe.swift:68`) with the silent fallback `let scale = Double(screen?.backingScaleFactor ?? 1)` / `let localizedName = screen?.localizedName` (`:93-94`). Worst exactly during display reconfiguration, when AppKit is rebuilding its screen list on the main thread: a missed lookup defeats `DisplayFingerprint.sameGeometry` and forces proportional remapping with no error. NSScreen has no `@MainActor` annotation in the SDK, so Swift 6 strict concurrency stays silent. The probe's own doc comment ("fast enough to call on the main thread") shows it was written assuming main-thread use; the PutUI call sites honour that, the PutAutomation ones do not. Hop to the main actor for the NSScreen enumeration, or capture the screen index before detaching.

_`Sources/PutDisplay/DisplayProbe.swift`. Origin: F-M2 (deferred, absent from CR)._

### Medium - matching semantics and dedupe

**C11. `MatchCriteria.identityKey` carries `axRole` even when role is not evaluated.** _Validated: still valid._ `MatchCriteria.swift:50-56` always sets `axRole: axRole`, yet `RuleMatcher.matches` ignores role when `applyToAllWindows` (returns true at `RuleMatcher.swift:20-21`) and when `useTitlePatternExclusively` (role check guarded at `:28`). Two rules matching identical windows therefore get different dedupe keys and save-time dedupe spawns a duplicate. The key already blanks the title pattern, but only in the applyToAll branch (`effectiveTitlePattern: applyToAllWindows ? "" : titlePattern`, `:53`); role is never blanked. Mirror that blanking for role.

`identityKeyIgnoresTitlePatternWhenApplyToAll` (`PutCoreTests.swift:165`) covers the title case; nothing asserts role is ignored.

_`Sources/PutCore/MatchCriteria.swift`. Origin: CR-8._

**C12. `UnitRect.clamped()` clamps components independently, allowing `x + width > 1`.** _Validated: still valid._ `UnitRect.swift:33-39` clamps each component separately, so x=0.95 and width=0.3 both survive and sum to 1.25, overhanging the target display in the proportional fallback. Clamp width to `1 - x` and height to `1 - y` after clamping the origin. `PutCoreTests.swift:24-29` only checks per-component clamping.

_`Sources/PutCore/UnitRect.swift`. Origin: CR-9._

**C13. Exact float equality in display lookup.** _Validated: still valid._ `DisplayProbe.visibleTopY` matches live screens with `bounds.origin == fingerprint.globalOrigin, bounds.size == fingerprint.pointSize` (`DisplayProbe.swift:49-50`), whereas `ScreenConfigMatcher.swift:18` uses `arrangementTolerance: CGFloat = 1.0` and `DisplayFingerprint.sameGeometry` (`DisplayFingerprint.swift:80`) uses a 0.001 epsilon. Three inconsistent tolerances; sub-integer CG origins would silently defeat the menu-bar clamp. Use the tolerant comparison.

_`Sources/PutDisplay/DisplayProbe.swift`. Origin: CR-10._

### Medium - UX

**C14. The Rules tab "+" button cannot capture the intended window.** _Validated: still valid; the partial fix neutralised the defect rather than fixing it._ The self-exclusion filter exists (`ActionCoordinator.swift:197`, `windows.filter { $0.descriptor.bundleID != Bundle.main.bundleIdentifier }`, guarded by `guard !windows.isEmpty` at `:198`), but frontmost resolution is unchanged (`WindowProbe.swift:35`, `guard let app = NSWorkspace.shared.frontmostApplication`) and that is always Put when Settings is key. So the "+" button (`RulesTab.swift:127-128`) and Cmd-N (`:133`) now filter Put out and do **nothing** rather than creating a bogus self-rule. Capture the previously active application (needs activation-history tracking), or prompt the user to focus the target window.

_`Sources/PutUI/Settings/RulesTab.swift`, `Sources/PutWindows/WindowProbe.swift`. Origin: F-M5 (remainder after partial fix)._

### Medium - structure, duplication, complexity

**C15. `ActionCoordinator` has clean split seams.** _Validated: still valid; file is now 700 lines (review said 678) and `save(windows:applyToAll:)` is 96 lines (`:192-287`)._ The function splits naturally into a rule-building `for handle in windows` loop (`:216-262`) and a persist/flash/notice/log tail (`:264-286`). The placement-history logic remains un-extracted and cohesive enough to become a `PlacementHistoryStore` collaborator: `prunePlacementHistory` (`:489`), `recordPlacement` (`:589`), `shouldSuppressAutoReplay` (`:611`).

_`Sources/PutAutomation/ActionCoordinator.swift`. Origin: CR-11._

**C16. Duplicated test fixtures, no shared support target.** _Validated: still valid; the review's counts were wrong._ No `PutTestSupport` target exists in `Package.swift`. Real counts: `makeStore` has 6 definitions (`AutoTriggerControllerTests.swift:72`, `ActionCoordinatorJumpTests.swift:77`, `AutoTriggerControllerWakeRetryTests.swift:66`, `ActionCoordinatorTests.swift:102` and `:596`, `PutStorageTests.swift:17`); `makeHandle` has 5; `makeFingerprint` has 3 (`ScreenConfigTests.swift:6`, `ScreenConfigMatcherTests.swift:9`, `DisplayMatcherTests.swift:9`). The double-definition-in-one-suite is `ActionCoordinatorTests`, not `AutoTriggerControllerTests`, and the fixtures span 8 suites, not six.

_Origin: CR-12._

**C17. `AboutTab` (SwiftUI) and `AboutWindow` (AppKit) are two full implementations of the same view.** _Validated: still valid._ `AboutTab.swift` (71 lines) and `AboutWindow.swift` (187 lines) duplicate font and layout constants - app name 28pt semibold at `AboutTab.swift:16` versus `AboutWindow.swift:106`, plus matching 11/13/12/10 sizes and spacing 14. Only `AboutInfo` (`AboutWindow.swift:29`) is shared, so the presentations will drift. Host `AboutTab` inside `AboutWindow` via `NSHostingView`.

_Origin: CR-13._

**C18. Launch-at-login logic duplicated.** _Validated: still valid, but across two sites, not three._ `GeneralTab.swift:48-53` inlines `try loginItem.setEnabled(newValue); state.config.launchAtLogin = loginItem.isEnabled; launchAtLoginError = nil` plus catch, and `OnboardingWizard.setLaunchAtLogin` (`OnboardingWizard.swift:238-246`) repeats it verbatim. The third "site" the review cited - the onboarding defaults toggle (`OnboardingWizard.swift:517-518`) - actually delegates via `set: { model.setLaunchAtLogin($0) }`, so it is a caller, not a copy. Unify `GeneralTab` on the view-model method.

_Origin: CR-14._

**C19. `RuleDetailForm` is an undecomposed 241-line view.** _Validated: still valid._ The `UnitRect`-from-absolute derivation is copy-pasted verbatim in the `displayBinding` setter (`:211-215`) and the `frameBinding` setter (`:233-237`). Extract one `recomputeNormalised` helper before they diverge, and split `placementForm` into its own view.

_`Sources/PutUI/Settings/RuleDetailForm.swift`. Origin: CR-15._

**C20. `RulesTab` persists on every keystroke with an O(rules) rescan.** _Validated: still valid._ `RulesTab.swift:170-172` fires `.onChange(of: currentRule) { _, new in ... persister.scheduleWrite() }` per keystroke, and `currentRule` (`:215-218`) rescans with `active.rules.first { $0.id == id }`. `LayoutsTab.swift:114-115` instead scopes persistence to `.onChange(of: binding.name.wrappedValue)`, a single tracked field. Persist on field-commit as `LayoutsTab` does.

_`Sources/PutUI/Settings/RulesTab.swift`. Origin: CR-16._

**C21. Repeated `DisplayChangeObserver` plus refresh `.task` blocks.** _Validated: still valid._ `RulesTab.swift:32-42` and `DisplaysTab.swift:34-44` are near-identical (`let observer = DisplayChangeObserver(); observer.start(); defer { observer.stop() }; for await event in observer.events where event == .configurationChanged`), and the refresh bodies share the idiom exactly: `RulesTab.swift:247` versus `DisplaysTab.swift:87`, both `(try? DisplayProbe.snapshot()) ?? []`. Extract a shared view modifier.

_Origin: CR-17._

### Low - polish

**C22.** _Validated: still valid._ `logDrift` serialises CGRects via `String(describing: target)` / `String(describing: actual)` (`ActionCoordinator.swift:640-641`) and emits them into both the log line and the `Window drifted` NDJSON `target`/`actual` metadata (`:655-656`), making the key diagnostic hard to parse. Use fixed numeric formatting. _`Sources/PutAutomation/ActionCoordinator.swift`. Origin: CR-18._

**C23.** _Validated: still valid._ `FileLog.rotateIfNeeded` calls `attributesOfItem(atPath:)` (`FileLog.swift:125`) on every `append` (`:60`); the only actor state is `handle` (`:30`), with no cached byte counter. Track bytes in-actor instead, for display storms. _`Sources/PutStorage/FileLog.swift`. Origin: CR-19._

**C24.** _Validated: still valid._ `FileLog` keeps writing to an unlinked inode after `put.log` is externally deleted. `ensureHandle` returns the cached handle immediately without revalidating the path (`FileLog.swift:106`), and `rotateIfNeeded` bails on `guard fileManager.fileExists(atPath:)` (`:124`), so rotation is permanently disabled and the inode grows unbounded. Writes keep succeeding, so no error path fires, and every diagnostic since deletion vanishes when the process exits. `FileLogTests` has no external-deletion test. _`Sources/PutStorage/FileLog.swift`. Origin: F-L2 (deferred, absent from CR)._

**C25.** _Validated: still valid._ Five `unsafeDowncast` AX sites are guarded only by an inline `CFGetTypeID`, with no shared helper: `WindowProbe.swift:42, 148, 157` and `WindowMutator.swift:361, 371`. Fold into one helper. _Origin: CR-21._

**C26.** _Validated: still valid._ `DisplayChangeObserver.deinit` teardown is provably unreachable. `start()` does `Unmanaged.passRetained(self)` (`DisplayChangeObserver.swift:42`), so the observer self-retains until `stop()` releases it and nils `retainedPtr` (`:57-58`); at `deinit` the guard `if let ptr = retainedPtr` (`:75`) can never be non-nil, making the branch (`:75-78`) dead code. The safety net the comment promises does not exist: an owner that drops the observer without `stop()` leaks it forever, leaves the CG callback registered, and never finishes the `AsyncStream`. All current owners pair `stop()` correctly, so this is latent. Fix or remove the branch. _`Sources/PutDisplay/DisplayChangeObserver.swift`. Origin: F-L3 (deferred, absent from CR)._

**C27.** _Validated: still valid._ `make lint` prints and continues when the tools are absent - `else echo "swiftlint not installed; skipping"` (`Makefile:182`) and the swiftformat equivalent (`:187`), neither with an `exit` - so it exits 0, whereas `make format` does `else echo "swiftformat not installed" && exit 1` (`:195`). Make `lint` fail too. _Origin: CR-23._

**C28.** _Open question, not a defect._ `.swiftlint.yml:86` sets `function_body_length: warning: 60`. The review claimed this contradicts a 50-line rule in `CLAUDE.md`, but the project `CLAUDE.md` states no such rule - the 50-line figure comes from the developer's global `~/.claude/CLAUDE.md`, which is not in the repo. There is no in-repo contradiction. Decide whether to tighten `.swiftlint.yml` to 50 to match the personal standard, or leave it. _Origin: CR-22 (premise corrected)._

## Remediation plan

_Planned 2026-07-10 against the validation pass above. Baseline on current `main`: `make test` passes (233 tests in 36 suites, ~1.1s); `make lint` exits 0 with 7 standing swiftlint warnings, all file/type/function length and complexity in `ActionCoordinator.swift` and `ActionCoordinatorTests.swift` - the C15 material. Every change below must leave `make lint` and `make test` green before merge. All 28 outstanding findings are accounted for; none is silently dropped._

### Ordering rationale

CI comes first (change 1). Every test written for changes 2-12 is worthless per-PR until something runs it, and C27 folds in because a runner without swiftlint would pass `make lint` silently - the two defects gate each other. The shared test-support target (C16) comes second because six copies of `makeStore` across eight suites tax every test the later changes add, and it is the prerequisite for standing up `PutUITests` (C9).

C5 lands before C3/C4. The busy-drop in C3 fires because blocking main-actor AX writes (up to ~0.7s of `Thread.sleep` per drifting window, serial) make in-flight restores routinely outlast the 1s trigger debounce. Fixing C3/C4 first would mean writing and testing the re-queue logic against a threading model that change 5 then replaces, forcing a second review of the same function. With C5 in place, busy-drops become rare but remain possible (concurrent triggers still collide - the per-app launch path's `.droppedBusy` case proves it), so C3/C4 stay necessary and their tests must simulate the collision deliberately rather than rely on timing.

C3 and C4 are one change: both live in `runSettledRestore` / `applyLayoutTriggersIfMatching`, the fix for C4 (activate only after a successful restore) determines what "result == nil" means for the C3 re-queue, and splitting them would produce two PRs each touching the same twenty lines.

The pure-function fixes (C2, C7, C11, C12) and the PutStorage pair (C1, C24, plus C23 in the same file) are early because they are cheap, test-first-able against existing suites, and independent of everything else. The C15 decomposition goes last of the ActionCoordinator work - refactoring a file while changes 5, 6, and 8 are landing bug fixes in it invites conflicts - and C28 rides with it, since tightening the lint threshold only makes sense once the 74-line offender is gone.

### Changes, in execution order

#### Change 1 - CI gate (C8, C27)

- **C8 fix:** Add a `ci.yml` workflow running `make lint` and `make test` on `pull_request` and on push to `main`, on a macOS runner with swiftlint and swiftformat installed via brew. Adopts the doc's direction. Keep `make test-ax` out of CI - runners have no Accessibility grant.
- **C8 blast radius:** `.github/workflows/` only; no source files. `release.yml` keeps its `workflow_dispatch` trigger untouched.
- **C8 test:** The workflow run is the verification: one scratch commit with a deliberate lint error must fail the check, then the real PR must pass.
- **C8 risk:** Runner toolchain mismatch with local Swift 6 / macOS 26. `make test` is hermetic so no TCC issues. Note the 7 standing swiftlint warnings: gate on exit code only (swiftlint exits 0 on warnings); tighten after change 9 clears them.
- **C27 fix:** In the Makefile `lint` target, replace both "not installed; skipping" branches (`Makefile:182`, `:187`) with `exit 1`, matching `format` (`:195`).
- **C27 blast radius:** `Makefile` only.
- **C27 test:** No unit test; verified manually (`PATH`-stripped invocation) and permanently by CI, which now fails if the tools are missing.
- **C27 risk:** Contributors without swiftlint installed are now blocked at `make lint`. Acceptable - `format` already behaves this way.

Depends on: nothing. Everything later depends on this for per-PR verification.

#### Change 2 - shared test support target (C16)

- **Fix:** Add a test-only `PutTestSupport` target to `Package.swift` (depending on PutCore, PutStorage, PutDisplay, PutWindows, PutAutomation) hosting shared `makeStore`, `makeHandle`, and `makeFingerprint` builders; point the eight suites at it and delete the local copies.
- **Blast radius:** `Package.swift` (all eight test-target dependency lists) plus the fixture sites: `makeStore` x6 (`AutoTriggerControllerTests.swift:72`, `ActionCoordinatorJumpTests.swift:77`, `AutoTriggerControllerWakeRetryTests.swift:66`, `ActionCoordinatorTests.swift:102` and `:596`, `PutStorageTests.swift:17`), `makeHandle` x5, `makeFingerprint` x3 (`ScreenConfigTests.swift:6`, `ScreenConfigMatcherTests.swift:9`, `DisplayMatcherTests.swift:9`). No production source.
- **Test:** No new behaviour - the existing 233 tests passing after the swap is the proof.
- **Risk:** The six `makeStore` definitions may differ deliberately (temp-dir handling, injected fakes). Reconcile into parameterised builders rather than forcing one shape; keep a thin per-suite wrapper where a variant genuinely differs, so no test's fixture semantics silently change.

Depends on: change 1 (so the swap is CI-verified). Unblocks C9 in change 12 and cheapens every test below.

#### Change 3 - pure-function guards (C2, C7, C11, C12)

All four are test-first against existing suites (`CoordinatesTests`, `PutCoreTests`); write the failing test, fix, verify.

- **C2 fix:** Guard `Coordinates.denormalise` with `max(pointSize.{width,height}, 1)`, symmetric with `normalise`. Adopts the doc's direction.
- **C2 blast radius:** `Sources/PutPlacement/Coordinates.swift`; callers `PlacementEngine.swift:60` (target display) and `:93` (fallback display). Behaviour changes only for zero-size displays.
- **C2 test:** `Tests/PutPlacementTests/CoordinatesTests.swift` - a zero-`pointSize` display must not denormalise to a 0x0 frame at the origin.
- **C2 risk:** A genuinely zero-size display still yields degenerate ~1pt frames; the guard removes the destructive collapse, it does not make placement on a transient display sensible. The upstream fidelity flag remains the real defence.
- **C7 fix:** In `Coordinates.displayContaining`, return nil when `global.isNull` or any component is non-finite, before the intersection loop.
- **C7 blast radius:** `Sources/PutPlacement/Coordinates.swift`; sole caller `PlacementEngine.swift:120` (capture path), which already handles the nil case from the empty-displays guard.
- **C7 test:** `CoordinatesTests` - null rect, infinite rect, and NaN-component rect each return nil rather than the primary display.
- **C7 risk:** Capture now fails closed on a garbage frame where it previously "succeeded" against primary. That is the intent; nothing else consumes the function.
- **C11 fix:** In `MatchCriteria.identityKey`, blank `axRole` in the branches where `RuleMatcher` ignores it: when `applyToAllWindows` and when `useTitlePatternExclusively` is true. Mirrors the existing title-pattern blanking.
- **C11 blast radius:** `Sources/PutCore/MatchCriteria.swift`; sole caller `ActionCoordinator.swift:246` (save-time dedupe). Existing duplicate rules in user configs are not retro-deduped - only future saves stop spawning them.
- **C11 test:** `PutCoreTests`, beside `identityKeyIgnoresTitlePatternWhenApplyToAll` (`:165`) - assert role is blanked in both branches and preserved when role is actually evaluated.
- **C11 risk:** Dedupe becomes more aggressive: two rules differing only by role under `applyToAllWindows` now collapse to one. That matches `RuleMatcher` semantics, which is the point.
- **C12 fix:** In `UnitRect.clamped()`, after clamping the origin, clamp width to `1 - x` and height to `1 - y`. Adopts the doc's direction.
- **C12 blast radius:** `Sources/PutCore/UnitRect.swift`; sole caller `PlacementEngine.swift:124` (proportional fallback).
- **C12 test:** `PutCoreTests.swift` beside the per-component test (`:24-29`) - x=0.95, width=0.3 must yield width 0.05.
- **C12 risk:** Rules whose normalised rect legitimately overhangs (window larger than the saved display) now shrink on proportional fallback instead of overhanging the target. Shrinking on-display beats placing off-display, but it is a visible behaviour change for oversized windows - note it in the changelog when it lands.

Depends on: change 1. Independent of everything else.

#### Change 4 - PutStorage durability (C1, C24, C23)

- **C1 fix:** Restructure `ConfigStore.save`: try `replaceItemAt` first with no pre-remove; only on failure, and only when `backupTaken`, remove the original and `moveItem` the temp into place; when the backup failed, abort the save with an error, leaving the old config intact, rather than risk zero copies. The worst-case branch at `:137` stops deleting `tempURL` when it is the only surviving copy. Teach `load()` to fall back to `config.json.backup` when `fileURL` is missing or undecodable, before quarantining. Adopts both halves of the doc's direction.
- **C1 blast radius:** `Sources/PutStorage/ConfigStore.swift` only; callers (`ConfigPersister.swift:36`, `:50`, `ActionCoordinator.swift:395`, `PutApp.swift:167`) see no API change.
- **C1 test:** The existing test concedes it cannot simulate replace/move failure, so introduce a minimal injectable file-operations seam (protocol wrapping the three FileManager calls, defaulting to FileManager) and drive each failure combination in `PutStorageTests`, asserting at least one intact copy survives every branch. Plus a straightforward load-side test: delete `config.json`, keep the backup, assert `load()` recovers it. Write the failing tests first.
- **C1 risk:** This is the config-loss path - the atomic tmp+replace shape and the 0600 perms on file and parent must survive the restructure; the new tests and the existing perms/quarantine tests are the guard. The seam must stay internal so the public actor API is unchanged.
- **C24 + C23 fix (one design, same actor):** Replace the per-append `attributesOfItem` (`FileLog.swift:125`) with an in-actor byte counter seeded from the handle at open (C23). Revalidate path existence on a coarse cadence (every N appends) and at rotation-threshold checks; when the file is gone, close the stale handle, recreate the file, and reset the counter (C24), so `rotateIfNeeded` never permanently disables itself.
- **Blast radius:** `Sources/PutStorage/FileLog.swift` only; `append` callers (`PutApp.swift:226`, `ActionCoordinator.swift:275`, `:282`, `:375`, `:403`, `:648`) unaffected.
- **Test:** `FileLogTests` - external-deletion test (delete `put.log`, append past the revalidation cadence, assert a fresh file exists and receives writes; make the cadence injectable so the test does not loop thousands of appends) and a rotation test asserting the byte counter still triggers rotation at the threshold. Failing tests first.
- **Risk:** This is the hot path during display storms - keep per-append cost O(1). Counter drift versus real file size is only possible with an external writer, which does not exist; seed from `fstat` at open to be safe.

Depends on: change 1. Independent of everything else.

#### Change 5 - restore-path threading (C5, C10)

- **C5 fix:** Route `applyPlacement` -> `performWrite` (`ActionCoordinator.swift:493-560`) through `await Task.detached(priority: .userInitiated)` exactly as `AutoTriggerController.tryFulfil` already does (`:396-410`), re-entering the main actor only for state mutation (drift recording, placement history). Writes stay serial per window - only the executor changes. Adopts the doc's direction.
- **C5 blast radius:** `Sources/PutAutomation/ActionCoordinator.swift`; callers of `restoreAllWindows` (`MenuBarController.swift:306`, `PutApp.swift:253`, `:318`, `AutoTriggerController.swift:274`, `:321`, `:535`) are already async call sites and see no signature change.
- **C5 test:** `PutAutomationTests` with the injected fake `WindowMutating` recording `Thread.isMainThread` per call; the new test asserts writes run off the main thread. It fails today - test-first.
- **C5 risk:** Two documented gotchas sit adjacent. `WindowMutator.applyOnce` must keep ending in `setSize` in both branches - this change must not reorder the write sequence, only relocate it. And the `beginRestore`/`endRestore` in-flight flags stay main-actor so two restores cannot interleave through the detached region. AX enumeration blocking on XPC is precisely why the detach exists; the pattern is already proven in `tryFulfil`.
- **C10 fix:** Hop the NSScreen enumeration back to the main actor: annotate `DisplayProbe` `@MainActor` (its own doc comment says it was written for main-thread use) and split the detached probes so displays are snapshotted on the main actor before detaching for the AX window probe. Departs slightly from the doc's "or capture the screen index before detaching" alternative - the annotation makes the invariant compile-checked rather than conventional.
- **C10 blast radius:** `Sources/PutDisplay/DisplayProbe.swift`; off-main call sites `ActionCoordinator.swift:428` (`probeDisplaysOffMain`) and `AutoTriggerController.swift:299`, `:359` (`probeDisplaysAndWindows` splits into main-actor display snapshot + detached window probe). Main-actor UI call sites (`RulesTab.swift:247`, `DisplaysTab.swift:87`, `LayoutScreenConfigSection.swift:136`) already comply. `PutDisplayTests` and `IntegrationTests` suites touching the probe need `@MainActor` annotations.
- **C10 test:** The `@MainActor` annotation is the proof - off-main use becomes a compile error, which is stronger than any runtime assertion. Existing suites passing after annotation is the regression check.
- **C10 risk:** Display snapshots move onto the main thread during display storms; CGDirectDisplay + NSScreen reads are cheap, and net main-thread cost still drops sharply because C5 removed the sleeps.

Depends on: change 1. Must precede change 6 (see rationale above).

#### Change 6 - trigger loss and activation ordering (C3, C4)

One change; same two functions.

- **C4 fix:** In `applyLayoutTriggersIfMatching`, move `onActivateLayout?(match.layoutID)` - or at minimum the persistence of `activeLayoutID` - to after a non-nil restore result, and make the returned `fired` reflect whether the layout was actually applied. Adopts the doc's direction.
- **C3 fix:** In `runSettledRestore`, when `restoreAllWindows` returns nil (busy-drop), re-insert the consumed reasons into `pendingReasons` and re-arm the debouncer, mirroring the per-app path's explicit `.droppedBusy` handling (`:476-477`). Adopts the doc's direction.
- **Blast radius:** `Sources/PutAutomation/AutoTriggerController.swift` - `runSettledRestore` (`:222`), `applyLayoutTriggersIfMatching` (`:294`), `scheduleCorrectiveRetryIfNeeded` (`:504`). One external caller: `PutApp.swift:250` invokes `applyLayoutTriggersIfMatching` on launch - it must still activate the layout on a successful launch restore, which the reordering preserves.
- **Test:** `AutoTriggerControllerTests` (existing harness with injected fakes). Three failing tests first: a busy-dropped settled restore re-queues its reasons and a later pass fires without a new external trigger; layout activation does not persist when the restore is dropped busy; activation still persists on success (regression guard for the launch path).
- **Risk:** Re-queue can ping-pong if restores are persistently busy - bound it by the existing debounce interval and the corrective-retry cap rather than adding a new mechanism. The menu-bar active-layout checkmark now updates after the restore instead of before it; a visible but correct timing change.

Depends on: change 5 (threading model must be final first) and change 1.

#### Change 7 - display matching robustness (C6, C13)

- **C6 fix:** Pair by per-instance handle rather than fingerprint id string: `ScreenConfigMatcher.evaluate` consumes candidates by index (so identical twins stop excluding each other), and `DisplayMatcher`'s vendor+product `first(where:)` gains a geometry tie-break (prefer the candidate whose `globalOrigin`/`pointSize` matches) that only activates when multiple candidates share a fingerprint id. This is the doc's second option; the first (reject duplicate ids up front) would make exact-match twin configurations permanently unmatchable, which is the defect, not a fix. Full backtracking is not worth the complexity - the tie-break covers the crosswise case.
- **Blast radius:** `Sources/PutDisplay/ScreenConfigMatcher.swift` (`:33-42`), `Sources/PutDisplay/DisplayMatcher.swift` (`:66-70`). `DisplayMatcher` is also on the rule-placement path, so the tie-break affects rule display resolution for twin displays; distinct-display behaviour is unchanged because the tie-break only engages on duplicate ids. `ScreenConfigMatcher.evaluate`'s one caller is `LayoutTriggerEvaluator.swift:31`.
- **Test:** `ScreenConfigMatcherTests` and `DisplayMatcherTests` - twin displays (same vendor/product, nil serial, nil UUID) in an exact configuration must match; a crosswise arrangement must pair by geometry and pass `arrangementsAlign`. The doc notes no twin case exists today; write them failing first.
- **C13 fix:** Replace the exact `==` comparisons in `DisplayProbe.visibleTopY` (`:49-50`) with `DisplayFingerprint.sameGeometry`'s epsilon comparison. Adopts the doc's direction.
- **C13 blast radius:** `Sources/PutDisplay/DisplayProbe.swift`; sole caller `ActionCoordinator.swift:602` (menu-bar clamp).
- **C13 test:** `visibleTopY` reads NSScreen live with no injection point, so extract the fingerprint-vs-bounds comparison into a pure helper and unit-test that in `PutDisplayTests` with sub-integer origins. No AX-gated test needed once the comparison is pure.
- **C13 risk:** Negligible - the epsilon is orders of magnitude below any real display offset.

Depends on: change 1. Independent of everything else.

#### Change 8 - diagnostics and dead-code polish (C22, C25, C26)

Order-independent, but lands before change 9 because C22 touches `ActionCoordinator.swift`.

- **C22 fix:** `logDrift` formats CGRects via a fixed numeric formatter (one decimal place per component) instead of `String(describing:)`, in both the log line and the NDJSON `target`/`actual` metadata (`ActionCoordinator.swift:640-656`).
- **C22 test:** A small formatting-helper test in `PutAutomationTests` asserting the output shape is stable and parseable.
- **C22 risk:** None beyond changing the NDJSON field format; nothing parses it programmatically today, and the change is why it becomes parseable.
- **C25 fix:** One shared generic helper wrapping the `CFGetTypeID`-then-`unsafeDowncast` idiom; fold in the five sites (`WindowProbe.swift:42`, `:148`, `:157`, `WindowMutator.swift:361`, `:371`).
- **C25 test:** No new behaviour; hermetic suites do not exercise AX paths, so the existing `make test-ax` suites cover it under `PUT_RUN_AX_TESTS=1`.
- **C25 risk:** Mechanical; keep the helper in PutWindows so no new cross-module dependency appears.
- **C26 fix:** Remove the provably dead `deinit` branch and its misleading safety-net comment in `DisplayChangeObserver` (`:75-78`); `stop()` is the required teardown and all three owners (`RulesTab.swift:36-38`, `DisplaysTab.swift:38-40`, `AutoTriggerController.swift:81/:112/:179`) already pair it. "Fix" is not available - the `passRetained` self-retain means `deinit` cannot run while the callback is registered, so the branch can only ever be dead.
- **C26 test:** None practical (deinit of a self-retained object is unreachable by construction); the existing retain/release balance checks stand.
- **C26 risk:** None; removing dead code only.

Depends on: change 1.

#### Change 9 - ActionCoordinator decomposition (C15) and lint threshold (C28)

- **C15 fix:** Split `save(windows:applyToAll:)` (`:192-287`) along the doc's seams - the rule-building loop and the persist/flash/notice/log tail become private helpers - and extract the placement-history trio (`prunePlacementHistory:489`, `recordPlacement:589`, `shouldSuppressAutoReplay:611`) into a `PlacementHistoryStore` collaborator. Adopts the doc's direction.
- **C15 blast radius:** `Sources/PutAutomation/ActionCoordinator.swift` internals only; no caller sees a signature change. `ActionCoordinatorTests` fixtures may need the new collaborator injected.
- **C15 test:** No behaviour change, so the 233 existing tests are the primary guard; add `PlacementHistoryStore` unit tests for the suppression-window edge cases now that the logic is independently constructible. This change also clears all 7 standing lint warnings.
- **C15 risk:** Pure refactor in the file changes 5, 6, and 8 just modified - hence its position. Extraction must not move any AX-touching code back onto the main actor (preserve the change-5 threading).
- **C28 decision: do it, here.** Tighten `.swiftlint.yml` `function_body_length` warning from 60 to 50 to match the developer's standard. Doing it earlier would add a standing warning on the 74-line `save()` and train everyone to ignore lint output; after C15 the offenders are gone and the change is one line at zero cost. If post-C15 code still trips 50 somewhere, split the function rather than raising the threshold back.

Depends on: changes 5, 6, 8 (same file). C28 half depends on the C15 half.

#### Change 10 - Rules tab "+" capture (C14)

- **Fix:** Add a small `@MainActor` activation-history observer (in PutWindows, beside `WindowProbe`) tracking `NSWorkspace.didActivateApplicationNotification`; `WindowProbe` gains a focused-window-for-pid variant (`AXUIElementCreateApplication(pid)` + `kAXFocusedWindowAttribute`); `ActionCoordinator.saveFocusedWindow*` (`:75`, `:92`, `:109`) uses the previously active app when Put itself is frontmost, and falls back to prompting the user to focus the target window when history is empty. This is the doc's first option with its second as the fallback.
- **Blast radius:** `Sources/PutWindows/WindowProbe.swift` (new pid-targeted lookup; note `frontmostAppWindows()` at `:28` currently has no callers - fold or remove it while here), `Sources/PutAutomation/ActionCoordinator.swift` (the three `saveFocusedWindow*` entry points), `Sources/PutUI/Settings/RulesTab.swift:127-133` ("+" button and Cmd-N), plus wiring the observer at startup in `PutApp`/`AppDelegate`.
- **Test:** Activation-history logic is hermetic with an injected `NotificationCenter` - unit tests in `PutWindowsTests`. The end-to-end capture (focused window of a real app by pid) is AX-dependent: gate with `.disabled(if:)` and `PUT_RUN_AX_TESTS` in `Tests/PutWindowsTests`, never `#require`. Failing hermetic test first: with Put frontmost and a recorded prior activation, capture resolves the prior app, not Put.
- **Risk:** The pid-targeted AX lookup blocks on XPC like every AX read - it must follow the established `Task.detached` pattern (post-change-5 convention). `NSWorkspace` notifications arrive on the main thread, so the history stays `@MainActor`. This is the largest behavioural change in the plan, which is why it sits after the mechanical work.

Depends on: changes 1 and 5 (threading convention). Independent of the UI changes below.

#### Change 11 - PutUI dedupe (C17, C18, C21)

Mechanical deduplication, no behaviour change.

- **C17 fix:** Host `AboutTab` inside `AboutWindow` via `NSHostingView`, deleting `AboutWindow`'s duplicate layout. Adopts the doc's direction.
- **C17 blast radius:** `Sources/PutUI/AboutWindow.swift`; `PutApp.swift:387` (`showAbout`) keeps constructing `AboutWindow`; `SettingsView.swift:59` keeps `AboutTab`. `AboutInfo` stays the shared model.
- **C17 test:** No extractable logic; visual parity is a manual QA item (there is no QA matrix doc in the repo, so check the About window by hand).
- **C17 risk:** `PutCore.Layout` must stay fully qualified in any SwiftUI file touched - the collision gotcha applies to every file in this change and change 12.
- **C18 fix:** Extract the `setEnabled` + sync-config + clear-error pattern into one shared helper (on `AppState` or a small `LoginItemToggling` type in PutAutomation); `GeneralTab.swift:48-53` and `OnboardingWizard.setLaunchAtLogin` (`:238-246`) both call it. The third `setEnabled` caller, `PutApp.swift:560`, is a startup sync with different semantics - leave it alone.
- **C18 test:** The helper is hermetic with an injected `LoginItemController` fake; unit test both the success and the error-message path.
- **C21 fix:** Extract the repeated observer-plus-refresh idiom (`RulesTab.swift:32-42`, `DisplaysTab.swift:34-44`, refresh at `RulesTab.swift:247` / `DisplaysTab.swift:87`) into a shared `onDisplayConfigurationChange` view modifier in PutUI.
- **C21 test:** The modifier is a thin async-stream consumer; covered indirectly by both tabs continuing to compile and behave. No dedicated test - there is no logic to assert beyond "calls the closure per event", which a hermetic test can cover if the observer is injectable; make it so.
- **C21 risk:** The modifier must preserve the `defer { observer.stop() }` pairing - C26 established that a dropped observer without `stop()` leaks the CG callback.

Depends on: change 1. Change 12 builds on its extractions.

#### Change 12 - PutUI behaviour and tests (C19, C20, C9)

- **C19 fix:** In `RuleDetailForm`, extract one `recomputeNormalised` helper for the duplicated `UnitRect`-from-absolute derivation (`:211-215`, `:233-237`) and split `placementForm` into its own view. Adopts the doc's direction.
- **C19 test:** `recomputeNormalised` is pure - unit test it in the new `PutUITests` with a display fingerprint and an absolute frame.
- **C20 fix:** Scope `RulesTab` persistence to field-commit as `LayoutsTab` does (`LayoutsTab.swift:114-115`), replacing the per-keystroke `.onChange(of: currentRule)` (`:170-172`) and its O(rules) rescan (`:215-218`).
- **C20 test:** Extract the "which mutations schedule a write" decision into a testable function if practical; otherwise the behaviour is a manual QA item (typing in the title field must not write config.json per keystroke - observable via the persister's write counter in a hermetic test with an injected `ConfigPersister` spy).
- **C20 risk:** Under-persisting - a field that no longer triggers a write on any path loses data on quit. `applicationShouldTerminate` already flushes the persister (R3), which bounds the damage to crash-only loss; test the commit paths explicitly.
- **C9 fix:** Stand up `Tests/PutUITests` (depending on `PutTestSupport`) and extract the testable state-derivation logic from `MenuBarController` (menu item state), `OnboardingWizard` (step progression, `setLaunchAtLogin` via the change-11 helper), and the settings tabs into plain types with unit tests. Scope deliberately: view-model and formatting logic, not view rendering - 3,022 lines of SwiftUI body code is not the target, the logic buried in it is.
- **C9 blast radius:** `Package.swift` (new test target), the PutUI files logic is extracted from, and no behaviour change if the extraction is faithful.
- **C9 risk:** Extraction refactors in `@MainActor` SwiftUI files - the `PutCore.Layout` qualification gotcha again, and `DispatchSource` (not `Timer`) for anything timed, per the `OnboardingWindowController` precedent.

Depends on: change 2 (`PutTestSupport`) and change 11 (its extractions). Last in the plan; C9 can continue incrementally after the first PR establishes the target.

### Deferred or dropped

Nothing is dropped. C28 is decided above (do it, inside change 9). The three refuted claims stay refuted; no work is planned for them. Change 12's C9 is the only open-ended item - it lands as an initial target-plus-first-tests PR with the remaining extraction proceeding incrementally, rather than pretending one PR reaches 80% coverage of a 3,022-line module.

## Previously fixed - regression check passed

Actioned in the 2026-06-11 follow-up pass. The 2026-06-18 review did not re-check them; the 2026-07-10 validation pass confirms all seven are still present.

- **R1 (F-M1).** `ConfigStore.load()` quarantines on any decode/migrate failure via a catch-all (`ConfigStore.swift:61`, `:70`, `:83`), moving the file aside as `config.corrupt-*.json`. Test `futureSchemaVersionQuarantinesAndBootstraps` still exists (`PutStorageTests.swift:95`).
- **R2 (F-M3).** `AutoTriggerController` injects `mutator: any WindowMutating = DefaultWindowMutator()` (`:83`); `tryFulfil` branches on `restoresPosition` (`:400`) and logs failed writes (`:411-417`) rather than swallowing them.
- **R3 (F-M4).** `applicationShouldTerminate` (`PutApp.swift:263`) awaits `persister.flush()` (`:266`), replies (`:267`), and returns `.terminateLater` (`:269`).
- **R4 (F-M5, partial).** `ActionCoordinator.swift:197` filters out `Bundle.main.bundleIdentifier`. Remainder tracked as C14.
- **R5 (F-M6).** `LoginItemController` adds (`:36`) and removes (`:50`) its observer on `NotificationCenter.default`.
- **R6 (F-L5).** `WindowMutator` throws `AXOperationError.elementGone` on readback failure in `setFrame` (`:91-92`) and `setSize` (`:151-152`).
- **R7 (F-L7).** `showSettings` guards `state != nil, coordinator != nil, persister != nil, loginItem != nil` (`PutApp.swift:362`).

## Confirmed sound - no action

- `DisplayChangeObserver` retain/release balance and lock discipline.
- `RuleMatcher` regex fail-closed semantics.
- `DisplayMatchQuality` ordering and the `<= .equivalent` found contract.
- `WindowMutator.applyOnce` ending both branches in `setSize`.
- `AccessibilityTrust.promptIfNeeded` idempotency.
- No force unwraps, no `try!`/`as!`, no TODO/FIXME debt, no SwiftUI retain cycles, timers use `DispatchSource`.

## Refuted on validation

Recorded so a future review does not resurrect them.

- **`ConfigStore.migrate` has no lower bound** (CR-20). Factually accurate - `ConfigStore.swift:154` guards only the upper bound, and the else branch (`:164-165`) stamps any lower value, including 0 or negative, forward to `putSchemaVersion`. But this is the deliberate "anything below current is an upgradable old version" behaviour, locked in by a passing test that writes `schemaVersion = 0` and asserts it is stamped forward (`PutStorageTests.swift:81-91`). Stamping a nonsensical version forward loses no data. No defect.

- **Reasons repopulated mid-await are never rescheduled** (CR-3, first half). The premise fails. The only path that repopulates `pendingReasons` is `scheduleSettledRestore`, which re-arms the debouncer in the same synchronous main-actor call: `pendingReasons.insert(reason)` immediately followed by `debouncer.schedule { ... await runSettledRestore() }` (`AutoTriggerController.swift:215-219`). An event arriving during the `applyLayoutTriggersIfMatching` await both repopulates the set and schedules a fresh pass. The busy-drop half of the finding survives as C3.

- **FlashPanel missing `isReleasedWhenClosed = false`** (`Sources/PutUI/SaveFlashPresenter.swift`, refuted in the 2026-06-11 pass). Claimed over-release on every save flash. `NSPanel`, unlike `NSWindow`, defaults `isReleasedWhenClosed` to false, verified empirically on macOS 26. The explicit assignments elsewhere are on `NSWindow` instances, where the default genuinely is true. No defect.
