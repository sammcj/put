# Changelog

<!-- AI agents: add entries under the ## [Unreleased] header. Do NOT add version numbers or dates. Do NOT duplicate headings. The ## Known Bugs section must always stay pinned above ## [Unreleased]. Group entries under ### Added, ### Changed, ### Fixed, or ### Removed. Combine or update items refined within the same session. If the file exceeds 2000 lines, truncate the oldest releases. -->

All notable changes to Put are recorded here. The format follows Keep a
Changelog; versions use SemVer.

## Known Bugs

## [Unreleased]

## [0.2.0] - 2026-07-28

### Added

- CI workflow (`.github/workflows/ci.yml`) that runs `make lint` and `make test`
  on every pull request and on push to `main`, so style, file-length, and
  complexity violations no longer reach `main` ungated. Runs on a `macos-26`
  runner because the package's macOS 26 deployment target needs the Xcode 26
  SDK. AX-dependent tests are excluded because hosted runners have no
  Accessibility grant.
- One-click recovery for windows stranded on another Space. After a sleep/wake
  reflow, macOS can collapse a display's Spaces and exile a managed window onto
  a non-active Space where the Accessibility API can't reach it, so Put silently
  can't move it back (cross-Space moves need SIP disabled). Put now detects this
  - an enabled position-restoring rule whose app is running with a window on
  another Space (via the all-Spaces window list, which distinguishes an exiled
  window from a closed one) but none reachable here - and surfaces an "On
  another Space" section in the menu bar. Picking "Recover <app>" activates the
  app to bring the window into reach, then re-places it onto its saved display.
- New "Save Size Only" actions in the menu bar. The main menu gains a "Save Size
  Only" submenu (focused window all-app, focused window this-title-only, all
  windows) and each app's submenu under "Apps" gains "Save All Windows (Size
  Only)". These create rules that restore size but leave the window where it
  sits. The origin is still captured, so position restore can be re-enabled
  later from the Rules tab without resaving.
- The Rules tab now shows - and lets you switch - which layout you're editing,
  via a layout picker above the rules list. The list, the new-rule button, and
  the detail editor all follow the selection. Switching here is the same
  side-effect-free active-layout change as the Layouts tab (no restore fires).
- Saving now respects the active layout's screen scope. A window on a monitor
  that isn't part of the active layout's screen configuration (e.g. saving
  while docked into a laptop-only layout) is no longer stamped into that layout
  as a rule targeting the foreign display - which previously created rules that
  couldn't restore once the monitor was gone. The skipped windows are reported
  in a notice naming the layout and the monitor, so the save isn't silent.
  Layouts with no screen configuration (hotkey-only) are unaffected.
- `Tests/PutUITests`, the first PutUI test target, covering the extracted
  state-derivation logic: `RuleEditPersistence` (which edits persist and when),
  `RulePlacementForm.recomputeNormalised`, `MenuBarModel` (jump-title and
  active-layout menu state), `OnboardingWizardController.Step` progression, and
  `RulesTab.subtitle` formatting. View rendering is out of scope; extraction of
  further PutUI logic continues incrementally.
- Return-to-machine restores now fire on screen wake and unlock, not just full
  system sleep/wake. Put observes `screensDidWakeNotification` (display-idle
  wake, where the system never slept) and the screen-unlock notification, so the
  saved layout is reasserted when you come back to a machine that only slept its
  display or sat on the lock screen. These fold into the same debounce as the
  existing wake trigger, so a full wake still runs a single restore.
- `docs/fable-review-1.md`: validated full-codebase review. 15 confirmed
  findings (2 high, 5 medium, 8 low) with an action checklist; 1 finding
  refuted during validation.
- Settings backup. Settings → General → Backup exports every setting (layouts,
  rules, hotkeys, and preferences) to a single JSON file, and imports one back.
  Import warns that it replaces all current settings before applying. The whole
  `Config` is embedded verbatim and global hotkeys are derived from
  `GlobalHotkeyName`, so new settings are captured by backups automatically.
- Menu bar gains a "Jump to Window" submenu listing the active layout's rules.
  Picking one raises the first live window that matches and lets macOS switch
  to whichever Space the window is on. This is navigation only (public
  Accessibility) - no window is moved between Spaces, sidestepping the private
  SkyLight APIs that forced relocation would require. Groundwork for optional
  Space-aware behaviour.
