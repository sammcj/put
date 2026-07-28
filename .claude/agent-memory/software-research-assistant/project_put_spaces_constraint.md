---
name: project-put-spaces-constraint
description: Put + macOS Mission Control Spaces — what is SIP-safe to do and what is off-limits for a notarised, SIP-enabled, non-sandboxed app
metadata:
  type: project
---

Put (net.smcleod.put) must work on SIP-enabled macOS 26 Tahoe; user will NOT ask end users to disable SIP. Researched 2026-06-29 against yabai/AeroSpace/menu-bar tools.

**Why:** Defines the hard boundary of what Put can do with Mission Control Spaces. Cross-Space window moves are a tempting feature but are architecturally impossible under the constraints.

**How to apply:** When advising on Put features touching Spaces, hold this line:
- READ Spaces topology = GO, SIP-safe. Use private SkyLight `CGSCopyManagedDisplaySpaces(SLSMainConnectionID())` — returns per-display array with `Spaces` and `Current Space` (`ManagedSpaceID`, `type` 0=desktop/4=fullscreen). Proven by shipping notarised apps WhichSpace, Spaceman, SpaceCommand native backend (needs only Accessibility/Automation perms, no SIP). Parse defensively — undocumented keys can shift between Tahoe point releases.
- MOVE windows across Spaces / CREATE / DESTROY Spaces = NO-GO without partial SIP disable. `CGSAddWindowsToSpaces`/`CGSMoveWindowsToManagedSpace`/`CGSSpaceCreate` only work from the window-server main-connection owner (Dock), reachable only via scripting-addition injection that SIP blocks. yabai needs SIP off for exactly these; AeroSpace avoids native Spaces entirely (parks windows off-screen) to dodge it. On Tahoe even yabai's SIP-off `space --destroy` now fails silently (issue #2730).
- AX writes (`kAXPositionAttribute`) to a window on a NON-active Space: returns kAXErrorSuccess but does not migrate the window across Spaces and does not visibly apply until that Space is activated; some apps ignore it. So only trust/verify AX geometry writes for windows on the currently active Space of their display. Gate restore + read-back verification on active-Space, else false successes.
- Sleep/wake Space collapse: external display re-registers asynchronously on wake/hotplug; while absent, macOS evacuates its windows to the primary display's Space and collapses secondary Spaces. Don't key restore on Space index or assume Space survival. Re-derive topology after CGDisplayRegisterReconfigurationCallback settles and treat "display reappeared" as a re-place trigger. "Automatically rearrange Spaces based on most recent use" OFF stops index drift.

Relates to [[put-macos-detection]] (already records no window-move provenance API, Tahoe CGDisplay caveat).
