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

/// Returns the CGS workspace ID of the currently active space on the primary display.
@_silgen_name("CGSGetWorkspace")
@discardableResult
func CGSGetWorkspace(_ conn: CGSConnectionID, _ workspace: inout Int32) -> OSStatus

/// Returns an array of display dictionaries, each containing a "Spaces" array
/// and a "Current Space" dict with the currently active space on that display.
@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ conn: CGSConnectionID) -> CFArray

/// Directly switches the given display to the space with the given ManagedSpaceID,
/// bypassing the Dock's gesture pipeline entirely. `display` is a CGS display
/// identifier string ("Main" or a CFUUID string). Stable private API since OS X Lion,
/// used by WhichSpace, Spaceman, and similar tools.
@_silgen_name("CGSManagedDisplaySetCurrentSpace")
func CGSManagedDisplaySetCurrentSpace(_ conn: CGSConnectionID, _ display: CFString, _ spaceID: UInt64)

/// Tells WindowServer to hide a set of spaces, moving their windows off-screen.
/// Paired with CGSShowSpaces + CGSManagedDisplaySetCurrentSpace to perform a full
/// visual space transition that cleanly updates Mission Control state.
@_silgen_name("CGSHideSpaces")
func CGSHideSpaces(_ conn: CGSConnectionID, _ spaces: CFArray)

/// Tells WindowServer to show a set of spaces, making their windows on-screen.
@_silgen_name("CGSShowSpaces")
func CGSShowSpaces(_ conn: CGSConnectionID, _ spaces: CFArray)

/// Freezes WindowServer rendering. Pair with CGSReenableUpdate. Used internally
/// by Mission Control, Rectangle, and similar tools to batch several CGS
/// operations without the user seeing intermediate frames. Nested calls are
/// refcounted — every Disable must be matched by exactly one Reenable.
@_silgen_name("CGSDisableUpdate")
func CGSDisableUpdate(_ conn: CGSConnectionID)

/// Resumes WindowServer rendering after a matching CGSDisableUpdate.
@_silgen_name("CGSReenableUpdate")
func CGSReenableUpdate(_ conn: CGSConnectionID)

// MARK: - SkyLight (SLS) private APIs — loaded via dlsym

import Darwin

private let skylight: UnsafeMutableRawPointer? = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

typealias SLSEnsureSpaceSwitchFn = @convention(c) (CGSConnectionID) -> OSStatus
typealias SLSSpaceResetMenuBarFn = @convention(c) (CGSConnectionID, UInt64) -> OSStatus
typealias SLSSetWindowPrefersCurrentSpaceFn = @convention(c) (CGSConnectionID, UInt32, Bool) -> OSStatus
typealias SLSCopySpacesForWindowsFn = @convention(c) (CGSConnectionID, Int32, CFArray) -> Unmanaged<CFArray>?

func SLSEnsureSpaceSwitchToActiveProcess(_ conn: CGSConnectionID) -> OSStatus {
    guard let skylight, let sym = dlsym(skylight, "SLSEnsureSpaceSwitchToActiveProcess") else { return -1 }
    return unsafeBitCast(sym, to: SLSEnsureSpaceSwitchFn.self)(conn)
}

func SLSSpaceResetMenuBar(_ conn: CGSConnectionID, _ spaceID: UInt64) -> OSStatus {
    guard let skylight, let sym = dlsym(skylight, "SLSSpaceResetMenuBar") else { return -1 }
    return unsafeBitCast(sym, to: SLSSpaceResetMenuBarFn.self)(conn, spaceID)
}

func SLSSetWindowPrefersCurrentSpace(_ conn: CGSConnectionID, _ windowID: UInt32, _ prefers: Bool) -> OSStatus {
    guard let skylight, let sym = dlsym(skylight, "SLSSetWindowPrefersCurrentSpace") else { return -1 }
    return unsafeBitCast(sym, to: SLSSetWindowPrefersCurrentSpaceFn.self)(conn, windowID, prefers)
}

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
