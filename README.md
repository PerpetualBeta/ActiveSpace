# ActiveSpace

A macOS menu-bar app that shows which Mission Control space you are on, and lets you jump to any other one by clicking it. Optionally replaces command-Tab with a space-aware switcher that only shows apps with windows on the current space.

## What it does

- **Numbered bubble in the menu bar** showing the current space; updates live whether you switch with ActiveSpace, Mission Control, the keyboard or a trackpad gesture.
- **Click to switch.** With two spaces a left-click toggles between them; with three or more it opens a popover with numbered buttons; with one space the icon is just an indicator.
- **Optional grid layout.** Tell ActiveSpace your conceptual row width — say, 4 if you keep 8 spaces and think of them as 4×2 — and the popover reflows into rows of that width. Two extra hotkeys become available which navigate up/down a row, with optional column-wrap, where navigating down from the bottom of a column lands at the top of the same column and vice versa. Set row width to 0 to keep the original linear strip.
- **Optional space-aware command-Tab Switcher** (off by default). When on, `command` `tab` shows only apps with windows on the current space, including minimised windows and windows of hidden apps. Cycle with `tab` or arrows, reverse with `shift` `tab`, commit by releasing `command` or pressing `return`, cancel with `esc`. When off, native `command` `tab` is completely untouched.
- **Follow app across spaces.** Bind a shortcut to make the frontmost app's windows appear on every Mission Control space, the same effect as the Dock's right-click *Options → Assign To → All Desktops*. Toggle the same shortcut again and the app returns to the space it was on when you first followed it.
- **Focus follows you.** Arriving on a space brings forward an app that actually lives there, rather than leaving you on a desk with nothing selected.

## How switching works

ActiveSpace does not switch spaces itself. It sends the keyboard shortcut macOS already has for the space you picked, and macOS does the rest.

That means one mechanism on every display configuration, no private window-server calls, and nothing to break the next time Apple changes how Mission Control works. It also means the animation is Apple's, because it is Apple doing the switching.

The shortcuts live in **System Settings → Keyboard → Keyboard Shortcuts → Mission Control**, as *Switch to Desktop 1*, *Switch to Desktop 2* and so on. They are switched off by default on a new Mac. ActiveSpace's Settings pane lists one row per space showing the key macOS has for it, or telling you plainly that it has none, and a single button turns on every missing one for you. Where macOS already knows a key, that key is kept; where it has none, `control` plus the space number is used, which is macOS's own default.

If a space has no shortcut, the popover cannot reach it. The Settings pane shows which spaces are in that state so you can fix them; the popover itself gives no warning at the point of clicking.

Earlier versions did switch spaces themselves, using synthetic trackpad gestures and private CoreGraphics calls, with an invisible virtual display to make that work on a single-monitor Mac. macOS 27 ended all of it, and deferring to macOS turned out to be simpler, more robust and about a thousand lines lighter.

## Installation

Two formats on every release, both signed and notarised, pick whichever suits:

