# Put

Native macOS 26+ menu bar utility that remembers and restores window positions across monitor changes. Display-independent rules survive resolution, `Looks like` scale, and monitor replug changes without resaving.

## Architecture

Nine targets in the local Swift Package (eight libraries plus the `Put` executable):

- `PutCore`: pure `Codable` models and the `putSchemaVersion` constant. Platform-agnostic; also hosts `PutLog` (which wraps `os.Logger`) since every module needs logging and Core is the single universal dependency.
- `PutStorage`: actor-isolated `ConfigStore` for `~/Library/Application Support/Put/config.json` and a `FileLog` actor that writes NDJSON to `~/Library/Logs/Put/put.log`.
- `PutDisplay`: `DisplayProbe` (CGDirectDisplay), `DisplayMatcher` (resolution chain), `DisplayChangeObserver` (CGDisplayRegisterReconfigurationCallback → `AsyncStream`).
- `PutWindows`: `WindowProbe` and `WindowMutator` (AXUIElement), `WindowHandle` (the opaque pairing), `AccessibilityTrust`.
- `PutPlacement`: pure functions - `Coordinates` (three coordinate spaces, see below), `RuleMatcher`, `PlacementEngine`.
- `PutHotkeys`: `KeyboardShortcuts` wrapper, default bindings, `LayoutHotkeys` for dynamic per-layout shortcuts.
- `PutAutomation`: `ActionCoordinator` (orchestrates save/restore), `AutoTriggerController` (display/launch/wake), `AppState` (`@Observable`), `ConfigPersister`, `DiagnosticsExport`, `LoginItemController`, `Debouncer`.
- `PutUI`: SwiftUI `SettingsScene` with five tabs, `MenuBarController`, `OnboardingWindowController`, `AboutWindow`.
- `Put`: `@main` `PutApp` + `AppDelegate` that wires everything.

## Build commands

All build commands MUST run outside the Claude sandbox. SwiftPM runs its own inner `sandbox-exec` during manifest compile which the outer Claude sandbox blocks with `Operation not permitted`. Use `dangerouslyDisableSandbox: true` on the Bash tool for anything that triggers `swift build/test`.

```
make bundle     # build + generate icon + assemble .app + sign
make run        # launch the bundled .app
make lint       # swiftlint + swiftformat
make test       # hermetic unit tests
make test-ax    # PUT_RUN_AX_TESTS=1 for AX-dependent tests
```

Always drive the build/lint/test loop through `make`, not direct `swift` / `swiftlint` / `swiftformat` calls - the Makefile wires in signing identity resolution, icon generation, and environment defaults that ad-hoc invocations miss.

Icon generation (`Resources/AppIcon.icns` from `AppIcon.svg`) uses `rsvg-convert` + `iconutil`. Missing `rsvg-convert` (`brew install librsvg`) warns and ships a generic icon rather than failing.

## Coordinate spaces

Three spaces, converted only in `PutPlacement.Coordinates`:

- **Global AX space**: top-left origin, primary display at (0, 0), what `kAXPositionAttribute` returns. NSScreen is bottom-left Cocoa; never mix.
- **Display-local**: top-left origin relative to a `DisplayFingerprint.globalOrigin`. This is what `Rule.frame.absolute` persists.
- **Unit space**: `[0, 1]² ` relative to a display's `pointSize`. This is `Rule.frame.normalised`, the proportional fallback.

Display identity resolves via `DisplayMatcher` chain: UUID → vendor+product+serial → closest point size → primary. Returned `DisplayMatchQuality` is comparable; quality `<= .equivalent` means "found the target", anything else means "missing, apply `MissingDisplayPolicy`".

## Rule matching semantics

In `RuleMatcher.matches(rule, against:)`:

1. `bundleID` must match (always).
2. If `applyToAllWindows`: match succeeds on bundleID alone.
3. Else evaluate title pattern (empty pattern = any title).
4. If `useTitlePatternExclusively == false` and `axRole` is set, role must also match.