- Dev-only `PutSpaceProbe` executable (`swift run PutSpaceProbe`) prints the
  per-screen desktop-picture URL and the on-screen app set on an interval, to
  measure whether wallpaper tracks per-Space and how stable the on-screen app
  set is as a Space fingerprint. Not part of the shipped app.
- A layout can now hold more than one screen-configuration trigger, so it
  auto-activates across several monitor arrangements (for example the same
  layout firing whether you're docked at one desk or another). Settings →
  Layouts shows each captured configuration as its own row with independent
  "auto-activate" and "match arrangement exactly" toggles and a Remove button,
  plus an "Add current configuration" button. Re-capturing a configuration a
  layout already holds refreshes it in place. A configuration still belongs to
  at most one layout; capturing one already claimed elsewhere prompts to move
  it. Config schema bumps to 3; older single-trigger configs migrate
  automatically on load.
- Settings → Layouts gains a "Duplicate" button that copies the selected
  layout (rules and all) under a "COPY OF <name>" name and focuses the name
  field so the user can rename immediately. The activation hotkey and
  screen-config trigger are intentionally left unset on the copy to avoid
  clashing with the original.
- Rule editor gains a "Clear position" button next to the X/Y fields.
  Clearing position turns the rule into a size-only restore: the matched
  window is resized but its current screen position is left as-is. The
  saved X/Y values are retained so "Set position" restores the previous
  behaviour without losing them. Existing rules default to restoring
  position, matching prior behaviour.
- Settings → General gains a "Leave windows I've moved alone" toggle (on by
  default). When on, once Put has placed a window it won't be snapped back if
  you move or resize it; the window is left alone until the display layout
  changes or you restore it manually. Turn it off for the old "always
  re-apply the saved position" behaviour.

### Changed

- `Package.swift` is now covered by `make lint` and `make format`. The manifest
  sat outside both, so style drift there was invisible to CI.
- Test doubles for the window probe, window mutator and accessibility gate moved
  into `PutTestSupport`. Every automation suite kept its own near-identical copy,
  differing only in which calls it recorded, and the copies had started to
  diverge. Genuinely specialised doubles stay local to their suite.
- The Settings window titlebar is now transparent with the title hidden, so the
  tab bar sits directly under the traffic lights instead of below a redundant
  "Put Settings" band.
- Test fixtures now live in a shared `PutTestSupport` target rather than being
  copied across eight suites. The `makeStore`, `makeHandle`, and
  `makeFingerprint` construction bodies are centralised there; each suite keeps a
  thin wrapper carrying its own defaults, so no test's fixture semantics change.
- The five Accessibility read sites in `WindowProbe` and `WindowMutator` that
  guarded an `unsafeDowncast` with an inline `CFGetTypeID` now share one
  `axDowncast` helper. No behaviour change.
- The standalone About window now hosts the shared SwiftUI `AboutTab` via
  `NSHostingView` instead of a second, hand-written AppKit layout, so the About
  window and the Settings About tab can no longer drift apart. No behaviour
  change.
- The launch-at-login toggle logic (write through, mirror into config, clear
  error, schedule persist) is now one `AppState.applyLaunchAtLogin` helper that
  both the General tab and the onboarding wizard call, replacing two verbatim
  copies. No behaviour change.
- The Rules and Displays tabs now share one `onDisplayConfigurationChange` view
  modifier for their display-observer refresh loop, replacing two near-identical
  copies. The modifier keeps the observer's `start()`/`stop()` pairing so the
  CoreGraphics reconfiguration callback can't leak. No behaviour change.
- Removed the unreachable `deinit` teardown branch in `DisplayChangeObserver`.
  `start()` self-retains the observer via `passRetained`, so `deinit` cannot run
  until `stop()` releases it and clears the pointer, leaving the branch provably
  dead; `stop()` stays the required teardown and all owners already pair it.
- Decomposed `ActionCoordinator.save` into `buildRules`, `upsert`, `finishSave`,
  and `notifyOutOfScope` helpers (now in `ActionCoordinator+Save.swift`), and
  extracted the per-window placement-history cache into a standalone
  `PlacementHistoryStore` collaborator with its own suppression-window unit
  tests. The detached off-main AX write path and the main-actor `DisplayProbe`
  read are unchanged; no behaviour change.
- Tightened the SwiftLint `function_body_length` warning threshold from 60 to 50
  lines to match the standing 50-line function limit. Two incidental functions
  that were sitting between the old and new thresholds (`AboutWindow.makeContent`
  constraint block and `PutApp.bootstrap` hotkey/menu-bar wiring) were split into
  helpers rather than exempted.
- The Rules tab's persist-on-edit decision moved into a testable
  `RuleEditPersistence` type. Any edit to the selected rule schedules a write;
  the write is debounced (`ConfigPersister`, 400ms) so a keystroke burst still
  collapses into a single write, and a selection change (navigating to a
  different rule) doesn't write. No behaviour change from the prior debounced
  persistence.
- Split `RuleDetailForm` into the match-criteria form and a new
  `RulePlacementForm` (display, saved frame, preview), and extracted one
  `recomputeNormalised` helper for the `UnitRect`-from-absolute derivation that
  was copy-pasted across the display and frame bindings. No behaviour change.
- Auto-trigger restores now respect a manually moved or resized window
  durably, rather than for a fixed 30-second window after placement.
  Previously the window would snap back on the next wake or app launch once
  the 30s lapsed. Suppression now persists until the rule resolves to a
  different target (for example a display is connected or removed, which makes
  the saved geometry authoritative again) or the user restores manually.
  Detection also covers resizes, not just moves, so a window grown from a
  corner that keeps its origin fixed is no longer re-applied. Gated by the new
  "Leave windows I've moved alone" setting.
- Automatic-restore timing constants (event debounce, wake retry, app-launch
  retry schedule) are gathered into a single documented `RestoreTiming` type
  to make the clock-driven behaviour easy to find when debugging.

### Fixed

- The per-window placement history is now bounded. Pruning only runs on a full
  restore, so someone whose only enabled trigger is app launch never pruned at
  all: records for windows that had since closed accumulated for the life of the
  process, each one retaining a dead Accessibility element. Recording now evicts
  the least recently placed entries once the cache passes its ceiling.
- `make lint` passes again on SwiftFormat 0.62, which enabled two if-body
  wrapping rules by default. They would have rewritten every single-line guard in
  the codebase, so both are disabled in `.swiftformat`. That also stops lint
  results depending on whichever formatter version a machine or CI runner
  happens to install.
- The Rules tab "+" button (and Cmd-N) now captures the window you were last
  using instead of doing nothing. Pressing it makes a Put window frontmost, so
  the capture used to resolve Put's own Settings window and then drop it via the
  self-exclusion filter, creating no rule. Put now tracks the app that was
  active before its window took focus and captures that app's focused window by
  pid. When no prior app is known, or its focused window can't be read, it asks
  you to click the target window and try again rather than failing silently.
- Auto-trigger restores that collide with an in-flight restore are no longer
  lost. When a settled display/wake pass found a restore already running, its
  reason batch was cleared and silently dropped until an unrelated future
  trigger. It now re-queues the reasons and re-arms the debouncer so the pass
  runs once the coordinator frees up, bounded by the existing consecutive-drop
  cap so a persistently busy coordinator can't ping-pong forever.
- A screen-config layout trigger no longer activates a layout it never applied.
  Activation was switched and persisted before the restore ran, so a
  busy-dropped restore left the user on a newly activated layout with nothing
  placed. Activation now persists only after the restore lands; a dropped
  restore reverts the in-memory switch and re-queues, and launch-time activation
  still persists on a successful launch restore. Because the restore awaits
  off-main writes, the deferred activation and the busy-drop revert only touch
  `activeLayoutID` while it still holds the matched layout, so a layout the user
  picks from the menu mid-restore is no longer silently reverted.
- Restore no longer freezes the menu bar during display storms. The AX write
  loop (which sleeps up to ~0.7s per drifting window while retrying) ran
  synchronously on the main actor; it now runs off-main in a detached task,
  re-entering the main actor only to record the outcome. Writes stay serial per
  window and the setFrame-then-setSize order is unchanged.
- Display enumeration during a restore is now done on the main actor.
  `DisplayProbe` reads `NSScreen`, which is main-thread state; probing it from a
  detached task during a reconfiguration could return stale or empty results and
  defeat geometry matching, forcing an unnecessary proportional remap. The probe
  is now `@MainActor` so the invariant is compile-checked, and only the AX window
  probe (which blocks on XPC) stays detached.
- Identical twin displays (same vendor and product, no serial or UUID) now match
  their saved screen configuration. Pairing consumed candidates by fingerprint
  id, and twins share one id, so pairing the first twin removed both from the
  pool and forced a no-match on an exact configuration. Pairing now consumes by
  per-instance display index instead. Crosswise twin arrangements also resolve
  correctly: `DisplayMatcher` now breaks a vendor+product tie by geometry
  (preferring the candidate whose origin and size match within the shared
  `geometryTolerance`, so a fractional CG origin can't defeat it) but only when
  several candidates share one id, so distinct-display matching is unchanged.
  Serial-less, UUID-less twins remain best-effort if a replug also shifts the
  arrangement origin.
- The menu-bar clamp no longer misses a display whose live CG origin carries a
  sub-integer offset. `DisplayProbe.visibleTopY` compared origin and point size
  with exact float equality; it now uses a tolerant comparison (matching
  `DisplayFingerprint.sameGeometry`'s epsilon), so a fractional origin some
  virtual or mirrored displays report no longer defeats the clamp.
- Proportional (unit-space) restore no longer denormalises to a 0x0 frame at the
  origin when a display transiently reports a zero point-size during post-wake
  enumeration; `Coordinates.denormalise` now guards the point-size with
  `max(..., 1)`, matching `normalise`.
- Save-time display attribution now fails closed on a corrupt window frame. A
  null or non-finite (infinite/NaN) rect previously fell through to the primary
  display, silently persisting the corruption; `displayContaining` now returns
  nil for such frames.
- Rule deduplication on save no longer spawns a duplicate when two rules target
  the same windows but differ only by AX role. The dedupe key now blanks the
  role in the cases where matching ignores it (apply-to-all-windows, and
  title-pattern-exclusive), mirroring the existing title-pattern blanking.
- Proportional fallback no longer places overhanging windows off the target
  display. `UnitRect.clamped()` clamps the extent to the display first, then
  slides the origin so the rect fits, preserving the window's size where it can
  (matching the menu-bar clamp) and shrinking only a rect genuinely larger than
  the display, instead of always shrinking the extent and distorting the window.
- `make lint` now fails with exit 1 when swiftlint or swiftformat is missing,
  instead of printing "not installed; skipping" and exiting 0. This matches
  `make format` and stops CI passing lint silently on a runner without the
  tools.
- A window the system relocated onto the wrong display during a display
  power-cycle is no longer mistaken for a manual move and left in place. The
  moved-by-user guard inferred "you moved it" purely from how far the window sat
  from its saved spot, so when macOS reflowed a window onto another monitor on
  display-off/on, an auto-restore suppressed it (it only moved back on an
  explicit restore). Suppression now also checks the display: a window still on
  its target display that drifted is respected as before, but one now centred on
  a *different* display is treated as a system relocation and restored. (macOS
  exposes no move provenance, so this is the practical signal; a deliberate drag
  to another monitor will be pulled back on the next return event.)
- Windows whose saved (or proportionally-remapped) target lands above the menu
  bar are no longer re-placed endlessly. macOS clamps such a window down to the
  first row below the menu bar, so the target was unreachable: every restore
  "drifted" and got re-triggered, and because a drifted write recorded no
  moved-by-user baseline, `respectManualMoves` could never suppress it - the
  window snapped back even after the user dragged it elsewhere. Restore targets
  are now clamped to the display's visible area before being applied, and a
  baseline is recorded on drifted writes too, so the placement settles and
  manual moves are respected. Mainly affected proportional fallbacks onto the
  laptop screen for rules saved on a now-disconnected external display (e.g.
  Messages).
- Windows are no longer left mis-placed after waking or unlocking when an
  external display comes back at a transient resolution. If the saved target
  display's geometry isn't present yet, the restore now places the window
  proportionally as before, but flags the placement so a corrective retry runs
  once the panel settles into its real resolution and replays the saved
  absolute frame. The wake-retry previously armed only on Accessibility errors,
  so a "successful" proportional placement onto the wrong geometry was never
  re-checked. Retries follow a backoff (3s, 5s, 8s, 13s, 21s) and stop as soon
  as a pass lands cleanly.
- Restores after a wake or a display power-on/unlock are more reliable,
  including on mirrored displays driven through a HiDPI adapter where a window
  (e.g. Ghostty) could end up small in the top-left. The settle-and-retry
  safety net now covers display-change events, not just wake from sleep - a
  lock/display-off-on cycle never fires the wake notification, so previously a
  display-on restore that hit transient Accessibility errors got no corrective
  pass at all. Four changes work together: the first pass now waits for the
  display-reconfigure burst to go quiet (up to a few seconds) before running, so
  it places against the final geometry instead of racing the reconfigure; a
  corrective retry that gets dropped because another restore is in flight no
  longer consumes a backoff slot, it waits briefly and re-attempts the same
  step; the retry keeps going until the specific apps that errored are actually
  placed, rather than stopping early when a managed window momentarily reads as
  having no rule (its display was transiently absent); and the whole safety net
  now applies to display-change restores too. Note: a window on an inactive
  Space/Desktop still can't be restored, as macOS Accessibility can neither see
  nor move windows on a Space that isn't currently active.
- A config written by a newer Put (higher schema version) is no longer
  destroyed on downgrade. `ConfigStore.load()` now quarantines any file it
  can't decode or migrate as `config.corrupt-*.json` and bootstraps a fresh
  one, instead of throwing and letting the next save overwrite the newer file
  with an empty default.
- Settings or layout changes made within the 400ms save-debounce window are no
  longer lost on quit; the app flushes the pending config write during
  termination.
- The Rules tab "+" no longer creates a self-rule for Put's own Settings
  window; focused-window saves skip windows belonging to Put.
- The login-item toggle now reflects changes made in System Settings while Put
  is running. Its activation observer was registered on the wrong notification
  centre and never fired.
- Size-only rules (position-restore off) no longer have their position
  rewritten when their display reconnects.
- Queued-rule fulfilment after a display reconnect now logs failed Accessibility
  writes instead of swallowing them silently.
- `WindowMutator` reports `elementGone` when a window vanishes mid-restore
  rather than fabricating an `actual` frame in the "Window drifted" diagnostic.
- Diagnostics export now strips display `localizedName` (which can embed a
  device owner's name for Sidecar/AirPlay screens) from the exported config.
- Relaunching Put (Spotlight, `open -a Put`) during a slow config load no longer
  risks a crash from opening Settings before app state is ready.
- Config writes can no longer lose every copy. `ConfigStore.save` now attempts
  the atomic swap first with no pre-remove and only falls back to a destructive
  remove-and-move when it holds a backup (or there was no live file to lose); a
  save that cannot snapshot the existing config aborts and leaves it untouched
  rather than risk zero copies. The worst-case first-save branch keeps the temp
  file as the only surviving copy instead of deleting it.
- `ConfigStore.load` now recovers from the sibling `config.json.backup` when the
  primary is missing or unreadable, before quarantining and bootstrapping, so an
  interrupted write no longer discards the user's config. It also recovers a
  lingering `config.json.tmp` (the completed-but-unswapped output of a failed
  first save) when neither primary nor backup exists, so a first-run save that
  cannot land is no longer silently lost on the next launch.
- The diagnostics log (`put.log`) resumes writing to a fresh file after it is
  deleted out from under the app. It previously kept writing to the unlinked
  inode and never rotated again, so every diagnostic since deletion was lost at
  process exit; the log now revalidates the path on a coarse cadence and
  recreates the file when it has vanished.
- Log rotation no longer stats the file on every append. An in-actor byte
  counter seeded from the handle at open drives rotation, keeping per-append
  cost O(1) on the display-storm hot path.
- The `Window drifted` diagnostic now records the target and actual frames as
  four fixed comma-separated components (`x,y,width,height`, one decimal place
  each) in both the log line and the NDJSON metadata, instead of
  `String(describing:)` output. This keeps the primary surface for debugging
  app-specific AX misbehaviour stable and machine-parseable.

## [0.1.4] - 2026-05-04

### Fixed

- App-launch auto-trigger now retries with backoff (500 ms, 1 s, 1.5 s, 2 s,
  3 s, 5 s, 7 s) instead of giving up after a single 500 ms probe. Cold-launched
  apps such as Messages whose window appears later than 500 ms after the
  `didLaunchApplication` notification, and launches that race a wake or
  display-change restore through the `isRestoring` gate, now succeed without
  needing the user to press the restore hotkey. Per-bundleID dedup cancels any
  in-flight retry when the same app launches again.

## [0.1.3] - 2026-05-01

### Added

- Re-launching Put while it's already running (Spotlight, Raycast,
  `open -a Put`, etc.) now opens the Settings window. Login-item launches are
  unaffected.
- Per-layout screen-configuration triggers. Capture the current display set
  against a layout in Settings → Layouts to have it auto-activate (and run
  restore) whenever that arrangement is connected. Match-arrangement-exactly
  and auto-activate flags both default on. Capturing a configuration already
  used by another layout shows a Replace / Cancel prompt; clearing a trigger
  also confirms first. The captured set is shown in human-readable form with
  a six-character disambiguating hash. Layout triggers fire on launch as well
  as on display reconfigure, and a successful match suppresses the global
  on-display-change restore for that event so windows don't double-place.

### Changed

- Config schema bumped to v2 to mark the introduction of `Layout.screenConfig`.
  Older configs decode unchanged; the field is optional and defaults to nil.

## [0.1.1] - 2026-04-25

### Changed

- `make release` now bumps the patch version (and freezes `CHANGELOG`) before
  notarising, so each release ships a fresh version automatically. Credentials
  are validated before the bump so a misconfigured run doesn't burn a number.
  Pass `NO_BUMP=1` to retry a release at the existing `VERSION`. New
  `make bump-patch` target exposes the bump on its own.

### Added

- Initial release scaffolding for Put, a native macOS menu bar utility that
  remembers and restores window positions and sizes.
- Display-independent rule model: each rule stores both a display-local
  absolute rect and a normalised unit rect so resolution changes, `Looks like`
  scale changes, and monitor replugs are handled without resaving.
- `DisplayMatcher` resolves stored display fingerprints via UUID, then vendor
  tuple, then closest point size, then primary.
- `PlacementEngine` pure functions for normalise/denormalise, placement
  resolution, and rule matching, with extensive unit test coverage.
- Four global hotkeys via the `KeyboardShortcuts` package, with defaults
  `shift+F5`, `F5`, `shift+F6`, `F6`.
- Action coordinator with save/restore for the active window, all windows of
  an app, and all windows across all apps.
- SwiftUI Settings window with General, Hotkeys, Rules, Layouts, and Displays
  tabs.
- `MenuBarController` status item with per-app submenus, layout switcher, and
  Settings entry.
- Auto-triggers for display configuration change, application launch, and
  wake from sleep, each independently toggleable.
- Debounced display change handling and queue-for-reconnect fulfilment.
- Multi-step welcome wizard covering an introduction with a glossary
  (Rule, Layout, Save/Restore, Auto-triggers), the Accessibility permission
  grant, and the launch-at-login + restore-on-Put-launch defaults. Stamped
  via `Config.firstRunCompletedAt` so it auto-shows once on first launch.
- "Show welcome again..." button on the General settings tab and a
  "Welcome..." item in the menu bar to re-run the wizard. Re-running does
  not modify `firstRunCompletedAt` and only persists settings the user
  actually changes during the session.
- Login-at-start registration via `SMAppService.mainApp`.
- JSON config persistence at `~/Library/Application Support/Put/config.json`
  with `0600` permissions and schema migration hook.
- Rolling file sidecar log at `~/Library/Logs/Put/put.log`.
- Developer ID notarisation workflow scaffolding in the Makefile.
- `Equatable` conformance on `DiagnosticsExportError` for parity with the
  other module error enums.
- `WindowMutator` test suite covering write-sequence ordering, growth
  detection, and the no-progress bail-out used by the retry loop.
- About tab in Settings showing the same content as the standalone About
  window. Both surfaces share a single `AboutInfo` value defined in
  `AppDelegate.aboutInfo()` so the tagline, version, copyright, and links
  cannot drift between the two.

### Changed

- `WindowMutator` exposes `writeSequence`, `isGrowing`, and
  `shouldBailAfterNoProgress` as testable internal helpers; `applyOnce` now
  iterates the shared `writeSequence` rather than duplicating the grow vs
  shrink branches inline.

### Fixed

- `ConfigStore` now uses `.iso8601` for both encoding and decoding dates.
  Previously the encoder used `.iso8601` while the decoder used the default
  strategy, which was latent until a `Date` field landed in the schema. With
  the schema now containing `firstRunCompletedAt`, the asymmetry would have
  caused configs to be quarantined as corrupt on the launch after a
  successful first-run completion.

### Known limitations

- macOS Spaces: windows restore on their current Space only. Moving windows
  across Spaces requires private APIs and is out of scope for v1.
- Mac App Store: not a supported distribution target. Cross-process
  Accessibility control is incompatible with App Store sandboxing.
