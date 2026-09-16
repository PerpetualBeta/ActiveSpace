import AppKit
import CoreGraphics

/// Reads, posts and (on request) enables the Mission Control keyboard shortcuts
/// that macOS uses to switch spaces.
///
/// **Why this exists.** ActiveSpace used to switch spaces itself, by synthesising
/// a trackpad dock-swipe or by calling private CoreGraphics APIs. macOS 27 ended
/// both: the synthetic gesture is ignored outright, and the direct call moves the
/// space counter while leaving every window on screen, which strands the user on
/// a desk they cannot click. Measured on 27.0 build 26A428; see
/// `tools/spaceprobe/`.
///
/// Jonathan's decision, 2026-09-16, and it is the right shape: macOS switches
/// spaces perfectly well, so send it the key the user already has bound and let
/// it do the work. One mechanism for every display configuration, no private
/// API, nothing to break when Apple changes the window server.
///
/// **Where the bindings live.** `com.apple.symbolichotkeys`, key
/// `AppleSymbolicHotKeys`, one entry per shortcut id:
///
///   - `118 + N - 1` → "Switch to Desktop N"
///   - `79` / `81`   → "Move left / right a space"
///
/// Each entry is `{ enabled: Bool, value: { parameters: [char, keyCode, modifiers] } }`
/// where the modifiers use **NSEvent's** flag values, not CoreGraphics'.
enum MissionControlShortcuts {

    struct Binding {
        var keyCode: CGKeyCode
        var flags: CGEventFlags
        var enabled: Bool
    }

    enum Status {
        /// Bound and switched on. The only case that can switch a space.
        case enabled(Binding)
        /// macOS knows a key for it, but the shortcut is switched off.
        case disabled(Binding)
        /// No entry at all. Normal on a fresh Mac beyond the first desktops.
        case missing
    }

    private static let domain = "com.apple.symbolichotkeys" as CFString
    private static let key = "AppleSymbolicHotKeys" as CFString

    /// Keycodes for the digits 1...9, used only when inventing a binding.
    private static let digitKeyCodes: [CGKeyCode] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    static func shortcutID(forDesktop n: Int) -> Int { 118 + n - 1 }

    // MARK: - Reading

    static func status(forDesktop n: Int) -> Status {
        guard let b = binding(id: shortcutID(forDesktop: n)) else { return .missing }
        return b.enabled ? .enabled(b) : .disabled(b)
    }

