// spaceprobe — determine which space-switching mechanism still works on macOS 27.
//
// ActiveSpace stopped switching spaces after the macOS 27.0 upgrade. Its log
// proves it posts the swipe and the space never moves. This probe tries each
// candidate mechanism in turn and MEASURES the result by re-reading the current
// space from CGS, so the answer is observed rather than assumed.
//
// It is deliberately a plain CLI: ActiveSpace itself cannot be hand-installed
// for testing because its keep-alive agent is under a notarisation launch
// constraint.

import AppKit
import ApplicationServices

// MARK: - Output
//
// Everything printed is also appended to ~/Library/Logs/spaceprobe.log. A bare
// CLI cannot reliably hold an Accessibility grant, because macOS attributes the
// permission to the responsible parent process. Wrapped in an .app bundle and
// launched with `open` it gets its own identity and the grant sticks — but then
// stdout goes nowhere, so the log is the only way to read the result.

let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/spaceprobe.log")

func say(_ s: String = "") {
    print(s)
    if let data = (s + "\n").data(using: .utf8) {
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}

// MARK: - Private API (copied verbatim from ActiveSpace/CGSPrivate.swift)

typealias CGSConnectionID = UInt32

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ conn: CGSConnectionID) -> CFArray

@_silgen_name("CGSManagedDisplaySetCurrentSpace")
func CGSManagedDisplaySetCurrentSpace(_ conn: CGSConnectionID, _ display: CFString, _ spaceID: UInt64)

@_silgen_name("CGSHideSpaces")
func CGSHideSpaces(_ conn: CGSConnectionID, _ spaces: CFArray)

@_silgen_name("CGSShowSpaces")
func CGSShowSpaces(_ conn: CGSConnectionID, _ spaces: CFArray)

// MARK: - Reading the current space (mirrors SpaceObserver.refresh)

struct Snapshot {
    var displayID: String
    var spaceIDs: [Int]
    var currentID: Int
    var currentIndex: Int      // 1-based
    var total: Int { spaceIDs.count }
}