Invalid regex patterns fail closed (no match). Keep it that way - fail-open would cause catastrophic "all Safari windows" placements.

## Config and persistence

`Config` is schema-versioned via `putSchemaVersion`. `ConfigStore` migration stub stamps older versions forward; future incompatible changes bump the int and add a real migration branch. Reads and writes are atomic (tmp + replace); writes force 0600 perms on both file and parent directory.

`KeyboardShortcuts` stores chosen bindings in `UserDefaults` keyed by `Name.rawValue`. Per-layout activation shortcuts use `KeyboardShortcuts.Name("layout.<uuid>")` so they survive restarts as long as the `Layout.id` does. `LayoutHotkeys.syncRegistrations` is called on launch and polled every 2 seconds from `AppDelegate.observeLayoutChanges` to catch layout add/remove.

## Settings backup

`SettingsBackup` (PutAutomation) is a single-JSON export/import of all settings, wired through `AppDelegate.exportSettings`/`importSettings` and surfaced in Settings → General → Backup. For a new setting to be captured automatically, store it in one of the two recognised homes: a field on `Config` (the whole struct is embedded verbatim, so any new field flows through), or a `GlobalHotkeyName` case (`ShortcutsBackup.globalNames` derives the backed-up hotkeys from `GlobalHotkeyName.allCases`). A setting written to any third location (a bespoke `UserDefaults` key, say) is silently dropped from backups. `ShortcutsBackupTests.globalNamesCoverEveryGlobalHotkey` guards the hotkey derivation.

## Testing

Default `swift test` is hermetic and fast (~0.3s). AX-dependent integration tests live in `Tests/IntegrationTests` and `Tests/PutWindowsTests`; disabled unless `PUT_RUN_AX_TESTS=1`. Use `.disabled(if:)` trait, not `#require`, when gating new AX tests - `#require` converts skip-by-environment into a test failure.

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

**No App Store target.** Cross-process `AXUIElement` is incompatible with sandboxing. Distribution path is Developer ID + notarisation (`make notarise`, gated on `DEVELOPER_ID_APPLICATION`, `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_ID_PASSWORD`). Do not add sandbox entitlements "just in case".

**`WindowMutator.applyOnce` must end with `setSize` in both branches.** Firefox (and likely other Gecko apps) silently revert the size when a position write immediately follows it - AX returns `.success`, but the size never lands. The growing branch keeps a trailing position pin to catch size-induced origin drift, then re-commits size last; the shrinking branch already ends with size. Symptom of a regression: window jumps to target then snaps back, with `Window drifted attempts=2` in the log because the early-bail sees identical actuals across attempts.

---

## Workflow

- Always run `make lint` and then `make test` and fix any warnings or errors (even if not related to your change) before stating that your task is complete.

### Issue & PR Management

Issues (features, bugs, chores) are to be tracked in Github Issues.

- Keep issues concise, clear and actionable. Ideally with a definition of done if possible.
- If asked to create a PR from a branch, copilot may comment on the PR (this usually takes 2-5 minutes after the PR is created and out of draft), if the user asks you to follow up on any Copilot comments after Confirming if they're valid or invalid, resolve the issue or engage in discussion with the user if it is unclear. Once completed and a lightweight unit test has been added if required, you may then add a very brief comment on co-pilots' comments and close their comment thread. Once all co-pilot comments have been resolved, you can ask the user if they would like you to trigger co-pilots to do another review or not.

### Changelog

Update `CHANGELOG.md` under the `## [Unreleased]` section with a concise bullet-point summary of changes made, grouped under headings (Added/Changed/Fixed/Removed). Combine or update items refined within the same session. Do NOT add version numbers; the build process handles that via `make version V=X.Y.Z` (or `make stamp-version` to freeze the current VERSION). Truncate the file when it exceeds 2000 lines.