    /// Read one shortcut. Returns nil when macOS has no entry for it.
    static func binding(id: Int) -> Binding? {
        guard let all = CFPreferencesCopyValue(key, domain,
                                               kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                as? [String: Any],
              let entry = all[String(id)] as? [String: Any],
              let value = entry["value"] as? [String: Any],
              let params = value["parameters"] as? [Any], params.count >= 3,
              let code = (params[1] as? NSNumber)?.intValue,
              let mods = (params[2] as? NSNumber)?.uint64Value else { return nil }
        let enabled = (entry["enabled"] as? Bool) ?? false
        return Binding(keyCode: CGKeyCode(code),
                       flags: cgFlags(fromNSEventFlags: mods),
                       enabled: enabled)
    }

    /// NSEvent modifier flags → CGEventFlags.
    ///
    /// **`0x800000` must be carried across.** It is NSEvent's function-key
    /// marker, and macOS registered these shortcuts with it. Dropping it as
    /// "not a modifier the user holds" was tried on 2026-09-16 and killed the
    /// desktop jumps that had worked three times in a row immediately before.
    private static func cgFlags(fromNSEventFlags mods: UInt64) -> CGEventFlags {
        var f: CGEventFlags = []
        if mods & 0x20000  != 0 { f.insert(.maskShift) }
        if mods & 0x40000  != 0 { f.insert(.maskControl) }
        if mods & 0x80000  != 0 { f.insert(.maskAlternate) }
        if mods & 0x100000 != 0 { f.insert(.maskCommand) }
        if mods & 0x800000 != 0 { f.insert(.maskSecondaryFn) }
        return f
    }

    // MARK: - Posting

    /// Send a shortcut, as though the user had pressed it.
    ///
    /// **Only ever call this with a "Switch to Desktop N" binding.** Posting the
    /// arrow bindings (`Move left/right a space`) opens Mission Control instead
    /// of switching, because the function-key bit reads as the globe key. The
    /// tell, when it happens, is the on-screen window count jumping from a
    /// handful to every window on the Mac. Navigation never needs them: work out
    /// which desktop you want and send that desktop's key.
    static func post(_ b: Binding) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: b.keyCode, keyDown: true),
              let up   = CGEvent(keyboardEventSource: nil, virtualKey: b.keyCode, keyDown: false) else { return }
        down.flags = b.flags
        up.flags = b.flags
        down.post(tap: .cgSessionEventTap)
        usleep(20_000)
        up.post(tap: .cgSessionEventTap)
    }

    // MARK: - Enabling

    enum EnableResult {
        /// It was switched off; now on, with its existing key untouched.
        case switchedOn(Binding)
        /// There was no entry, so one was created. The key was chosen by us.
        case created(Binding)
        /// Already on. Nothing done.
        case alreadyOn(Binding)
        case failed(String)
    }

    /// Turn a desktop's shortcut on, on the user's behalf.
    ///
    /// Two cases, deliberately different:
    ///
    ///   - **An entry exists but is off.** Flip it and change nothing else, so
    ///     the user keeps whatever key they or macOS chose.
    ///   - **No entry exists.** Invent control+digit, which is macOS's own
    ///     historical default for "Switch to Desktop N". Jonathan's call: stick
    ///     with Apple's defaults rather than picking something clever.
    ///
    /// A preference write is not live until the shortcut system reloads, which
    /// `activateSettings -u` does. Verified 2026-09-16 with its own control: with
    /// the shortcut off the key does nothing, and after this call the same key
    /// switches cleanly.
    @discardableResult
    static func enableDesktop(_ n: Int) -> EnableResult {
        guard n >= 1 else { return .failed("desktop \(n) is not a desktop") }
        let id = shortcutID(forDesktop: n)

        var all = (CFPreferencesCopyValue(key, domain,
                                          kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                   as? [String: Any]) ?? [:]

        let result: EnableResult
        if var entry = all[String(id)] as? [String: Any],
           let value = entry["value"] as? [String: Any],
           let params = value["parameters"] as? [Any], params.count >= 3,
           let code = (params[1] as? NSNumber)?.intValue,
           let mods = (params[2] as? NSNumber)?.uint64Value {
            let was = (entry["enabled"] as? Bool) ?? false
            let b = Binding(keyCode: CGKeyCode(code),
                            flags: cgFlags(fromNSEventFlags: mods),
                            enabled: true)
            if was { return .alreadyOn(b) }
            entry["enabled"] = true
            all[String(id)] = entry
            result = .switchedOn(b)
        } else {
            guard n <= digitKeyCodes.count else {
                return .failed("macOS has no default key for desktop \(n)")
            }
            let code = digitKeyCodes[n - 1]
            all[String(id)] = [
                "enabled": true,
                "value": [
                    "type": "standard",
                    // [character, keyCode, modifiers]; 0x40000 is control.
                    "parameters": [NSNumber(value: 65535),
                                   NSNumber(value: Int(code)),
                                   NSNumber(value: 0x40000)]
                ]
            ] as [String: Any]
            result = .created(Binding(keyCode: code, flags: [.maskControl], enabled: true))
        }

        CFPreferencesSetValue(key, all as CFPropertyList, domain,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        reloadShortcuts()
        aslog("MissionControlShortcuts.enableDesktop(\(n)) → \(result)")
        return result
    }

    private static func reloadShortcuts() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath:
            "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings")
        task.arguments = ["-u"]
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            aslog("MissionControlShortcuts: activateSettings failed: \(error)")
        }
    }

    /// Open the Mission Control shortcuts pane, for the "do it yourself" button.
    static func openKeyboardShortcutSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Works out which space to move to, then asks macOS to go there.
///
/// Everything here is index arithmetic plus one call to
/// `MissionControlShortcuts`. The app no longer switches spaces itself; see that
/// type for why.
enum SpaceSwitcher {

    // MARK: - Public API

    /// Prompts for Accessibility permission if not already granted. Posting a
    /// keystroke needs it, exactly as the old synthetic events did.
    static func ensureAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Switch to a specific space index (1-based).
    static func switchTo(index: Int, observer: SpaceObserver) {
        observer.refresh()
        guard index >= 1, index <= observer.totalSpaces else {
            aslog("switchTo(\(index)): out of range (total=\(observer.totalSpaces)) — ignoring")
            return
        }

        let current = observer.currentSpaceIndex
        if index == current {
            aslog("switchTo(\(index)): already on target, skipping")
            return
        }

        guard AXIsProcessTrusted() else {
            aslog("switchTo(\(index)): Accessibility permission not granted")
            ensureAccessibility()
            return
        }

        switch MissionControlShortcuts.status(forDesktop: index) {
        case .enabled(let binding):
            aslog("switchTo(\(index)): sending its Mission Control key (code \(binding.keyCode), flags \(binding.flags.rawValue))")
            MissionControlShortcuts.post(binding)
        case .disabled:
            aslog("switchTo(\(index)): the Mission Control shortcut for this space is switched off")
        case .missing:
            aslog("switchTo(\(index)): macOS has no shortcut bound for this space")
        }
    }

