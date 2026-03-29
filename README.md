# ActiveSpace

A macOS menu-bar app that shows your current Mission Control space number and lets you switch spaces by clicking.

## What it does

- Shows the current space number as a numbered bubble in the menu bar
- **1 space:** icon only, no interaction
- **2 spaces:** left-click toggles between them
- **3+ spaces:** left-click opens a popover with numbered buttons — click any to jump directly to it
- **Right-click:** Quit

The icon updates instantly when you switch spaces via Mission Control, trackpad gestures, or keyboard shortcuts.

## Architecture

| File | Purpose |
|---|---|
| `ActiveSpaceApp.swift` | `@main` entry; wires `AppDelegate` via `@NSApplicationDelegateAdaptor` |
| `AppDelegate.swift` | Owns the `NSStatusItem`, routes clicks, manages the popover |
| `SpaceObserver.swift` | `ObservableObject` that tracks current space index and total space count |
| `SpaceSwitcher.swift` | Executes space switches via AppleScript keyboard simulation |
| `MenuBarIcon.swift` | Renders the numbered bubble icon dynamically |
| `SpaceSelectorView.swift` | SwiftUI popover UI showing numbered space buttons |
| `CGSPrivate.swift` | Swift bindings for private CoreGraphics space APIs |

### SpaceObserver

Queries the private CoreGraphics `CGSCopyManagedDisplaySpaces` API to enumerate all spaces across all displays and identify which is current. Refreshes via three mechanisms:

1. `NSWorkspace.activeSpaceDidChangeNotification` — fires on every space switch
2. `NSApplication.didChangeScreenParametersNotification` — fires when spaces are added/removed via Mission Control
3. A 2-second poll timer — backstop for edge cases where notifications don't fire

Publishes `@Published currentSpaceIndex` (1-based) and `@Published totalSpaces`, which AppDelegate subscribes to via Combine to update the icon.

### SpaceSwitcher

Switches spaces by sending `Control+Arrow` key events via `NSAppleScript` targeting System Events. Uses key codes 123 (left arrow) and 124 (right arrow), with a 0.35s delay between presses when jumping multiple spaces. Runs in the app's TCC context — requires Accessibility permission to be granted once.

### MenuBarIcon

Renders the menu bar icon dynamically using `NSImage` with `lockFocus`. Draws a filled rounded-rect bubble sized to the space number text, with a 7pt horizontal and 3pt vertical padding and a minimum width of 22pt. Uses `NSColor.controlAccentColor` when highlighted (active space in popover), dark gray otherwise. `isTemplate = false` so the exact colours are preserved.

### Click routing (AppDelegate)

```
Left-click
├── 1 space  → no-op
├── 2 spaces → SpaceSwitcher.toggle()
└── 3+ spaces → show NSPopover with SpaceSelectorView

Right-click → Quit menu
```

### Private API usage

`CGSPrivate.swift` binds three private CoreGraphics symbols using `@_silgen_name`:

- `CGSMainConnectionID()` — returns the current process's CG connection
- `CGSCopyManagedDisplaySpaces(_:)` — returns an array of display dictionaries, each containing a `Spaces` array and a `Current Space` entry
- `CGSGetWorkspace(_:_:)` — legacy workspace query (used as fallback)

These APIs have been stable across macOS versions and are used by several open-source space utilities (WhichSpace, Spaceman, etc.).

## Building

```bash
open ActiveSpace.xcodeproj
# Then Cmd+B / Cmd+R in Xcode
```

Or from the command line:

```bash
xcodebuild -project ActiveSpace.xcodeproj \
  -target ActiveSpace \
  -configuration Release \
  build
```

## Requirements

- macOS 13.0+
- **Accessibility permission** — required for AppleScript key simulation. macOS will prompt on first space switch attempt.

---

ActiveSpace is part of [Jorvik Software](https://jorviksoftware.cc/). If you find it useful, consider [buying me a coffee](https://jorviksoftware.cc/donate).
