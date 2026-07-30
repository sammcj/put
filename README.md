# Put

Put remembers and restores the display, size and position of windows when triggered by a hotkey or configurable events such as changing monitors, waking, or launching an app. Rules are display-independent, so they survive resolution, scale, and monitor replug changes without resaving.

![screenshot](./docs/screenshot.jpeg)

## Requirements

- macOS 26.0 or later
- Grant accessibility permissions for the app to manage window positions and sizes
- For development: Swift toolchain (bundled with Xcode), `swiftlint` and `swiftformat`

## Install

Download the latest `.dmg` from [Releases](https://github.com/sammcj/put/releases) and drag Put to Applications. Builds are signed with a Developer ID and notarised, so Gatekeeper opens them without the right-click workaround. On first launch Put asks for Accessibility and walks you through granting it.

## Build and run

```shell
make            # build and assemble ./Put.app
make install    # install the signed bundle to /Applications
# or
make run        # build and launch the bundled app
```

## Layouts

A layout is a named set of window rules scoped to a screen configuration. Put keeps separate layouts for, say, "laptop only" versus "docked with external display", so the same app can have different saved placements per setup. Layouts are managed in Settings → Layouts, and each rule belongs to the layout selected in Settings → Rules. Each layout can also be given its own activation hotkey.

Saving respects the active layout's screen scope: a window on a monitor that isn't part of that layout's configuration is skipped rather than stamped in with an unrestorable rule, and the skip is reported so it isn't silent.

## What a rule restores

Each rule chooses how much of its saved placement it re-asserts, in Settings → Rules → Saved placement:

- **Size and position** (default) - put the window back on its saved display at its saved size and position.
- **Size only** - force the saved size and leave the window wherever it currently sits.
- **Display only** - move the window onto its saved display and change nothing else. It keeps its current size, and lands roughly where it sat on the display it came from - a window filling a laptop screen ends up centred on a larger external one rather than in the corner - nudged inwards if it would otherwise hang off the edge of a smaller screen. A window already on the right display is left exactly as it is, even if it's parked half off-screen.

Display only is for apps that open on the wrong screen but whose window size you want to keep - VS Code and Electron apps in particular. The full frame is saved whichever option is chosen, so narrowing the scope and widening it again later doesn't lose the original coordinates.

## Default hotkeys

| Action                              | Default    |
| ----------------------------------- | ---------- |
| Save focused window (all app windows) | `shift+F5` |
| Restore active window               | `F5`       |
| Save all windows                    | `shift+F6` |
| Restore all windows                 | `F6`       |

Saving the focused window stamps a rule that applies to every window of the frontmost app. A separate "save focused window (this title only)" action is available with no default binding. All hotkeys, plus per-layout activation shortcuts, are editable from Settings → Hotkeys.

## Permissions

Put needs the Accessibility permission to query and move windows in other applications. On first launch a multi-step welcome wizard introduces the core concepts, drives the Accessibility grant, and surfaces the launch-at-login and restore-on-launch defaults.

The wizard can be re-opened later from Settings → General → "Show welcome again..." or from the menu bar's "Welcome..." item. Re-running it never overwrites existing settings.

If permission state gets into a weird condition during development (typical after rebuilds change the binary hash), reset it:

```shell
tccutil reset Accessibility net.smcleod.put
```

---

### Development
```shell
make test       # hermetic unit tests
make test-ax    # integration tests requiring Accessibility (PUT_RUN_AX_TESTS=1)

make lint       # swiftlint + swiftformat
make bundle     # build, assemble and sign ./Put.app

make clean      # remove .build/ and Put.app/
```

- `make setup-dev-signing` store an Apple Development identity in the Keychain (one-time).
- `make setup-signing` lists the codesign identities available on the machine.
- `make bundle` signs the app as part of the build. By default it signs ad-hoc, which revokes the Accessibility grant on every rebuild because the binary hash changes. For development, sign with a stable Apple Development certificate once so the grant persists.

CI runs `make lint` and `make test` on pull requests only, not on pushes to `main`.

### Distribution

Put is distributed as a Developer ID signed, notarised `.app`, packaged as a `.dmg`.

```shell
make setup-release-keychain   # store Developer ID + notarisation creds (one-time)
make release                  # bump patch, notarise, build DMG, commit, tag, offer to push
make verify                   # codesign / spctl / stapler checks on the built artefacts
```

`make release` writes `dist/Put-<version>.zip` and `dist/Put-<version>-<arch>.dmg`, then commits the version bump as `chore: release X.Y.Z`, creates an annotated `vX.Y.Z` tag, and asks before pushing either. `NO_BUMP=1` reuses the current version, `NO_TAG=1` skips the commit and tag.

## Acknowledgements

Global hotkeys and the shortcut recorder controls use [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) by Sindre Sorhus, under the MIT licence. The full notice is in [THIRD-PARTY-NOTICES.md](./THIRD-PARTY-NOTICES.md), which also ships inside the app bundle.

## License

Copyright 2026 Sam McLeod. Licensed under the [GNU General Public License v3.0](./LICENSE).

Use it anywhere, including at work, and fork it freely. If you distribute Put or anything derived from it, that distribution has to carry the same licence with its source and keep the copyright notice, so no one can rebrand it as closed-source software of their own.