    /// Move to the next space.
    ///
    /// - Linear mode (`rowWidth < 2` or `total ≤ rowWidth`): wraps last → first
    ///   across the whole list.
    /// - Grid mode: wraps within the current row. Next from the last column of
    ///   row N goes to the first column of row N, never crossing into row N+1.
    ///   Symmetric with `switchUp`/`switchDown` (which cycle within columns).
    static func switchNext(rowWidth: Int = 0, wrap: Bool = true, observer: SpaceObserver) {
        horizontalStep(direction: 1, rowWidth: rowWidth, wrap: wrap, observer: observer)
    }

    /// Move to the previous space; same wrap semantics as `switchNext`.
    static func switchPrev(rowWidth: Int = 0, wrap: Bool = true, observer: SpaceObserver) {
        horizontalStep(direction: -1, rowWidth: rowWidth, wrap: wrap, observer: observer)
    }

    /// Linear or row-cycling step. Partial last rows are handled — e.g. with
    /// total=6, rowWidth=4 the second row contains only spaces 5 and 6, so
    /// Next from 6 wraps to 5 and Prev from 5 wraps to 6.
    private static func horizontalStep(direction: Int, rowWidth: Int, wrap: Bool, observer: SpaceObserver) {
        observer.refresh()
        let total = observer.totalSpaces
        guard total > 1 else { return }
        let current = observer.currentSpaceIndex   // 1-based

        let target: Int
        if rowWidth >= 2 && total > rowWidth {
            // Grid mode: move within the current row.
            let row = (current - 1) / rowWidth
            let rowStart = row * rowWidth + 1
            let rowEnd = min(rowStart + rowWidth - 1, total)
            let rowSize = rowEnd - rowStart + 1
            let column = current - rowStart           // 0-based within row
            let nextColumn = column + direction
            if nextColumn < 0 || nextColumn >= rowSize {
                // Past the row edge: wrap within the row, or hard-stop (no-op).
                target = wrap ? rowStart + ((nextColumn % rowSize + rowSize) % rowSize) : current
            } else {
                target = rowStart + nextColumn
            }
        } else {
            // Linear mode: move across the whole list.
            if direction > 0 {
                target = current < total ? current + 1 : (wrap ? 1 : current)
            } else {
                target = current > 1 ? current - 1 : (wrap ? total : current)
            }
        }

        aslog("horizontalStep(\(direction)): current=\(current) total=\(total) rowWidth=\(rowWidth) wrap=\(wrap) → target=\(target)")
        if target != current {
            switchTo(index: target, observer: observer)
        }
    }

    /// Move one "row" up in the conceptual grid (current − rowWidth), with
    /// column-cycling wrap. No-op when grid mode is inactive
    /// (rowWidth < 2 or totalSpaces ≤ rowWidth).
    static func switchUp(rowWidth: Int, wrap: Bool = true, observer: SpaceObserver) {
        step(direction: -1, rowWidth: rowWidth, wrap: wrap, observer: observer)
    }

    /// Move one row down (current + rowWidth), with column-cycling wrap.
    /// No-op when grid mode is inactive.
    static func switchDown(rowWidth: Int, wrap: Bool = true, observer: SpaceObserver) {
        step(direction: 1, rowWidth: rowWidth, wrap: wrap, observer: observer)
    }

    /// Column-cycling navigation. The user thinks of spaces as a grid of
    /// `rowWidth` columns; this moves through column N independently of
    /// other columns. With a partial last row, columns past the partial-row
    /// edge have only one row each, so up/down on those columns no-ops.
    private static func step(direction: Int, rowWidth: Int, wrap: Bool, observer: SpaceObserver) {
        observer.refresh()
        let total = observer.totalSpaces
        guard rowWidth >= 2, total > rowWidth else {
            aslog("step(\(direction)): grid inactive (rowWidth=\(rowWidth) total=\(total)) — ignoring")
            return
        }
        let current = observer.currentSpaceIndex          // 1-based
        let column  = (current - 1) % rowWidth
        let row     = (current - 1) / rowWidth
        let rowsInColumn = (total - column - 1) / rowWidth + 1
        let nextRow = row + direction
        let target: Int
        if nextRow < 0 || nextRow >= rowsInColumn {
            // Past the column edge: wrap within the column, or hard-stop (no-op).
            guard wrap else {
                aslog("step(\(direction)): hard stop at column end (current=\(current)) — ignoring")
                return
            }
            let newRow = (nextRow % rowsInColumn + rowsInColumn) % rowsInColumn
            target = column + newRow * rowWidth + 1
        } else {
            target = column + nextRow * rowWidth + 1
        }
        aslog("step(\(direction)): current=\(current) col=\(column) row=\(row) rowsInCol=\(rowsInColumn) wrap=\(wrap) → target=\(target)")
        if target != current {
            switchTo(index: target, observer: observer)
        }
    }
}
