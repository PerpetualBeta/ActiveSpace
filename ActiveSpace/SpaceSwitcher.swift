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
        /// The same modifiers as NSEvent sees them, for display only. The
        /// function-key bit is deliberately not represented: a user reading
        /// "F5" does not want to see it spelled as fn+F5.
        var nsModifiers: NSEvent.ModifierFlags = []

        /// How to write this shortcut in the UI, e.g. "F5" or "⌃1".
        var display: String {
            JorvikShortcutPanel.displayString(keyCode: UInt16(keyCode), modifiers: nsModifiers)
        }
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

    /// "Move left a space" and "Move right a space".
    ///
    /// Listed in Settings but never posted by the app: sending them opens
    /// Mission Control rather than switching, because the function-key bit in
    /// their stored modifiers reads as the globe key. They are here because the
    /// user presses them, and a missing one is worth telling them about.
    static let moveLeftID = 79
    static let moveRightID = 81

    // MARK: - Reading

    static func status(forDesktop n: Int) -> Status {
        status(id: shortcutID(forDesktop: n))
    }

    static func status(id: Int) -> Status {
        guard let b = binding(id: id) else { return .missing }
        return b.enabled ? .enabled(b) : .disabled(b)
    }

    /// Read one shortcut. Returns nil when macOS has no entry for it.
    ///
    /// **Synchronises first, every time.** CoreFoundation caches another
    /// process's preference domain, so without this a long-running app keeps
    /// reporting whatever it read the first time. Jonathan changed his bindings
    /// from the F-keys to control+digit while the Settings panel was open and it
    /// carried on showing F1 to F8.
    static func binding(id: Int) -> Binding? {
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
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
                       enabled: enabled,
                       nsModifiers: nsModifiers(fromRaw: mods))
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

    /// The subset of the stored modifiers that is worth showing a user.
    private static func nsModifiers(fromRaw mods: UInt64) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if mods & 0x20000  != 0 { f.insert(.shift) }
        if mods & 0x40000  != 0 { f.insert(.control) }
        if mods & 0x80000  != 0 { f.insert(.option) }
        if mods & 0x100000 != 0 { f.insert(.command) }
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
        guard n <= digitKeyCodes.count else {
            return enable(id: shortcutID(forDesktop: n), inventing: nil)
        }
        // macOS's own default for "Switch to Desktop N" is control plus the digit.
        //
        // The character matters. macOS stores the ASCII code of whatever the key
        // produces — control+1 is written as 49, not 65535 — and writing 65535
        // for a key that does produce a character risks a binding it never
        // matches. Observed when Jonathan switched his own bindings from the
        // F-keys (65535, no character) to the digits (49, 50, 51 ...).
        return enable(id: shortcutID(forDesktop: n),
                      inventing: (digitKeyCodes[n - 1], 0x40000, 48 + n))
    }

    /// Turn "Move left a space" on, inventing control+left if macOS has no entry.
    ///
    /// Character 65535 means "this key produces no character", which is correct
    /// for an arrow.
    @discardableResult
    static func enableMoveLeft() -> EnableResult {
        enable(id: moveLeftID, inventing: (123, 0x40000, 65535))
    }

    /// Turn "Move right a space" on, inventing control+right if macOS has none.
    @discardableResult
    static func enableMoveRight() -> EnableResult {
        enable(id: moveRightID, inventing: (124, 0x40000, 65535))
    }

    /// `inventing` is the key to create when macOS has no entry at all. Pass nil
    /// to refuse to invent one, which is right when there is no sensible default.
    @discardableResult
    private static func enable(id: Int, inventing fallback: (CGKeyCode, UInt64, Int)?) -> EnableResult {

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
                            enabled: true,
                            nsModifiers: nsModifiers(fromRaw: mods))
            if was { return .alreadyOn(b) }
            entry["enabled"] = true
            all[String(id)] = entry
            result = .switchedOn(b)
        } else {
            guard let (code, mods, character) = fallback else {
                return .failed("macOS has no default key for shortcut \(id)")
            }
            all[String(id)] = [
                "enabled": true,
                "value": [
                    "type": "standard",
                    // [character, keyCode, modifiers]; 0x40000 is control.
                    "parameters": [NSNumber(value: character),
                                   NSNumber(value: Int(code)),
                                   NSNumber(value: Int(mods))]
                ]
            ] as [String: Any]
            result = .created(Binding(keyCode: code,
                                      flags: cgFlags(fromNSEventFlags: mods),
                                      enabled: true,
                                      nsModifiers: nsModifiers(fromRaw: mods)))
        }

        CFPreferencesSetValue(key, all as CFPropertyList, domain,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        reloadShortcuts()
        aslog("MissionControlShortcuts.enable(id: \(id)) → \(result)")
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


/// Watches the menu bar for a few seconds after a switch and logs it if it goes.
///
/// The bar's backing window sits at layer 24 and leaves the on-screen window
/// list whenever the bar is not drawn. Matched on layer and geometry only:
/// `kCGWindowName` is empty without Screen Recording permission, and owner names
/// localise. The primitive comes from RainbowApple 2.0.15.
enum MenuBarWatch {

    static func isVisible() -> Bool {
        let menuLayer = Int(CGWindowLevelForKey(.mainMenuWindow))
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        for w in raw {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == menuLayer,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let y = b["Y"] as? Double,
                  let width = b["Width"] as? Double else { continue }
            if abs(y) < 2 {
                for screen in NSScreen.screens where width >= screen.frame.width / 2 {
                    return true
                }
            }
        }
        return false
    }

    /// Sample for `seconds` after a switch, and log only if the bar goes away.
    /// Silence in the log means it stayed up, which is the answer we want.
    static func observeAfterSwitch(to index: Int, seconds: Double = 4.0) {
        guard debugLoggingIsOn else { return }
        var elapsed = 0.0
        var goneAt: Double? = nil
        func tick() {
            guard elapsed < seconds else {
                if let goneAt {
                    aslog(String(format: "MenuBarWatch: after switchTo(%d) the menu bar went at %.2fs and was STILL GONE at %.1fs",
                                 index, goneAt, seconds))
                }
                return
            }
            elapsed += 0.1
            if isVisible() {
                if let goneAt {
                    aslog(String(format: "MenuBarWatch: after switchTo(%d) the menu bar went at %.2fs, back after %.2fs",
                                 index, goneAt, elapsed - goneAt))
                    return
                }
            } else if goneAt == nil {
                goneAt = elapsed
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: tick)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: tick)
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
            handBackTheMenuBar()
            MenuBarWatch.observeAfterSwitch(to: index)
        case .disabled:
            aslog("switchTo(\(index)): the Mission Control shortcut for this space is switched off")
        case .missing:
            aslog("switchTo(\(index)): macOS has no shortcut bound for this space")
        }
    }

    /// Give the menu bar an owner after a switch the popover started.
    ///
    /// **Removed in the macOS 27 cull and restored the same day**, which is the
    /// interesting part. It used to sit after the synthetic gesture, and the
    /// reasoning for dropping it was that macOS handles focus itself when it
    /// performs the switch. That is true when the USER presses the key:
    /// ActiveSpace is not active, and whichever app already owned the menu bar
    /// keeps it.
    ///
    /// It is false when the popover has just run `NSApp.activate`. ActiveSpace
    /// is then the active app, and being an accessory it owns no menu bar, so on
    /// arrival there is nothing to draw one.
    ///
    /// Measured 2026-09-16, all four combinations:
    ///
    ///   - keystroke only, any target, 10 switches   bar never went
    ///   - keystroke only, space 1, 6 switches       bar never went
    ///   - popover to 6 and to 8                     bar never went
    ///   - popover to space 1, 3 times               bar went every time, 3.2s+
    ///
    /// **Why space 1 specifically is NOT explained.** The obvious theory was that
    /// every window there is assigned to all desktops, so nothing arrives when
    /// you land and macOS has no new window to focus — but Jonathan corrected it:
    /// Music lives on space 1 and only there, so something does arrive. The
    /// theory is dead and the question is open. What is measured is that the bar
    /// only goes when the popover has made us active, which is what this
    /// addresses; the log line below records what it hands the bar to, which is
    /// the evidence needed to finish the explanation.
    ///
    /// Only runs when we are the active app, so a keyboard switch never steals
    /// the user's focus from whatever they were using.
    private static func handBackTheMenuBar() {
        guard NSApp.isActive else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard let windowList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
            ) as? [[String: Any]] else { return }

            for window in windowList {
                guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                      let pid = window[kCGWindowOwnerPID as String] as? pid_t else { continue }
                if let app = NSRunningApplication(processIdentifier: pid),
                   app.activationPolicy == .regular, !app.isHidden {
                    app.activate()
                    aslog("handBackTheMenuBar: activated \(app.localizedName ?? "?") (pid \(pid))")
                    return
                }
            }
            aslog("handBackTheMenuBar: no suitable window found — the bar may stay blank")
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
