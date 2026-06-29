# ActiveSpace

A macOS menu-bar app that shows your current Mission Control space and switches spaces instantly — by click, popover button, or configurable keyboard shortcut. Optionally replaces `Cmd-Tab` with a space-aware switcher that only shows apps with windows on the current space.

## What it does

- **Numbered bubble in the menu bar** showing the current space; updates live whether you switch by ActiveSpace, Mission Control, or trackpad gesture.
- **Click to switch.** With two spaces a left-click toggles between them; with three or more it opens a popover with numbered buttons; with one space the icon is just an indicator.
- **Configurable keyboard shortcuts** for next/previous space. They wrap around at the ends by default; a **Navigation** setting switches to a hard stop, where Previous on the first space and Next on the last space are no-ops.
- **Optional grid layout.** Tell ActiveSpace your conceptual row width — say, 4 if you keep 8 spaces and think of them as 4×2 — and the popover reflows into rows of that width. Two extra hotkeys, **Space Up** and **Space Down**, navigate ±rowWidth with column-cycling wrap (so `Space Down` from the bottom row wraps to the top of the same column). With grid mode on, **Next Space** and **Previous Space** become row-aware too — Next from the last column of any row wraps to the first column of the same row instead of stepping into the next row. Set row width to 0 to keep the original linear strip.
- **Instant transitions.** No animation, no sliding, no wait — across single-display, dual-display, lid-open, and lid-closed configurations.
- **Optional space-aware Cmd-Tab Switcher** (off by default). When on, `Cmd-Tab` shows only apps with windows on the current space — including minimised windows and windows of hidden apps. Cycle with `Tab` or arrows, reverse with `Shift-Tab`, commit by releasing `Cmd` or pressing `Return`, cancel with `Esc`. When off, native `Cmd-Tab` is completely untouched.
- **Follow app across spaces.** Bind a shortcut to make the frontmost app's windows appear on every Mission Control space — the same effect as the Dock's right-click *Options → Assign To → All Desktops*. Toggle the same shortcut again and the app returns to the space it was on when you first followed it.

## Installation

Two formats on every release — both signed and notarised, pick whichever suits:

- **[Installer (`.pkg`)](https://github.com/PerpetualBeta/ActiveSpace/releases/latest/download/ActiveSpace.pkg)** — recommended for first-time installs. Double-click to run; macOS Installer places the app in `/Applications` without quarantine or App Translocation.
- **[Download (`.zip`)](https://github.com/PerpetualBeta/ActiveSpace/releases/latest)** — unzip and drag `ActiveSpace.app` to your Applications folder.

Launch ActiveSpace from `/Applications` and grant Accessibility and Input Monitoring permissions when prompted.

## Settings

Right-click the menu-bar bubble and choose **Settings…**:

- **Keyboard shortcuts** — Next Space, Previous Space, and Follow App Across Spaces hotkeys (plus Space Up and Space Down when grid layout is enabled).
- **Switcher** — toggle the space-aware Cmd-Tab replacement.
- **Grid** — optional row width for the popover layout and the Space Up / Space Down hotkeys.
- **Navigation** — **Wrap around at the ends** (on by default). Turn it off for a hard stop: Previous on the first space and Next on the last space become no-ops. In grid mode the same applies at the row and column edges.
- **Permissions** — live status of Accessibility and Input Monitoring with grant buttons.
- **Launch at Login** — start automatically.

Auto-updates are handled by Sparkle. Use the **Check for Updates…** entry in the right-click menu to check on demand; Sparkle's prompt offers an "Automatically download and install updates in the future" checkbox the first time an update is available.

## Permissions

Two are required, both manageable from Settings:

- **Accessibility** — required for space switching. macOS prompts on first launch.
- **Input Monitoring** — required for keyboard shortcuts and the Switcher. If not granted, ActiveSpace shows an alert with a direct link to the correct System Settings pane.

To avoid conflicts with macOS's built-in shortcuts, disable `Control-←` and `Control-→` (and `Control-↑` / `Control-↓` if you bind those to Space Up / Space Down) in System Settings → Keyboard → Keyboard Shortcuts → Mission Control.

## How it works

Hybrid switching strategy chosen per display count:

- **Single display:** direct CGS API (`CGSHideSpaces` / `CGSShowSpaces` / `CGSManagedDisplaySetCurrentSpace`) for an instant flash-free transition. Backed by an invisible 800×600 virtual display whose only job is to flip `NSScreen.screens.count` from 1 to 2 — that alone disarms a macOS 14+ single-display routing bug. The virtual is owned by a bundled `VirtualDisplayHost` helper process (launched on demand) and parked in the negative-coordinate quadrant so it shares only a single corner with main.
- **Multi-display (incl. spans-displays mode):** synthetic dock-swipe gestures via `CGEvent` because the direct API doesn't tell `WindowServer` to move windows or update Mission Control state.

The virtual is created automatically when only a single physical display is present (laptop alone, or laptop with lid closed and one external) and torn down when a second physical display appears. While the virtual exists ActiveSpace pins the cursor to main via a session-level CGEvent tap (`CursorFence`) — macOS otherwise lets the cursor traverse the single shared corner under some lid/wake/screen-lock race conditions, and the cursor would then be invisible on the off-screen virtual. A drift monitor classifies display/space reconfiguration events and, on qualifying drift, restarts the app via its launchd keep-alive agent so any accumulated WindowServer-state weirdness clears.

## Architecture

| File | Purpose |
|---|---|
| `ActiveSpaceApp.swift` | `@main` entry; wires `AppDelegate` |
| `AppDelegate.swift` | Status item, event tap, click routing, popover, settings, keep-alive agent registration |
| `SpaceObserver.swift` | `@Published` current/total space counts; CGS polling + notifications |
| `SpaceSwitcher.swift` | Hybrid direct-API / synthetic-gesture switching |
| `VirtualDisplay.swift` | Supervises the bundled `VirtualDisplayHost` helper; gates the post-reconfig menu-bar reset |
| `VirtualDisplayHost/main.m` | Standalone helper process that owns the off-screen `CGVirtualDisplay` lifecycle |
| `CursorFence.swift` | Session-level event tap that pins the cursor to main while the virtual exists |
| `WindowFollow.swift` | Per-app "follow across spaces" toggle + toast HUD |
| `MenuBarIcon.swift` | Numbered bubble rendering |
| `SpaceSelectorView.swift` | SwiftUI popover (3+ spaces) |
| `TransitionOverlay.swift` | Per-screen blur overlay that masks intermediate-space flashes during multi-step jumps |
| `SwitcherController.swift` | State machine for the space-aware Cmd-Tab switcher |
| `SwitcherHUDWindow.swift` | Borderless HUD with proportional icon scaling |
| `SwitcherAppResolver.swift` | Per-window space membership via `SLSCopySpacesForWindows`; pre-warmed app-icon cache |
| `SwitcherAppStack.swift` | Per-space MRU bundle-ID stack |
| `ReconfigurationObserver.swift` | Six-source observer for display/space/screen-lock/poll events |
| `DriftMonitor.swift` | Classifies reconfiguration events; terminates on qualifying drift so launchd respawns |
| `ActiveSpaceFingerprint.swift` | Display + Spaces snapshot used for drift diffing |
| `SpacesPlist.swift` | Reads `com.apple.spaces.plist` for visual-order ground truth |
| `Logging.swift` | `aslog(...)` to `/tmp/activespace.log`, gated on `ActiveSpace.debugLogging` |
| `CGSPrivate.swift` | Swift bindings for private CoreGraphics, SkyLight, and Accessibility APIs |

## If your Dock disappears

ActiveSpace uses an invisible virtual display on single-monitor configurations. Very rarely, a display reconfiguration can route the Dock onto it. ActiveSpace's drift monitor detects this within a couple of seconds and restarts the app via its launchd keep-alive agent, which clears the condition. If you'd rather not wait, right-click the bubble in the menu bar and choose **Quit** — your Dock returns immediately.

## First launch on a single-display Mac

The first time ActiveSpace runs on a Mac with only one display, macOS may ask **"What do you want to show on 'ActiveSpace VirtualDisplayHost'?"** Choose **Extended Display** (not Mirror) and tick **Set as Default**, then confirm.

This is a one-time macOS prompt for ActiveSpace's invisible helper display — the off-screen virtual that makes instant single-display switching work. Nothing is ever shown or mirrored on it; it stays parked off-screen. macOS remembers the choice, so you'll only be asked once. (It's a macOS-imposed prompt for any virtual display and can't be suppressed by the app, so ActiveSpace shows a short note explaining it if the picker appears.)

## Building

```bash
git clone https://github.com/PerpetualBeta/ActiveSpace.git
open ActiveSpace/ActiveSpace.xcodeproj
# Cmd-B to build, Cmd-R to run
```

Or from the command line:

```bash
xcodebuild -project ActiveSpace.xcodeproj \
  -scheme ActiveSpace \
  -configuration Release \
  build
```

## Requirements

- macOS 14.0 (Sonoma) or later
- Universal binary (Apple Silicon and Intel)
- Accessibility and Input Monitoring permissions (both grantable from the Settings pane)

## Diagnostic logging

ActiveSpace ships with disk logging off. Enable it for support or self-debugging with:

```bash
defaults write cc.jorviksoftware.ActiveSpace ActiveSpace.debugLogging -bool YES
```

Then quit and relaunch. The log lives at `/tmp/activespace.log`. Disable again with `-bool NO` (or `defaults delete`) plus another relaunch.

---

ActiveSpace is part of [Jorvik Software](https://jorviksoftware.cc/). If you find it useful, consider [buying me a coffee](https://jorviksoftware.cc/donate).
