# ActiveSpace

A macOS menu-bar app that shows your current Mission Control space and switches spaces instantly — by click, popover button, or configurable keyboard shortcut. Optionally replaces `Cmd-Tab` with a space-aware switcher that only shows apps with windows on the current space.

## What it does

- **Numbered bubble in the menu bar** showing the current space; updates live whether you switch by ActiveSpace, Mission Control, or trackpad gesture.
- **Click to switch.** With two spaces a left-click toggles between them; with three or more it opens a popover with numbered buttons; with one space the icon is just an indicator.
- **Configurable keyboard shortcuts** for next/previous space, with wrap-around.
- **Optional grid layout.** Tell ActiveSpace your conceptual row width — say, 4 if you keep 8 spaces and think of them as 4×2 — and the popover reflows into rows of that width. Two extra hotkeys, **Space Up** and **Space Down**, navigate ±rowWidth with column-cycling wrap (so `Space Down` from the bottom row wraps to the top of the same column). With grid mode on, **Next Space** and **Previous Space** become row-aware too — Next from the last column of any row wraps to the first column of the same row instead of stepping into the next row. Set row width to 0 to keep the original linear strip.
- **Instant transitions.** No animation, no sliding, no wait — across single-display, dual-display, lid-open, and lid-closed configurations.
- **Optional space-aware Cmd-Tab Switcher** (off by default). When on, `Cmd-Tab` shows only apps with windows on the current space — including minimised windows and windows of hidden apps. Cycle with `Tab` or arrows, reverse with `Shift-Tab`, commit by releasing `Cmd` or pressing `Return`, cancel with `Esc`. When off, native `Cmd-Tab` is completely untouched.

## Installation

Two formats on every release — both signed and notarised, pick whichever suits:

- **[Installer (`.pkg`)](https://github.com/PerpetualBeta/ActiveSpace/releases/latest/download/ActiveSpace.pkg)** — recommended for first-time installs. Double-click to run; macOS Installer places the app in `/Applications` without quarantine or App Translocation.
- **[Download (`.zip`)](https://github.com/PerpetualBeta/ActiveSpace/releases/latest)** — unzip and drag `ActiveSpace.app` to your Applications folder.

Launch ActiveSpace from `/Applications` and grant Accessibility and Input Monitoring permissions when prompted.

## Settings

Right-click the menu-bar bubble and choose **Settings…**:

- **Keyboard shortcuts** — Next Space and Previous Space hotkeys (plus Space Up and Space Down when grid layout is enabled).
- **Switcher** — toggle the space-aware Cmd-Tab replacement.
- **Grid** — optional row width for the popover layout and the Space Up / Space Down hotkeys.
- **Permissions** — live status of Accessibility and Input Monitoring with grant buttons.
- **Launch at Login** — start automatically.
- **Auto-update** — schedule + optional automatic install.

## Permissions

Two are required, both manageable from Settings:

- **Accessibility** — required for space switching. macOS prompts on first launch.
- **Input Monitoring** — required for keyboard shortcuts and the Switcher. If not granted, ActiveSpace shows an alert with a direct link to the correct System Settings pane.

To avoid conflicts with macOS's built-in shortcuts, disable `Control-←` and `Control-→` (and `Control-↑` / `Control-↓` if you bind those to Space Up / Space Down) in System Settings → Keyboard → Keyboard Shortcuts → Mission Control.

## How it works

Hybrid switching strategy chosen per display count:

- **Single display:** direct CGS API (`CGSHideSpaces` / `CGSShowSpaces` / `CGSManagedDisplaySetCurrentSpace`) for an instant flash-free transition. Backed by an invisible 640×480 virtual display that forces macOS off its single-display "Main" identifier and onto UUID-based identifiers — required for clean Dock compositing on macOS 14+.
- **Multi-display (incl. spans-displays mode):** synthetic dock-swipe gestures via `CGEvent` because the direct API doesn't tell `WindowServer` to move windows or update Mission Control state.

The virtual display is created automatically when you have a single physical display (laptop alone, or laptop with lid closed and one external) and torn down again when a second display appears. While present, ActiveSpace pins it to the right edge of main, fences the cursor out of it, and resets menu-bar coordinate state on every display reconfiguration so windows and menus stay where you expect them.

## Architecture

| File | Purpose |
|---|---|
| `ActiveSpaceApp.swift` | `@main` entry; wires `AppDelegate` |
| `AppDelegate.swift` | Status item, event tap, click routing, popover, settings, keep-alive agent registration |
| `SpaceObserver.swift` | `@Published` current/total space counts; CGS polling + notifications |
| `SpaceSwitcher.swift` | Hybrid direct-API / synthetic-gesture switching |
| `VirtualDisplay.swift` | Manages the virtual display, drift reposition, cursor fence, post-create + post-destroy menu-bar resets |
| `VirtualDisplayHelper.{h,m}` | Obj-C bridge to the private `CGVirtualDisplay` classes |
| `MenuBarIcon.swift` | Numbered bubble rendering |
| `SpaceSelectorView.swift` | SwiftUI popover (3+ spaces) |
| `TransitionOverlay.swift` | Per-screen blur overlay that masks intermediate-space flashes during multi-step jumps |
| `SwitcherController.swift` | State machine for the space-aware Cmd-Tab switcher |
| `SwitcherHUDWindow.swift` | Borderless HUD with proportional icon scaling |
| `SwitcherAppResolver.swift` | Per-window space membership via `SLSCopySpacesForWindows` |
| `SwitcherAppStack.swift` | Per-space MRU bundle-ID stack |
| `AppIconCache.swift` | Pre-warms scaled icons so the first HUD draw is snappy |
| `ReconfigurationObserver.swift` | Six-source observer for display/space/screen-lock/poll events |
| `DriftMonitor.swift` | Classifies reconfiguration events; logs drift verdicts |
| `CGSPrivate.swift` | Swift bindings for private CoreGraphics, SkyLight, and Accessibility APIs |

## If your Dock disappears

ActiveSpace uses an invisible virtual display on single-monitor configurations. Very rarely, a display reconfiguration can cause the Dock to migrate onto it. If that happens, right-click the bubble in the menu bar and choose **Quit** — your Dock will return immediately.

## If your mouse pointer disappears

The same invisible virtual display sits 6000pt off-screen to the right. ActiveSpace installs a cursor fence to keep the pointer out of that region, but a fast cursor throw during exactly the wrong moment (e.g. just after waking from screen lock, while the fence is briefly disarmed) can occasionally slip past — and once the cursor is on the off-screen virtual, it's invisible.

ActiveSpace ships **MouseCatcher** for exactly this case — a tiny keyboard-only utility that warps the cursor back to the centre of your main display. ActiveSpace deploys it to `/Applications/MouseCatcher.app` automatically on launch (sibling of ActiveSpace.app) so it's already there when you need it. To recover the cursor:

1. Press <kbd>⌘&nbsp;Space</kbd> to open Spotlight
2. Type **MouseCatcher**
3. Press <kbd>Return</kbd>

The cursor reappears immediately near the centre of your main display. MouseCatcher does its one job and exits — no Dock flash, no menu-bar item, no UI.

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
