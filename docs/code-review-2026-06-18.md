# Code Review - 2026-06-18

Full-codebase review across all nine targets, conducted by four parallel reviewers covering automation/concurrency, the UI layer, core models/placement/storage, and tests/build hygiene. Findings are deduped and prioritised. File references omit line numbers where the code is likely to move; where a line is cited it was accurate at review time.

## Summary

The codebase is in good shape on the basics: no force unwraps, no `try!`/`as!`, no TODO/FIXME debt, clean module boundaries, both documented AX gotchas (`applyOnce` ending in `setSize`, `promptIfNeeded` idempotency) intact, regex fail-closed honoured, no SwiftUI retain cycles, and timers correctly using `DispatchSource`. The items below harden edge cases, close test and CI gaps, and trim a few oversized units.

Two highest-impact claims were verified against the source before writing this doc: the config-write data-loss window and the CI gating gap.

## High - correctness and data safety

1. **Config write can lose data with no backup.** `ConfigStore.save` destructively removes the live file (`removeItem(at: fileURL)`) before the fallback `moveItem`. If `replaceItemAt` throws, the earlier backup copy failed (`backupTaken == false`), and the move then throws, the config is gone with nothing to restore. Make the backup copy mandatory (propagate its failure) before the destructive remove, or drop the pre-remove and let `moveItem` replace. _Source: `Sources/PutStorage/ConfigStore.swift`._

2. **`Coordinates.denormalise` multiplies by an unguarded `pointSize`** while `normalise` guards with `max(..., 1)`. A display reporting zero `pointSize` during the transient post-wake enumeration (the case the fidelity flag exists for) denormalises every saved rule to a 0x0 frame at the origin. Guard symmetrically. _Source: `Sources/PutPlacement/Coordinates.swift`._

3. **Auto-trigger reasons can be silently dropped.** `AutoTriggerController.runSettledRestore` clears `pendingReasons` after snapshotting, then awaits `applyLayoutTriggersIfMatching`. A wake or display event arriving during that await repopulates `pendingReasons`, but the debounce task has already fired, so the new reason only restores if a later event schedules a fresh pass. Re-check `pendingReasons` at the end or reschedule. _Source: `Sources/PutAutomation/AutoTriggerController.swift`._

4. **`ScreenConfigMatcher` greedy pairing is order-dependent.** Two displays with no UUID or serial collapse to the same identity key, so pairing can yield false matches or non-matches depending on iteration order. Reject configs with duplicate fingerprint ids up front, or pair by a stable per-instance handle. _Source: `Sources/PutDisplay/ScreenConfigMatcher.swift`._

5. **`displayContaining` attributes garbage frames to the primary display.** A null or NaN global rect intersects to area 0 everywhere and falls through to "pick primary", so a corrupt save frame silently persists against primary rather than failing. Guard `global.isNull || !global.isFinite` and return nil. _Source: `Sources/PutPlacement/Coordinates.swift`._

## High - CI and test gaps

6. **CI verifies nothing per-PR.** `.github/workflows/release.yml` runs only on `workflow_dispatch` (push and pull_request triggers are commented out) and runs only `make test`, with no `make lint` or `swiftformat --lint` step. Style, `file_length`, and `cyclomatic_complexity` violations reach `main` ungated. Re-enable test and add lint on `pull_request`.

7. **`PutUI` (2,988 lines, the largest module) has zero tests.** There is no `Tests/PutUITests/`. View models, formatting, and state-derivation logic in `MenuBarController`, `OnboardingWizard`, and the settings tabs are extractable and unit-testable. This is the single biggest reason the stated 80%-new-code coverage rule is unmet on a line-weighted basis.

## Medium - matching semantics and dedupe

8. **`MatchCriteria.identityKey` carries `axRole` even when role is not evaluated.** When `applyToAllWindows` or `useTitlePatternExclusively` is set, `RuleMatcher` ignores role, but two rules matching identical windows get different dedupe keys, so save-time dedupe spawns a duplicate. Null `axRole` in the key whenever role is not part of matching, mirroring the existing title-pattern blanking. _Source: `Sources/PutCore/MatchCriteria.swift`._

