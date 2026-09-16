import Foundation
import ApplicationServices

// Private CoreGraphics Spaces APIs (SPI — not in public headers).
// These are stable on macOS 13+ and used by WhichSpace, Spaceman, etc.

typealias CGSConnectionID = UInt32

/// Resolves an AXUIElement window reference to its CG window ID. Used to
/// cross-reference AX windows (which enumerate across all spaces) against
/// the CG on-screen list (current-space only).
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement,
                           _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

/// Returns an array of display dictionaries, each containing a "Spaces" array
/// and a "Current Space" dict with the currently active space on that display.
@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ conn: CGSConnectionID) -> CFArray

// MARK: - SkyLight (SLS) private APIs — loaded via dlsym

import Darwin

private let skylight: UnsafeMutableRawPointer? = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

typealias SLSEnsureSpaceSwitchFn = @convention(c) (CGSConnectionID) -> OSStatus
typealias SLSCopySpacesForWindowsFn = @convention(c) (CGSConnectionID, Int32, CFArray) -> Unmanaged<CFArray>?
typealias SLSProcessAssignToAllSpacesFn = @convention(c) (CGSConnectionID, pid_t) -> OSStatus
typealias SLSProcessAssignToSpaceFn = @convention(c) (CGSConnectionID, pid_t, UInt64) -> OSStatus

/// Returns the ManagedSpaceIDs (as NSNumbers) that the given CG windows belong
/// to, across the space types covered by `mask`. Pass mask `0x7` for all
/// spaces (user + OS + current). Used by the switcher to determine per-window
/// Mission Control space membership — including minimised windows and windows
/// of hidden apps, which CGWindowListCopyWindowInfo omits.
func SLSCopySpacesForWindows(_ conn: CGSConnectionID, _ mask: Int32, _ windows: CFArray) -> [NSNumber] {
    guard let skylight, let sym = dlsym(skylight, "SLSCopySpacesForWindows") else { return [] }
    let fn = unsafeBitCast(sym, to: SLSCopySpacesForWindowsFn.self)
    guard let result = fn(conn, mask, windows) else { return [] }
    return (result.takeRetainedValue() as? [NSNumber]) ?? []
}

// MARK: - Per-process all-spaces assignment

/// Assign every window owned by `pid` to appear on every Mission
/// Control user space. Exactly the call the Dock's right-click
/// "Options → Assign To → All Desktops" menu makes. Per-process, not
/// per-window — toggling on for Slack makes ALL Slack windows follow
/// the user across spaces.
///
/// **Why this over `SLSAddWindowsToSpaces`:** the older
/// per-window-to-space-list API returns `kCGErrorSuccess` (rc=0) on
/// macOS 14.5+ but is a no-op — empirically verified 2026-05-16 with
/// `SLSCopySpacesForWindows` showing the window's space membership
/// unchanged after the call. Apple moved the space-membership
/// mechanism to a workspace/compatID model (`SLSSpaceSetCompatID` +
/// `SLSSetWindowListWorkspace`, used by Hammerspoon's spaces module),
/// but for "all spaces" specifically the per-process call still works
/// and is dramatically simpler than iterating spaces.
func SLSProcessAssignToAllSpaces(_ conn: CGSConnectionID, _ pid: pid_t) -> OSStatus {
    guard let skylight, let sym = dlsym(skylight, "SLSProcessAssignToAllSpaces") else { return -1 }
    return unsafeBitCast(sym, to: SLSProcessAssignToAllSpacesFn.self)(conn, pid)
}

/// Assign every window owned by `pid` to exactly one space — removed
/// from every other space they were previously on. The inverse of
/// `SLSProcessAssignToAllSpaces`, used to return an app's windows to
/// the space they were on when the user first toggled follow on.
func SLSProcessAssignToSpace(_ conn: CGSConnectionID, _ pid: pid_t, _ spaceID: UInt64) -> OSStatus {
    guard let skylight, let sym = dlsym(skylight, "SLSProcessAssignToSpace") else { return -1 }
    return unsafeBitCast(sym, to: SLSProcessAssignToSpaceFn.self)(conn, pid, spaceID)
}

// MARK: - Current space helper

/// Current user space's ManagedSpaceID. Returns 0 on fullscreen/tiled spaces
/// (type != 0) — activations that land there go into an inert bucket.
func currentManagedSpaceID() -> UInt64 {
    let conn = CGSMainConnectionID()
    guard let raw = CGSCopyManagedDisplaySpaces(conn) as? [[String: Any]] else { return 0 }
    for display in raw {
        guard let current = display["Current Space"] as? [String: Any],
              let type = current["type"] as? Int, type == 0,
              let id = current["ManagedSpaceID"] as? Int
        else { continue }
        return UInt64(id)
    }
    return 0
}