- **[Installer (`.pkg`)](https://github.com/PerpetualBeta/ActiveSpace/releases/latest/download/ActiveSpace.pkg)** — recommended for first-time installs. Double-click to run; macOS Installer places the app in `/Applications` without quarantine or App Translocation.
- **[Download (`.zip`)](https://github.com/PerpetualBeta/ActiveSpace/releases/latest)** — unzip and drag `ActiveSpace.app` to your Applications folder.

Or install it with [Homebrew](https://brew.sh):

```sh
brew install --cask perpetualbeta/jorvik/activespace
```

Launch ActiveSpace from `/Applications` and grant Accessibility when prompted.

## Settings

Right-click the menu-bar bubble and choose **Settings…**:

- **Switcher** — toggle the space-aware command-Tab replacement.
- **Grid** — optional row width for the popover layout and the up/down navigation hotkeys.
- **Navigation** — **Wrap around at the ends** (on by default). Turn it off for a hard stop at the top and bottom of a column.
- **Switching Spaces: Direct Select** — one row per space, showing the Mission Control shortcut macOS has for it or noting that it has none, with a button that sets up the missing ones.
- **Switching Spaces: Carousel** — the two shortcuts that step one space left or right. ActiveSpace does not send these; they are listed because they are how you move by hand.
- Below both, a button that opens the Mission Control pane if you would rather set these up yourself.
- **ActiveSpace Shortcuts** — Follow App Across Spaces, plus **Navigate Up** and **Navigate Down** when grid layout is on. These are ActiveSpace's own, because macOS has no equivalent. Each can be cleared as well as changed.
- **Permissions** — live status of Accessibility and Input Monitoring with grant buttons.
- **Launch at Login** — start automatically.

Auto-updates are handled by Sparkle. Use the **Check for Updates…** entry in the right-click menu to check on demand.

## Permissions

- **Accessibility** — always required. ActiveSpace switches spaces by sending a keystroke, and macOS only lets a trusted app do that. macOS prompts on first launch.
- **Input Monitoring** — only required if you use the keyboard. It exists for the shortcut listener, which is created only when the space-aware Switcher is on, or Follow App Across Spaces is bound, or grid layout is on with an up/down hotkey bound. Turn all of those off and ActiveSpace never asks for it.

ActiveSpace no longer competes with macOS's own Mission Control shortcuts. It uses them, so there is nothing to disable.

## Architecture

| File | Purpose |
|---|---|
| `ActiveSpaceApp.swift` | `@main` entry; wires `AppDelegate` |
| `AppDelegate.swift` | Status item, event tap, click routing, popover, settings |
| `SpaceObserver.swift` | `@Published` current/total space counts; CGS polling + notifications |
| `SpaceSwitcher.swift` | Works out which space to move to; `MissionControlShortcuts` reads, sends and enables macOS's own shortcuts |
| `WindowFollow.swift` | Per-app "follow across spaces" toggle + toast HUD |
| `MenuBarIcon.swift` | Numbered bubble rendering |
| `SpaceSelectorView.swift` | SwiftUI popover (3+ spaces) |
| `SwitcherController.swift` | State machine for the space-aware command-Tab switcher |
| `SwitcherHUDWindow.swift` | Borderless HUD with proportional icon scaling |
| `SwitcherAppResolver.swift` | Per-window space membership via `SLSCopySpacesForWindows`; pre-warmed app-icon cache |
| `SwitcherAppStack.swift` | Per-space MRU bundle-ID stack |
| `ReconfigurationObserver.swift` | Six-source observer for display/space/screen-lock/poll events |
| `DriftMonitor.swift` | Classifies reconfiguration events; diagnostic logging |
| `ActiveSpaceFingerprint.swift` | Display + Spaces snapshot used for drift diffing |
| `SpacesPlist.swift` | Reads `com.apple.spaces.plist` for visual-order ground truth |
| `Logging.swift` | `aslog(...)` to `~/Library/Logs/ActiveSpace/debug.log`, gated on `ActiveSpace.debugLogging` |
| `CGSPrivate.swift` | Swift bindings for private CoreGraphics, SkyLight and Accessibility APIs |
| `tools/spaceprobe/` | Command-line probe used to measure which switching mechanisms actually work on a given macOS |

## Building

```bash
git clone https://github.com/PerpetualBeta/ActiveSpace.git
open ActiveSpace/ActiveSpace.xcodeproj
# command B to build, command R to run
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
- Accessibility permission, and Input Monitoring only if you use the keyboard features

## Diagnostic logging

ActiveSpace ships with disk logging off. Enable it for support or self-debugging with:

```bash
defaults write cc.jorviksoftware.ActiveSpace ActiveSpace.debugLogging -bool YES
```

Then quit and relaunch. The log lives at `~/Library/Logs/ActiveSpace/debug.log`. Disable again with `-bool NO` (or `defaults delete`) plus another relaunch.

---

ActiveSpace is part of [Jorvik Software](https://jorviksoftware.cc/). If you find it useful, consider [buying me a coffee](https://jorviksoftware.cc/donate).