9. **`UnitRect.clamped()` clamps components independently, allowing `x + width > 1`.** A window saved flush-right (x=0.95, width=0.3) overhangs the target display in the proportional fallback. Clamp width to `1 - x` and height to `1 - y` after clamping the origin. _Source: `Sources/PutCore/UnitRect.swift`._

10. **Exact float equality in display lookup.** `DisplayProbe.visibleTopY` matches live screens by exact `==` on `globalOrigin` and `pointSize`, whereas `sameGeometry` uses a 0.001 epsilon and `ScreenConfigMatcher` a 1pt tolerance. Sub-integer CG origins would silently defeat the menu-bar clamp. Use the tolerant comparison. _Source: `Sources/PutDisplay/DisplayProbe.swift`._

## Medium - structure, duplication, complexity

11. **`ActionCoordinator` (678 lines) has clean split seams.** The placement-history and suppression logic (`prunePlacementHistory`, `recordPlacement`, `shouldSuppressAutoReplay`) is a cohesive `PlacementHistoryStore` collaborator. `save(windows:applyToAll:)` is roughly 95 lines, over the 50-line guideline, and splits naturally into a rule-building loop versus the persist/flash/notice/log tail. _Source: `Sources/PutAutomation/ActionCoordinator.swift`._

12. **Duplicated test fixtures, no shared support target.** `makeStore`, `makeHandle`, and `makeFingerprint` are reimplemented across six suites, and twice within `AutoTriggerControllerTests` alone. Extract a `PutTestSupport` target.

13. **`AboutTab` (SwiftUI) and `AboutWindow` (AppKit) are two full implementations of the same view** with duplicated fonts and layout constants. Only the `AboutInfo` data is shared, not the presentation, so they will drift. Host `AboutTab` inside `AboutWindow` via `NSHostingView`.

14. **Launch-at-login logic duplicated across three sites** (`GeneralTab`, `OnboardingWizard.setLaunchAtLogin`, and the onboarding defaults toggle). Unify on the view-model method.

15. **`RuleDetailForm` is an undecomposed 240-line view**, and its `UnitRect`-from-absolute derivation is copy-pasted in both the `displayBinding` and `frameBinding` setters. Extract one `recomputeNormalised` helper before they diverge, and split `placementForm` into its own view. _Source: `Sources/PutUI/Settings/RuleDetailForm.swift`._

16. **`RulesTab` persists on every keystroke with an O(rules) rescan** via the computed `currentRule`. Persist on field-commit as `LayoutsTab` does. _Source: `Sources/PutUI/Settings/RulesTab.swift`._

17. **Repeated `DisplayChangeObserver` plus refresh `.task` blocks** in `RulesTab` and `DisplaysTab`, with an identical `(try? DisplayProbe.snapshot()) ?? []` body. Extract a shared view modifier.

## Low - polish

18. `logDrift` serialises CGRects via `String(describing:)`, making the key `Window drifted` NDJSON diagnostic hard to parse. Use fixed numeric formatting. _Source: `Sources/PutAutomation/ActionCoordinator.swift`._
19. `FileLog.rotateIfNeeded` stats the file on every append; track bytes in-actor instead during display storms. _Source: `Sources/PutStorage/FileLog.swift`._
20. `migrate` has no lower bound, so a 0 or negative `schemaVersion` is stamped forward unvalidated. Add a floor. _Source: `Sources/PutStorage/ConfigStore.swift`._
21. Five `unsafeDowncast` AX sites are guarded only by `CFGetTypeID` in `WindowProbe` and `WindowMutator`. Fold into one helper to remove duplication.
22. `.swiftlint.yml` `function_body_length` is 60 but CLAUDE.md says max 50. Align the two.
23. `make lint` silently exits 0 when swiftlint or swiftformat are absent, while `make format` fails. Make `lint` fail too.

## Confirmed sound (no action)

`DisplayChangeObserver` retain/release balance and lock discipline, `RuleMatcher` regex fail-closed semantics, `DisplayMatchQuality` ordering and the `<= .equivalent` found contract, `WindowMutator.applyOnce` ending both branches in `setSize`, and `AccessibilityTrust.promptIfNeeded` idempotency.