func readSpaces() -> Snapshot? {
    let conn = CGSMainConnectionID()
    guard let raw = CGSCopyManagedDisplaySpaces(conn) as? [[String: Any]] else { return nil }

    var chosen: [String: Any]?
    for display in raw {
        if chosen == nil { chosen = display }
        if let current = display["Current Space"] as? [String: Any],
           let type = current["type"] as? Int, type == 0 {
            chosen = display
            break
        }
    }
    guard let chosen else { return nil }

    let displayID = chosen["Display Identifier"] as? String ?? ""
    var ids: [Int] = []
    if let spaces = chosen["Spaces"] as? [[String: Any]] {
        for s in spaces where (s["type"] as? Int ?? 0) == 0 {
            if let id = s["ManagedSpaceID"] as? Int { ids.append(id) }
        }
    }
    let currentID = (chosen["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int ?? -1
    let idx = (ids.firstIndex(of: currentID) ?? 0) + 1
    return Snapshot(displayID: displayID, spaceIDs: ids, currentID: currentID, currentIndex: idx)
}

// MARK: - Gesture posting

let fieldEventSubType       = CGEventField(rawValue: 55)!
let fieldHIDType            = CGEventField(rawValue: 110)!
let fieldScrollY            = CGEventField(rawValue: 119)!
let fieldSwipeMotion        = CGEventField(rawValue: 123)!
let fieldSwipeProgress      = CGEventField(rawValue: 124)!
let fieldSwipeVelocityX     = CGEventField(rawValue: 129)!
let fieldSwipeVelocityY     = CGEventField(rawValue: 130)!
let fieldGesturePhase       = CGEventField(rawValue: 132)!
let fieldScrollFlagBits     = CGEventField(rawValue: 135)!
let fieldZoomDeltaX         = CGEventField(rawValue: 139)!

let kCGSEventGesture:         Int64 = 29
let kCGSEventDockControl:     Int64 = 30
let kIOHIDEventTypeDockSwipe: Int64 = 23
let kGestureMotionHorizontal: Int64 = 1
let kPhaseBegan:              Int64 = 1
let kPhaseEnded:              Int64 = 4

/// Post one phase of a dock swipe. `progress` and `velocity` are ignored for
/// the "began" phase, matching how a real trackpad gesture is encoded.
func postPhase(_ phase: Int64, right: Bool, progress: Double, velocity: Double) {
    let flagDir: Int64 = right ? 1 : 0

    guard let gesture = CGEvent(source: nil), let dock = CGEvent(source: nil) else { return }

    gesture.type = CGEventType(rawValue: UInt32(kCGSEventGesture))!
    gesture.setIntegerValueField(fieldEventSubType, value: kCGSEventGesture)

    dock.type = CGEventType(rawValue: UInt32(kCGSEventDockControl))!
    dock.setIntegerValueField(fieldEventSubType,   value: kCGSEventDockControl)
    dock.setIntegerValueField(fieldHIDType,        value: kIOHIDEventTypeDockSwipe)
    dock.setIntegerValueField(fieldGesturePhase,   value: phase)
    dock.setIntegerValueField(fieldScrollFlagBits, value: flagDir)
    dock.setIntegerValueField(fieldSwipeMotion,    value: kGestureMotionHorizontal)
    dock.setDoubleValueField(fieldScrollY,         value: 0)
    dock.setDoubleValueField(fieldZoomDeltaX,      value: Double(Float.leastNonzeroMagnitude))
    if progress != 0 { dock.setDoubleValueField(fieldSwipeProgress, value: progress) }
    if velocity != 0 {
        dock.setDoubleValueField(fieldSwipeVelocityX, value: velocity)
        dock.setDoubleValueField(fieldSwipeVelocityY, value: 0)
    }

    dock.post(tap: .cgSessionEventTap)
    gesture.post(tap: .cgSessionEventTap)
}

/// Exactly what ActiveSpace 2.1.19 does today: began then ended, no gap,
/// no intermediate phase. Expected to fail on macOS 27.
func legacySwipe(right: Bool) {
    let progress: Double = right ?  2.0 : -2.0
    let velocity: Double = right ? 400.0 : -400.0
    postPhase(kPhaseBegan, right: right, progress: 0, velocity: 0)
    postPhase(kPhaseEnded, right: right, progress: progress, velocity: velocity)
}

/// The InstantSpaceSwitcher recipe: three phases, paced. Delay and the value
/// used for the "changed" phase are both knobs, because the changed constant is
/// reverse-engineered and 2 is an inference from Began=1 / Ended=4.
func pacedSwipe(right: Bool, delayMs: UInt32, changedPhase: Int64) {
    let progress: Double = right ?  2.0 : -2.0
    let velocity: Double = right ? 400.0 : -400.0
    postPhase(kPhaseBegan, right: right, progress: 0, velocity: 0)
    usleep(delayMs * 1000)
    postPhase(changedPhase, right: right, progress: progress / 2, velocity: 0)
    usleep(delayMs * 1000)
    postPhase(kPhaseEnded, right: right, progress: progress, velocity: velocity)
}

/// The direct CGS call ActiveSpace uses on single-display setups. No synthetic
/// input at all, so it needs no Accessibility grant.
func directSwitch(to targetID: Int, from currentID: Int, displayID: String) {
    let conn = CGSMainConnectionID()
    CGSHideSpaces(conn, [currentID] as CFArray)
    CGSShowSpaces(conn, [targetID] as CFArray)
    CGSManagedDisplaySetCurrentSpace(conn, displayID as CFString, UInt64(targetID))
}

/// A fingerprint of what is actually on screen. `optionOnScreenOnly` reports
/// windows on the CURRENT space only, so if the space genuinely changed the set
/// must change too. This is what distinguishes a real switch from CGS merely
/// flipping a counter while the windows stay put — the documented failure mode
/// of the direct call on multi-display setups.
func onScreenWindows() -> [String] {
    guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
    var out: [String] = []
    for w in raw {
        guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
        let num = w[kCGWindowNumber as String] as? Int ?? -1
        out.append("\(owner)#\(num)")
    }
    return out.sorted()
}


// MARK: - SkyLight, loaded via dlsym (copied from ActiveSpace/CGSPrivate.swift)

import Darwin

private let skylight: UnsafeMutableRawPointer? = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

typealias SLSEnsureSpaceSwitchFn = @convention(c) (CGSConnectionID) -> OSStatus
typealias SLSSpaceResetMenuBarFn = @convention(c) (CGSConnectionID, UInt64) -> OSStatus

func SLSEnsureSpaceSwitchToActiveProcess(_ conn: CGSConnectionID) -> OSStatus {
    guard let skylight, let sym = dlsym(skylight, "SLSEnsureSpaceSwitchToActiveProcess") else { return -1 }
    return unsafeBitCast(sym, to: SLSEnsureSpaceSwitchFn.self)(conn)
}

func SLSSpaceResetMenuBar(_ conn: CGSConnectionID, _ spaceID: UInt64) -> OSStatus {
    guard let skylight, let sym = dlsym(skylight, "SLSSpaceResetMenuBar") else { return -1 }
    return unsafeBitCast(sym, to: SLSSpaceResetMenuBarFn.self)(conn, spaceID)
}

/// What ActiveSpace's directSwitch ACTUALLY does: the CGS calls plus two
/// SkyLight calls. The source speculates SLSEnsureSpaceSwitchToActiveProcess
/// is "the missing step that prevents window bleed-through" — this tests it.
func directSwitchFull(to targetID: Int, from currentID: Int, displayID: String) {
    let conn = CGSMainConnectionID()
    CGSHideSpaces(conn, [currentID] as CFArray)
    CGSShowSpaces(conn, [targetID] as CFArray)
    CGSManagedDisplaySetCurrentSpace(conn, displayID as CFString, UInt64(targetID))
    let rc = SLSEnsureSpaceSwitchToActiveProcess(conn)
    let mrc = SLSSpaceResetMenuBar(conn, UInt64(targetID))
    say("     SLSEnsureSpaceSwitchToActiveProcess → \(rc), SLSSpaceResetMenuBar → \(mrc)")
}


// MARK: - Deferring to macOS instead of faking gestures
//
// Jonathan's design, 2026-09-16. macOS already switches spaces perfectly; the
// only reason ActiveSpace ever synthesised a gesture was to avoid the animation.
// Two days of measurement later every synthetic route is either dead (gesture)
// or corrupting (direct CGS bleed-through), while macOS's own path worked
// flawlessly throughout. So read what the user has bound in Mission Control and
// send that key, rather than fighting the window server.
//
// The bindings live in com.apple.symbolichotkeys under AppleSymbolicHotKeys:
//   79 / 81 = move left / right a space
//   118...  = switch to desktop 1, 2, 3 ...
// Each entry is { enabled: Bool, value: { parameters: [char, keycode, modifiers] } }.
// The modifier field uses NSEvent flag values, which must be translated to
// CGEventFlags before posting.

struct Binding {
    var keyCode: CGKeyCode
    var flags: CGEventFlags
    var enabled: Bool
}

func readBinding(id: Int) -> Binding? {
    guard let d = UserDefaults(suiteName: "com.apple.symbolichotkeys"),
          let all = d.dictionary(forKey: "AppleSymbolicHotKeys"),
          let entry = all[String(id)] as? [String: Any] else { return nil }
    let enabled = (entry["enabled"] as? Bool) ?? false
    guard let value = entry["value"] as? [String: Any],
          let params = value["parameters"] as? [Any], params.count >= 3,
          let code = (params[1] as? NSNumber)?.intValue,
          let mods = (params[2] as? NSNumber)?.uint64Value else { return nil }

    // NSEvent flags to CGEventFlags. The function bit (0x800000) is set by the
    // system for arrow and F keys; post it too, because the symbolic hotkey was
    // registered with it.
    var f: CGEventFlags = []
    if mods & 0x20000  != 0 { f.insert(.maskShift) }
    if mods & 0x40000  != 0 { f.insert(.maskControl) }
    if mods & 0x80000  != 0 { f.insert(.maskAlternate) }
    if mods & 0x100000 != 0 { f.insert(.maskCommand) }
    // 0x800000 is NSEvent's function-key bit, and it MUST be posted. macOS
    // registered these hotkeys with it, so without it nothing matches: dropping
    // it killed the F-key desktop jumps that had just worked three times in a
    // row. Measured both ways 2026-09-16.
    if mods & 0x800000 != 0 { f.insert(.maskSecondaryFn) }
    return Binding(keyCode: CGKeyCode(code), flags: f, enabled: enabled)
}

func postBinding(_ b: Binding) {
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: b.keyCode, keyDown: true),
          let up   = CGEvent(keyboardEventSource: nil, virtualKey: b.keyCode, keyDown: false) else { return }
    down.flags = b.flags
    up.flags = b.flags
    down.post(tap: .cgSessionEventTap)
    usleep(20_000)
    up.post(tap: .cgSessionEventTap)
}


// MARK: - Enabling a Mission Control shortcut on the user's behalf
//
// Jonathan's call, 2026-09-16: offering to switch the shortcut on is better UX
// than sending the user to System Settings and hoping. It writes another app's
// preference domain, which is why it is prototyped and measured here first.
//
// Two cases, and they are not the same:
//
//   - The entry EXISTS but is disabled. Flip `enabled` and change nothing else,
//     so the user keeps whatever key macOS already had for it.
//   - The entry is ABSENT. One must be invented. Use control+digit, macOS's own
//     historical binding for "Switch to Desktop N", and report what was chosen
//     rather than assigning silently.
//
// A write is not live until the shortcut system reloads it. `activateSettings -u`
// is the supported nudge.

let symbolicDomain = "com.apple.symbolichotkeys" as CFString
let symbolicKey = "AppleSymbolicHotKeys" as CFString

/// Keycodes for the digits 1...9, for the invented fallback binding.
let digitKeyCodes: [CGKeyCode] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

func enableDesktopShortcut(_ n: Int) -> String {
    let id = 118 + n - 1
    guard n >= 1, n <= 9 else { return "desktop \(n): out of range for a digit binding" }

    var all = (CFPreferencesCopyValue(symbolicKey, symbolicDomain,
                                      kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
               as? [String: Any]) ?? [:]

    var note: String
    if var entry = all[String(id)] as? [String: Any],
       let value = entry["value"] as? [String: Any],
       let params = value["parameters"] as? [Any], params.count >= 3 {
        let wasEnabled = (entry["enabled"] as? Bool) ?? false
        entry["enabled"] = true
        all[String(id)] = entry
        note = wasEnabled ? "desktop \(n): already enabled, rewritten unchanged"
                          : "desktop \(n): existing binding enabled, key untouched"
    } else {
        let code = digitKeyCodes[n - 1]
        let entry: [String: Any] = [
            "enabled": true,
            "value": [
                "type": "standard",
                // [character, keyCode, modifiers] — 0x40000 is control.
                "parameters": [NSNumber(value: 65535), NSNumber(value: Int(code)), NSNumber(value: 0x40000)]
            ]
        ]
        all[String(id)] = entry
        note = "desktop \(n): no entry existed, created control+\(n)"
    }

    CFPreferencesSetValue(symbolicKey, all as CFPropertyList, symbolicDomain,
                          kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    CFPreferencesSynchronize(symbolicDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)

    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings")
    task.arguments = ["-u"]
    do { try task.run(); task.waitUntilExit() } catch { note += " (activateSettings failed: \(error))" }

    return note
}


/// Flip an existing Mission Control shortcut on or off, leaving its key alone.
/// Returns a description of what happened, or nil if there was no entry.
func setDesktopShortcutEnabled(_ n: Int, _ on: Bool) -> String? {
    let id = 118 + n - 1
    guard var all = CFPreferencesCopyValue(symbolicKey, symbolicDomain,
                                           kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            as? [String: Any],
          var entry = all[String(id)] as? [String: Any] else { return nil }
    let was = (entry["enabled"] as? Bool) ?? false
    entry["enabled"] = on
    all[String(id)] = entry
    CFPreferencesSetValue(symbolicKey, all as CFPropertyList, symbolicDomain,
                          kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    CFPreferencesSynchronize(symbolicDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings")
    task.arguments = ["-u"]
    try? task.run()
    task.waitUntilExit()
    return "desktop \(n): \(was ? "on" : "off") -> \(on ? "on" : "off")"
}

// MARK: - Measurement harness

/// Service the runloop, then re-read. The runloop pump matters: a CLI that
/// exits immediately can die before the session event tap delivers the events.
func settle(_ seconds: Double) {
    CFRunLoopRunInMode(.defaultMode, seconds, false)
}

@discardableResult
func attempt(_ name: String, _ body: (Snapshot) -> Void) -> Bool {
    guard let before = readSpaces() else { print("  \(name): cannot read spaces"); return false }
    let winBefore = onScreenWindows()
    say("  \(name):")
    say("     before  space \(before.currentIndex) of \(before.total)  (id \(before.currentID)), \(winBefore.count) windows on screen")
    body(before)
    settle(1.0)
    guard let after = readSpaces() else { print("     after   cannot read spaces"); return false }
    let winAfter = onScreenWindows()
    let moved = after.currentID != before.currentID

    // Distinguish a clean switch from bleed-through, which the earlier version of
    // this check could not do. "The window set changed" is satisfied by BOTH a
    // real switch and by windows from the old space staying while new ones
    // arrive — and that second case is precisely the bug the virtual display was
    // built to prevent (commit 009f653: CGSManagedDisplaySetCurrentSpace "only
    // composites windows from the target space ... causing windows to bleed
    // across spaces"). So count departures, not just difference.
    let b = Set(winBefore), a = Set(winAfter)
    let left = b.subtracting(a).count       // windows that went away: proof the old space left
    let arrived = a.subtracting(b).count    // windows that appeared: proof the new space came
    let stayed = b.intersection(a).count

    say("     after   space \(after.currentIndex) of \(after.total)  (id \(after.currentID)), \(winAfter.count) windows on screen")
    say("     windows \(left) left, \(arrived) arrived, \(stayed) stayed")

    let clean = moved && left > 0 && arrived > 0
    if !moved {
        say("     RESULT  did not move ✗")
    } else if left == 0 && arrived > 0 {
        say("     RESULT  BLEED-THROUGH ✗ — every old window is still on screen and new ones joined")
    } else if left == 0 {
        say("     RESULT  counter moved, nothing on screen changed ✗ — windows did not follow")
    } else {
        say("     RESULT  CLEAN SWITCH ✓ — the old space left and the new one arrived")
    }
    return clean
}

/// Which way can we move from here without falling off the end?
func direction(_ s: Snapshot) -> Bool { s.currentIndex < s.total }

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())
let mode = args.first ?? "report"
let delayMs = UInt32(args.count > 1 ? Int(args[1]) ?? 10 : 10)
let changedPhase = Int64(args.count > 2 ? Int(args[2]) ?? 2 : 2)

say("spaceprobe — macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
let trusted = AXIsProcessTrusted()
say("Accessibility trusted: \(trusted ? "YES" : "NO  ← synthetic events will be ignored")")
if !trusted && (mode == "legacy" || mode == "paced" || mode == "all" || mode == "sweep" || mode == "defer" || mode == "prompt") {
    say("Asking macOS for Accessibility. Approve it, then run this again.")
    AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    if mode != "prompt" {
        say("Not running the gesture tests without permission — a refusal would look")
        say("exactly like the mechanism being dead, and that would be a false result.")
        exit(2)
    }
    exit(0)
}
say("NSScreen.screens.count: \(NSScreen.screens.count)")
if let s = readSpaces() {
    say("Display \"\(s.displayID)\": on space \(s.currentIndex) of \(s.total), ids \(s.spaceIDs)")
} else {
    say("Could not read spaces")
    exit(1)
}
say("")

switch mode {
case "report", "windows":
    say("On-screen windows (CGWindowList reports the CURRENT space only):")
    if let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
        for w in raw {
            let layer = w[kCGWindowLayer as String] as? Int ?? -1
            guard layer == 0 else { continue }
            let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
            let name = w[kCGWindowName as String] as? String ?? ""
            var box = ""
            if let b = w[kCGWindowBounds as String] as? [String: Any],
               let x = b["X"] as? Double, let y = b["Y"] as? Double,
               let ww = b["Width"] as? Double, let hh = b["Height"] as? Double {
                box = "\(Int(x)),\(Int(y)) \(Int(ww))x\(Int(hh))"
            }
            say("   \(owner.padding(toLength: 22, withPad: " ", startingAt: 0)) \(box.padding(toLength: 20, withPad: " ", startingAt: 0)) \(name.prefix(40))")
        }
    }
    say("")
    say("Read-only. Nothing posted.")

case "legacy":
    guard let s = readSpaces() else { exit(1) }
    attempt("legacy (began+ended, no gap) — what ActiveSpace does today") { _ in
        legacySwipe(right: direction(s))
    }

case "paced":
    guard let s = readSpaces() else { exit(1) }
    attempt("paced (began→changed→ended, \(delayMs)ms, changed=\(changedPhase))") { _ in
        pacedSwipe(right: direction(s), delayMs: delayMs, changedPhase: changedPhase)
    }

case "direct":
    say("NOTE: measured 2026-09-15 as counter-moves-but-windows-do-not on the")
    say("built-in display plus our OWN virtual display. Two REAL displays are a")
    say("different configuration and are the point of running this. If it fails,")
    say("recover with control+arrow or a trackpad swipe.")
    guard let s = readSpaces() else { exit(1) }
    let target = direction(s) ? s.spaceIDs[s.currentIndex] : s.spaceIDs[s.currentIndex - 2]
    let startID = s.currentID
    attempt("direct (CGSManagedDisplaySetCurrentSpace)") { b in
        directSwitch(to: target, from: b.currentID, displayID: b.displayID)
    }
    // Always put the desk back: this runs on a machine in active use.
    if let now = readSpaces(), now.currentID != startID {
        say("     restoring space \(s.currentIndex)...")
        directSwitch(to: startID, from: now.currentID, displayID: now.displayID)
        settle(1.0)
        if let back = readSpaces() {
            say("     back on space \(back.currentIndex)\(back.currentID == startID ? "" : "  ← RESTORE FAILED")")
        }
    }

case "all":
    // Only the gesture mechanisms. `direct` is deliberately NOT included: it was
    // measured on 2026-09-15 to move the space counter while leaving every window
    // on screen, which hands focus to an app whose windows are elsewhere and
    // leaves the desk unusable until a real switch resyncs WindowServer. It cost
    // Jonathan a wedged session once; it does not get to do that twice.
    let start = readSpaces()!
    say("Starting on space \(start.currentIndex) of \(start.total).")
    say("Each test moves one space. Whichever mechanism works is used to move back.")
    say("")

    var results: [(String, Bool)] = []
    var lastWorking: ((Bool) -> Void)? = nil

    if let s = readSpaces() {
        let ok = attempt("1. legacy — began+ended, no gap (what ActiveSpace does today)") { _ in
            legacySwipe(right: direction(s))
        }
        results.append(("legacy", ok))
        if ok { lastWorking = { r in legacySwipe(right: r) } }
    }
    say("")

    if let s = readSpaces() {
        let ok = attempt("2. paced — began→changed→ended, \(delayMs)ms apart, changed=\(changedPhase)") { _ in
            pacedSwipe(right: direction(s), delayMs: delayMs, changedPhase: changedPhase)
        }
        results.append(("paced", ok))
        if ok { lastWorking = { r in pacedSwipe(right: r, delayMs: delayMs, changedPhase: changedPhase) } }
    }
    say("")

    // Walk back with a mechanism that genuinely moves windows, one space at a time.
    if let now = readSpaces(), now.currentIndex != start.currentIndex {
        if let move = lastWorking {
            say("Walking back to space \(start.currentIndex)...")
            var guard_ = 0
            while let cur = readSpaces(), cur.currentIndex != start.currentIndex, guard_ < 12 {
                move(cur.currentIndex < start.currentIndex)
                settle(0.4)
                guard_ += 1
            }
            if let back = readSpaces() {
                say("  now on space \(back.currentIndex)\(back.currentIndex == start.currentIndex ? "" : "  ← switch back by hand")")
            }
        } else {
            say("Moved but nothing worked to move back — switch back by hand (F3).")
        }
    }

    say("")
    say("SUMMARY")
    for (name, ok) in results {
        say("  \(name.padding(toLength: 8, withPad: " ", startingAt: 0))  \(ok ? "WORKS — windows followed" : "dead")")
    }
    say("  direct    dead (measured separately: counter moves, windows do not)")

case "direct-full":
    say("NOTE: this is what ActiveSpace itself runs on a single display. On two")
    say("REAL displays it is untested. If it fails, recover with control+arrow.")
    guard let s = readSpaces() else { exit(1) }
    let target = direction(s) ? s.spaceIDs[s.currentIndex] : s.spaceIDs[s.currentIndex - 2]
    let startID = s.currentID
    attempt("direct-full (CGS + SLSEnsureSpaceSwitch + SLSSpaceResetMenuBar)") { b in
        directSwitchFull(to: target, from: b.currentID, displayID: b.displayID)
    }
    if let now = readSpaces(), now.currentID != startID {
        say("     restoring space \(s.currentIndex)...")
        directSwitchFull(to: startID, from: now.currentID, displayID: now.displayID)
        settle(1.0)
        if let back = readSpaces() {
            say("     back on space \(back.currentIndex)\(back.currentID == startID ? "" : "  ← RESTORE FAILED")")
        }
    }

case "sweep":
    // One Accessibility grant buys a whole experiment. Both unknowns in the
    // paced recipe are guesses: the value of the "changed" phase (inferred from
    // Began=1 / Ended=4) and how long the Dock needs between phases. Sweep them
    // rather than shipping another inference.
    guard let start = readSpaces() else { exit(1) }
    say("Sweeping the paced-gesture recipe. Start: space \(start.currentIndex) of \(start.total).")
    say("Each combination gets one single-space swipe. A hit stops the sweep.")
    say("")

    let phases: [Int64] = [2, 3, 8, 4]
    let delays: [UInt32] = [10, 25, 60, 120]
    var hit: (Int64, UInt32)? = nil

    outer: for ph in phases {
        for d in delays {
            guard let s = readSpaces() else { break outer }
            let before = s.currentID
            pacedSwipe(right: direction(s), delayMs: d, changedPhase: ph)
            settle(0.8)
            guard let after = readSpaces() else { break outer }
            let moved = after.currentID != before
            say("  changed=\(ph) delay=\(d)ms  \(moved ? "MOVED" : "no")")
            if moved { hit = (ph, d); break outer }
        }
    }

    say("")
    if let (ph, d) = hit {
        say("RESULT: paced gesture works with changedPhase=\(ph), delay=\(d)ms")
        say("  defaults write cc.jorviksoftware.ActiveSpace ActiveSpace.gestureChangedPhase -int \(ph)")
        say("  defaults write cc.jorviksoftware.ActiveSpace ActiveSpace.gesturePhaseDelayMs -int \(d)")
    } else {
        say("RESULT: no combination moved a space.")
        say("Pacing is not the answer. The remaining candidate is a real IOHIDEvent")
        say("attached with SLEventSetIOHIDEvent (the MouseDragFix approach).")
    }

    if let s = readSpaces() {
        let before = s.currentID
        legacySwipe(right: direction(s))
        settle(0.8)
        let moved = (readSpaces()?.currentID ?? before) != before
        say("  control: legacy began+ended  \(moved ? "MOVED (!)" : "no, as expected")")
    }

    if let now = readSpaces(), now.currentIndex != start.currentIndex {
        say("")
        say("You moved from space \(start.currentIndex) to \(now.currentIndex) — switch back by hand.")
    }

case "defer":
    guard let start = readSpaces() else { exit(1) }
    say("Deferring to macOS's own Mission Control shortcuts.")
    say("Start: space \(start.currentIndex) of \(start.total).")
    say("")
    say("Bindings found:")
    for i in 0..<start.total {
        if let b = readBinding(id: 118 + i) {
            say("   Switch to Desktop \(i+1): keyCode \(b.keyCode) flags 0x\(String(b.flags.rawValue, radix: 16)) \(b.enabled ? "enabled" : "DISABLED")")
        } else {
            say("   Switch to Desktop \(i+1): no binding")
        }
    }
    for (id, label) in [(79, "Move left a space"), (81, "Move right a space")] {
        if let b = readBinding(id: id) {
            say("   \(label): keyCode \(b.keyCode) flags 0x\(String(b.flags.rawValue, radix: 16)) \(b.enabled ? "enabled" : "DISABLED")")
        } else {
            say("   \(label): no binding")
        }
    }
    say("")

    let targets = [min(3, start.total), min(6, start.total), start.currentIndex]
    for tgt in targets {
        guard let b = readBinding(id: 118 + tgt - 1), b.enabled else {
            say("  desktop \(tgt): no enabled binding, skipping")
            continue
        }
        attempt("switch to desktop \(tgt) via its Mission Control key") { _ in postBinding(b) }
        say("")
    }

    if let b = readBinding(id: 81), b.enabled {
        attempt("move right a space via its Mission Control key") { _ in postBinding(b) }
        say("")
    }
    if let b = readBinding(id: 79), b.enabled {
        attempt("move left a space via its Mission Control key") { _ in postBinding(b) }
        say("")
    }

    if let now = readSpaces() {
        say("Finished on space \(now.currentIndex) (started on \(start.currentIndex)).")
    }

case "assignkey":
    // Idempotent by design: pointed at an already-enabled desktop it rewrites the
    // same value, which is how the write path gets tested without changing the
    // user's setup.
    let n = args.count > 1 ? (Int(args[1]) ?? 8) : 8
    say("Before:")
    if let b = readBinding(id: 118 + n - 1) {
        say("   desktop \(n): keyCode \(b.keyCode) flags 0x\(String(b.flags.rawValue, radix: 16)) \(b.enabled ? "enabled" : "disabled")")
    } else {
        say("   desktop \(n): no entry")
    }
    say("")
    say(enableDesktopShortcut(n))
    say("")
    say("After:")
    if let b = readBinding(id: 118 + n - 1) {
        say("   desktop \(n): keyCode \(b.keyCode) flags 0x\(String(b.flags.rawValue, radix: 16)) \(b.enabled ? "enabled" : "disabled")")
    } else {
        say("   desktop \(n): still no entry — the write did not take")
    }

case "liveness":
    // Does flipping the preference actually make the shortcut live? Turn one OFF,
    // prove the key stops working, turn it back ON, prove it works again. Ends on
    // the user's original settings either way.
    // Pick a target that is NOT where we already are. Asking to switch to the
    // space you are already on does nothing, which reads exactly like a dead
    // shortcut — the first run of this test made that mistake.
    guard let here = readSpaces() else { exit(1) }
    let n = args.count > 1 ? (Int(args[1]) ?? 0) : ((here.currentIndex % here.total) + 1)
    say("Currently on space \(here.currentIndex); testing with desktop \(n).")
    guard let b0 = readBinding(id: 118 + n - 1) else {
        say("desktop \(n) has no binding — nothing to test")
        exit(1)
    }
    let originallyOn = b0.enabled
    say("Testing whether the preference write goes live, using desktop \(n).")
    say("It starts \(originallyOn ? "enabled" : "disabled") and will be put back that way.")
    say("")

    if let msg = setDesktopShortcutEnabled(n, false) { say(msg) }
    settle(1.0)
    if let bOff = readBinding(id: 118 + n - 1) {
        say("   reads back as \(bOff.enabled ? "enabled" : "disabled")")
        let moved = attempt("posting desktop \(n)'s key while DISABLED (expect no move)") { _ in
            postBinding(Binding(keyCode: bOff.keyCode, flags: bOff.flags, enabled: false))
        }
        say(moved ? "   UNEXPECTED: it moved while disabled" : "   correct: disabled means dead")
    }
    say("")

    if let msg = setDesktopShortcutEnabled(n, true) { say(msg) }
    settle(1.0)
    if let bOn = readBinding(id: 118 + n - 1) {
        say("   reads back as \(bOn.enabled ? "enabled" : "disabled")")
        let moved = attempt("posting desktop \(n)'s key after RE-ENABLING (expect a move)") { _ in
            postBinding(bOn)
        }
        say(moved ? "   the write went live" : "   the write did NOT go live")
    }
    say("")

    if let msg = setDesktopShortcutEnabled(n, originallyOn) { say("restored: " + msg) }

default:
    say("usage: spaceprobe [report|windows|legacy|paced|direct|direct-full|all|sweep] [delayMs] [changedPhase]")
}
