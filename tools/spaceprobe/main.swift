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
    print("     SLSEnsureSpaceSwitchToActiveProcess → \(rc), SLSSpaceResetMenuBar → \(mrc)")
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
    print("  \(name):")
    print("     before  space \(before.currentIndex) of \(before.total)  (id \(before.currentID)), \(winBefore.count) windows on screen")
    body(before)
    settle(1.0)
    guard let after = readSpaces() else { print("     after   cannot read spaces"); return false }
    let winAfter = onScreenWindows()
    let moved = after.currentID != before.currentID
    let windowsFollowed = Set(winBefore) != Set(winAfter)
    print("     after   space \(after.currentIndex) of \(after.total)  (id \(after.currentID)), \(winAfter.count) windows on screen")
    if moved && !windowsFollowed {
        print("     RESULT  counter moved but the SAME windows are on screen ✗ — windows did not follow")
    } else if moved {
        print("     RESULT  MOVED ✓ — and the on-screen windows changed, so the desktop followed")
    } else {
        print("     RESULT  did not move ✗")
    }
    return moved && windowsFollowed
}

/// Which way can we move from here without falling off the end?
func direction(_ s: Snapshot) -> Bool { s.currentIndex < s.total }

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())
let mode = args.first ?? "report"
let delayMs = UInt32(args.count > 1 ? Int(args[1]) ?? 10 : 10)
let changedPhase = Int64(args.count > 2 ? Int(args[2]) ?? 2 : 2)

print("spaceprobe — macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
let trusted = AXIsProcessTrusted()
print("Accessibility trusted: \(trusted ? "YES" : "NO  ← synthetic events will be ignored")")
if !trusted && (mode == "legacy" || mode == "paced" || mode == "all" || mode == "prompt") {
    print("Asking macOS for Accessibility. Approve it, then run this again.")
    AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    if mode != "prompt" {
        print("Not running the gesture tests without permission — a refusal would look")
        print("exactly like the mechanism being dead, and that would be a false result.")
        exit(2)
    }
    exit(0)
}
print("NSScreen.screens.count: \(NSScreen.screens.count)")
if let s = readSpaces() {
    print("Display \"\(s.displayID)\": on space \(s.currentIndex) of \(s.total), ids \(s.spaceIDs)")
} else {
    print("Could not read spaces")
    exit(1)
}
print("")

switch mode {
case "report", "windows":
    print("On-screen windows (CGWindowList reports the CURRENT space only):")
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
            print("   \(owner.padding(toLength: 22, withPad: " ", startingAt: 0)) \(box.padding(toLength: 20, withPad: " ", startingAt: 0)) \(name.prefix(40))")
        }
    }
    print("")
    print("Read-only. Nothing posted.")

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
    print("WARNING: this mode moves the counter without moving windows and can")
    print("leave the desk unusable until a real switch. Measured dead 2026-09-15.")
    guard let s = readSpaces() else { exit(1) }
    let target = direction(s) ? s.spaceIDs[s.currentIndex] : s.spaceIDs[s.currentIndex - 2]
    let startID = s.currentID
    attempt("direct (CGSManagedDisplaySetCurrentSpace)") { b in
        directSwitch(to: target, from: b.currentID, displayID: b.displayID)
    }
    // Always put the desk back: this runs on a machine in active use.
    if let now = readSpaces(), now.currentID != startID {
        print("     restoring space \(s.currentIndex)...")
        directSwitch(to: startID, from: now.currentID, displayID: now.displayID)
        settle(1.0)
        if let back = readSpaces() {
            print("     back on space \(back.currentIndex)\(back.currentID == startID ? "" : "  ← RESTORE FAILED")")
        }
    }

case "all":
    // Only the gesture mechanisms. `direct` is deliberately NOT included: it was
    // measured on 2026-09-15 to move the space counter while leaving every window
    // on screen, which hands focus to an app whose windows are elsewhere and
    // leaves the desk unusable until a real switch resyncs WindowServer. It cost
    // Jonathan a wedged session once; it does not get to do that twice.
    let start = readSpaces()!
    print("Starting on space \(start.currentIndex) of \(start.total).")
    print("Each test moves one space. Whichever mechanism works is used to move back.")
    print("")

    var results: [(String, Bool)] = []
    var lastWorking: ((Bool) -> Void)? = nil

    if let s = readSpaces() {
        let ok = attempt("1. legacy — began+ended, no gap (what ActiveSpace does today)") { _ in
            legacySwipe(right: direction(s))
        }
        results.append(("legacy", ok))
        if ok { lastWorking = { r in legacySwipe(right: r) } }
    }
    print("")

    if let s = readSpaces() {
        let ok = attempt("2. paced — began→changed→ended, \(delayMs)ms apart, changed=\(changedPhase)") { _ in
            pacedSwipe(right: direction(s), delayMs: delayMs, changedPhase: changedPhase)
        }
        results.append(("paced", ok))
        if ok { lastWorking = { r in pacedSwipe(right: r, delayMs: delayMs, changedPhase: changedPhase) } }
    }
    print("")

    // Walk back with a mechanism that genuinely moves windows, one space at a time.
    if let now = readSpaces(), now.currentIndex != start.currentIndex {
        if let move = lastWorking {
            print("Walking back to space \(start.currentIndex)...")
            var guard_ = 0
            while let cur = readSpaces(), cur.currentIndex != start.currentIndex, guard_ < 12 {
                move(cur.currentIndex < start.currentIndex)
                settle(0.4)
                guard_ += 1
            }
            if let back = readSpaces() {
                print("  now on space \(back.currentIndex)\(back.currentIndex == start.currentIndex ? "" : "  ← switch back by hand")")
            }
        } else {
            print("Moved but nothing worked to move back — switch back by hand (F3).")
        }
    }

    print("")
    print("SUMMARY")
    for (name, ok) in results {
        print("  \(name.padding(toLength: 8, withPad: " ", startingAt: 0))  \(ok ? "WORKS — windows followed" : "dead")")
    }
    print("  direct    dead (measured separately: counter moves, windows do not)")

case "direct-full":
    print("WARNING: same caveat as `direct` — it wedges the desk. Measured dead.")
    guard let s = readSpaces() else { exit(1) }
    let target = direction(s) ? s.spaceIDs[s.currentIndex] : s.spaceIDs[s.currentIndex - 2]
    let startID = s.currentID
    attempt("direct-full (CGS + SLSEnsureSpaceSwitch + SLSSpaceResetMenuBar)") { b in
        directSwitchFull(to: target, from: b.currentID, displayID: b.displayID)
    }
    if let now = readSpaces(), now.currentID != startID {
        print("     restoring space \(s.currentIndex)...")
        directSwitchFull(to: startID, from: now.currentID, displayID: now.displayID)
        settle(1.0)
        if let back = readSpaces() {
            print("     back on space \(back.currentIndex)\(back.currentID == startID ? "" : "  ← RESTORE FAILED")")
        }
    }

default:
    print("usage: spaceprobe [report|legacy|paced|direct|direct-full|all] [delayMs] [changedPhase]")
}
