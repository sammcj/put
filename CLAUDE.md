# Put

Native macOS 26+ menu bar utility that remembers and restores window positions across monitor changes. Display-independent rules survive resolution, `Looks like` scale, and monitor replug changes without resaving.

## Architecture

Ten targets in the local Swift Package (eight libraries, the `Put` executable, and `PutSpaceProbe`, a dev-only diagnostic executable that is not part of the shipped app):

- `PutCore`: pure `Codable` models and the `putSchemaVersion` constant. Platform-agnostic; also hosts `PutLog` (which wraps `os.Logger`) since every module needs logging and Core is the single universal dependency.
- `PutStorage`: actor-isolated `ConfigStore` for `~/Library/Application Support/Put/config.json` and a `FileLog` actor that writes NDJSON to `~/Library/Logs/Put/put.log`.
- `PutDisplay`: `DisplayProbe` (CGDirectDisplay), `DisplayMatcher` (resolution chain), `DisplayChangeObserver` (CGDisplayRegisterReconfigurationCallback → `AsyncStream`).
- `PutWindows`: `WindowProbe` and `WindowMutator` (AXUIElement), `WindowHandle` (the opaque pairing), `AccessibilityTrust`.
- `PutPlacement`: pure functions - `Coordinates` (three coordinate spaces, see below), `RuleMatcher`, `PlacementEngine`.
- `PutHotkeys`: `KeyboardShortcuts` wrapper, default bindings, `LayoutHotkeys` for dynamic per-layout shortcuts.
- `PutAutomation`: `ActionCoordinator` (orchestrates save/restore), `AutoTriggerController` (display/launch/wake), `AppState` (`@Observable`), `ConfigPersister`, `DiagnosticsExport`, `LoginItemController`, `Debouncer`.
- `PutUI`: SwiftUI `SettingsView` with six tabs (General, Hotkeys, Rules, Layouts, Displays, About), `MenuBarController`, `OnboardingWindowController`, `AboutWindow`.
- `Put`: `@main` `PutApp` + `AppDelegate` that wires everything.

## Build commands

All build commands MUST run outside the Claude sandbox. SwiftPM runs its own inner `sandbox-exec` during manifest compile which the outer Claude sandbox blocks with `Operation not permitted`. Use `dangerouslyDisableSandbox: true` on the Bash tool for anything that triggers `swift build/test`.

```
make bundle     # build + generate icon + assemble .app + sign
make run        # launch the bundled .app
make lint       # swiftlint + swiftformat
make test       # hermetic unit tests
make test-ax    # PUT_RUN_AX_TESTS=1 for AX-dependent tests
make release    # bump patch, notarise, build DMG, then commit and tag
```

`make release` has side effects beyond building: it bumps the patch version, freezes the CHANGELOG `[Unreleased]` section, and on success commits `VERSION` + `CHANGELOG.md` as `chore: release X.Y.Z` and creates an annotated `vX.Y.Z` tag. It pushes nothing. `NO_BUMP=1` keeps the current version, `NO_TAG=1` skips the commit and tag.

Anything baked into the bundle from a file must be a prerequisite of the `$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)` rule. `VERSION` is, because the recipe seds it into `Info.plist`; omitting it meant a version bump alone left every prerequisite older than the target, so make skipped the recipe and shipped a stale `CFBundleShortVersionString` under a correctly-named DMG.

Always drive the build/lint/test loop through `make`, not direct `swift` / `swiftlint` / `swiftformat` calls - the Makefile wires in signing identity resolution, icon generation, and environment defaults that ad-hoc invocations miss.

Icon generation (`Resources/AppIcon.icns` from `AppIcon.svg`) uses `rsvg-convert` + `iconutil`. Missing `rsvg-convert` (`brew install librsvg`) warns and ships a generic icon rather than failing.

## Coordinate spaces

Three spaces, converted only in `PutPlacement.Coordinates`:

- **Global AX space**: top-left origin, primary display at (0, 0), what `kAXPositionAttribute` returns. NSScreen is bottom-left Cocoa; never mix.
- **Display-local**: top-left origin relative to a `DisplayFingerprint.globalOrigin`. This is what `Rule.frame.absolute` persists.
- **Unit space**: `[0, 1]² ` relative to a display's `pointSize`. This is `Rule.frame.normalised`, the proportional fallback.

Display identity resolves via `DisplayMatcher` chain: UUID → vendor+product+serial → closest point size → primary. Returned `DisplayMatchQuality` is comparable; quality `<= .equivalent` means "found the target", anything else means "missing, apply `MissingDisplayPolicy`".

## Restore scope

`Rule.restoreScope` selects which AX write a restore performs: `.sizeAndPosition` → `setFrame`, `.sizeOnly` → `setSize`, `.displayOnly` → `setPosition`. Every write path must switch on all three - `ActionCoordinator.executeWrite` and `AutoTriggerController.write` are the two.

`.displayOnly` is why `PlacementEngine.resolve` takes a `currentFrame`: its target is derived from where the window currently sits (size preserved, the window's *centre* mapped proportionally onto the target display via `Coordinates.moving`), not from the saved frame. Queued-rule fulfilment resolves per window for the same reason - two windows of one app can land in different places.

A `.displayOnly` rule must resolve to the window's exact current frame when it's already on the target display. `PlacementHistoryStore.shouldSuppressAutoReplay` skips moved-by-user suppression for `.displayOnly` on that basis, so any nudge repeats on every wake and display event. Two places enforce it: `Coordinates.moving` returns its input unchanged for a same-display move, ahead of the clamp that keeps a cross-display move on screen, and both write paths run the menu-bar clamp through `ActionCoordinator.clampingIfMoving`, which skips it when the resolved frame equals the current one.

A `.displayOnly` rule never resizes, so when there's no usable current frame (none passed, non-finite, or the window overlaps no display) the engine returns `.skipped` rather than falling back to the saved frame. Note `Coordinates.displayContaining` answers the save-time question and falls back to primary for a frame overlapping nothing; `displayOnlyFrame` rejects that fallback explicitly.

## Rule matching semantics

In `RuleMatcher.matches(rule, against:)`:

1. `bundleID` must match (always).
2. If `applyToAllWindows`: match succeeds on bundleID alone.
3. Else evaluate title pattern (empty pattern = any title).
4. If `useTitlePatternExclusively == false` and `axRole` is set, role must also match.

Invalid regex patterns fail closed (no match). Keep it that way - fail-open would cause catastrophic "all Safari windows" placements.

## Config and persistence

`Config` is schema-versioned via `putSchemaVersion`. `ConfigStore` migration stub stamps older versions forward; future incompatible changes bump the int and add a real migration branch. Reads and writes are atomic (tmp + replace); writes force 0600 perms on both file and parent directory.

`Rule` hand-rolls `Codable` so `restoreScope` can fall back to the superseded `restoresPosition` bool on read, and still writes that bool on encode so a config opened by an older build degrades to size-only instead of re-asserting a position the user cleared. Keep the dual write when touching the scope.

`KeyboardShortcuts` stores chosen bindings in `UserDefaults` keyed by `Name.rawValue`. Per-layout activation shortcuts use `KeyboardShortcuts.Name("layout.<uuid>")` so they survive restarts as long as the `Layout.id` does. `LayoutHotkeys.syncRegistrations` is called on launch and polled every 2 seconds from `AppDelegate.observeLayoutChanges` to catch layout add/remove.

## Settings backup

`SettingsBackup` (PutAutomation) is a single-JSON export/import of all settings, wired through `AppDelegate.exportSettings`/`importSettings` and surfaced in Settings → General → Backup. For a new setting to be captured automatically, store it in one of the two recognised homes: a field on `Config` (the whole struct is embedded verbatim, so any new field flows through), or a `GlobalHotkeyName` case (`ShortcutsBackup.globalNames` derives the backed-up hotkeys from `GlobalHotkeyName.allCases`). A setting written to any third location (a bespoke `UserDefaults` key, say) is silently dropped from backups. `ShortcutsBackupTests.globalNamesCoverEveryGlobalHotkey` guards the hotkey derivation.

## Testing

Default `swift test` is hermetic and fast (about a second). AX-dependent integration tests live in `Tests/IntegrationTests` and `Tests/PutWindowsTests`; disabled unless `PUT_RUN_AX_TESTS=1`. Use `.disabled(if:)` trait, not `#require`, when gating new AX tests - `#require` converts skip-by-environment into a test failure.

A test that posts to `NSWorkspace.shared.notificationCenter` or `DistributedNotificationCenter` shares that bus with the OS, so a real system wake, unlock or display change can deliver an extra event mid-test. Assert the boundary the test exists to prove (`>= 1` for "the observer is wired") rather than an exact count, and cover coalescing in a test that drives the debouncer directly. Two CI flakes have come from exact-count assertions over timing windows: this one, and `appLaunchRetryCancelsOnRelaunch`, where the split between "attempt belongs to the cancelled schedule" and "cancellation took effect" is not observable.

Pure placement matrix in `Tests/PutPlacementTests/PlacementEngineTests.swift` covers same-resolution replay, downscale, `Looks like` change, missing display fallback, arrangement origin shift, vendor-match-as-equivalent. When touching `PlacementEngine`, add to that matrix.

Test doubles for the PutWindows seams live in `Tests/PutTestSupport/Doubles.swift` (`StubWindowProbe`, `RecordingWindowMutator`, `StubAccessibilityGate`). Use them instead of adding a per-suite copy; the suites previously each kept their own variant and the copies drifted. Doubles for the PutAutomation-only seams (`SaveFlashing`, `SaveScopeNotifying`) stay local, since hoisting them would make every test target depend on PutAutomation.

## Diagnostics

When debugging window placement, the three surfaces in order of usefulness:

- NDJSON sidecar at `~/Library/Logs/Put/put.log` (rotates `.1`-`.3`). `Window drifted` entries record `target`, `actual`, `attempts`, and `bundle`, which is where app-specific AX misbehaviour shows up.
- Unified log: `log show --predicate 'subsystem == "net.smcleod.put"' --info`. Categories: `windows.mutator` (per-write outcomes with full target/actual frames), `actions` (save/restore summaries), `automation.triggers`, `display.observer`.
- Live config at `~/Library/Application Support/Put/config.json` - the rule's saved `targetDisplay` fingerprint, `frame.absolute`, and `frame.normalised`. Compare against current `DisplayProbe.snapshot()` output to see why a rule did or didn't match.

## Gotchas

**Ad-hoc TCC fragility.** Ad-hoc signatures change their cdhash on every rebuild, which invalidates Accessibility (TCC) trust. Dev builds should sign with an Apple Development cert so the designated requirement stays stable; `make setup-dev-signing` stores it in Keychain (service `put-release`). Before chasing "app doesn't see Accessibility granted" bugs, confirm the cdhash is stable across the grant → relaunch cycle - otherwise you're debugging the signing story, not the AX code.

**Accessory apps and ⌘Q.** `NSApp.setActivationPolicy(.accessory)` hides the menu bar when active. Key equivalents still route through `NSApp.mainMenu` if one is installed, so `AppDelegate.installMainMenu()` registers a minimal App menu (About / Settings / Check Accessibility / Hide / Quit) plus an Edit menu for TextField shortcuts. Without this, ⌘Q silently does nothing.

**`PutCore.Layout` vs `SwiftUI.Layout` collision.** SwiftUI defines a `Layout` protocol. Because `PutCore` is also the module name, the bare `PutCore.Layout` reference is ambiguous inside SwiftUI files. Always qualify as `PutCore.Layout` where SwiftUI is imported; the PutCore module never contains a namespace enum named `PutCore` (it was removed specifically to break this tie).

**`kAXTrustedCheckOptionPrompt` is concurrency-hostile.** The global CFStringRef fails Swift 6 strict concurrency checks. Use the hardcoded string literal `"AXTrustedCheckOptionPrompt"` (its documented value) as done in `AccessibilityTrust.promptIfNeeded`.

**`AccessibilityTrust.promptIfNeeded` is idempotent.** Subsequent calls in the same process are no-ops. The system AX dialog only appears once per launch. Do not remove this guard; doing so leads to the user seeing the TCC dialog repeatedly as AppDelegate lifecycle handlers fire.

**Timers inside Swift 6 `@MainActor` classes.** `Timer.scheduledTimer` closures are nonisolated and interact poorly with main-actor state. Use `DispatchSource.makeTimerSource(queue: .main)` (as in `OnboardingWindowController`) for any timed polling.

**AX enumeration blocks on XPC.** `WindowProbe.snapshot()` and friends synchronously round-trip to every foreground app's Accessibility server. The `ActionCoordinator` dispatches all AX reads via `Task.detached(priority: .userInitiated)` and only re-enters `@MainActor` for state mutation. Keep this pattern when adding new AX-driven operations.

**No App Store target.** Cross-process `AXUIElement` is incompatible with sandboxing, and GPL-3.0 is incompatible with the App Store's distribution terms, so this is settled twice over. Distribution path is Developer ID + notarisation. Credentials resolve Keychain-first from service `put-release` (accounts `signing-identity`, `api-issuer`, `api-key`, `api-key-path`, populated by `make setup-release-keychain`), falling back to the matching `APPLE_*` env vars so CI can supply them as secrets. Do not add sandbox entitlements "just in case".

**`WindowMutator.applyOnce` must end with `setSize` in both branches.** Firefox (and likely other Gecko apps) silently revert the size when a position write immediately follows it - AX returns `.success`, but the size never lands. The growing branch keeps a trailing position pin to catch size-induced origin drift, then re-commits size last; the shrinking branch already ends with size. Symptom of a regression: window jumps to target then snaps back, with `Window drifted attempts=2` in the log because the early-bail sees identical actuals across attempts.

**Mission Control Spaces are a hard boundary.** Put has to work with SIP enabled, which fixes what is reachable:

- An AX geometry write to a window on a non-active Space returns `kAXErrorSuccess` but does not apply until that Space is activated, and never migrates the window between Spaces. Read-back verification is meaningless there, so only trust write outcomes for windows on the active Space of their display.
- Moving windows across Spaces, and creating or destroying Spaces, needs the window-server main connection (owned by Dock) reached via scripting-addition injection that SIP blocks. This is permanently out of scope, not a deferred feature - yabai requires SIP off for exactly these calls.
- Reading Space topology is SIP-safe via private SkyLight `CGSCopyManagedDisplaySpaces(SLSMainConnectionID())`, as shipped by notarised apps like WhichSpace. Parse defensively; the undocumented keys shift between point releases.
- While an external display is absent (wake or hotplug), macOS evacuates its windows to the primary display's Space and collapses the secondary Spaces. Never key a restore on Space index; re-derive topology after `CGDisplayRegisterReconfigurationCallback` settles and treat "display reappeared" as a re-place trigger.

---

## Workflow

- Always run `make lint` and then `make test` and fix any warnings or errors (even if not related to your change) before stating that your task is complete.

### Issue & PR Management

Issues (features, bugs, chores) are to be tracked in Github Issues.

- Keep issues concise, clear and actionable. Ideally with a definition of done if possible.
- If asked to create a PR from a branch, copilot may comment on the PR (this usually takes 2-5 minutes after the PR is created and out of draft), if the user asks you to follow up on any Copilot comments after Confirming if they're valid or invalid, resolve the issue or engage in discussion with the user if it is unclear. Once completed and a lightweight unit test has been added if required, you may then add a very brief comment on co-pilots' comments and close their comment thread. Once all co-pilot comments have been resolved, you can ask the user if they would like you to trigger co-pilots to do another review or not.

### Changelog

Update `CHANGELOG.md` under the `## [Unreleased]` section with a concise bullet-point summary of changes made, grouped under headings (Added/Changed/Fixed/Removed). Combine or update items refined within the same session. Do NOT add version numbers; the build process handles that via `make version V=X.Y.Z` (or `make stamp-version` to freeze the current VERSION), and `make release` bumps the patch and freezes `[Unreleased]` itself. Truncate the file when it exceeds 2000 lines.
