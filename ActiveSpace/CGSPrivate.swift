import Foundation

// Private CoreGraphics Spaces APIs (SPI — not in public headers).
// These are stable on macOS 13+ and used by WhichSpace, Spaceman, etc.

typealias CGSConnectionID = UInt32

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

/// Returns the CGS workspace ID of the currently active space on the primary display.
@_silgen_name("CGSGetWorkspace")
@discardableResult
func CGSGetWorkspace(_ conn: CGSConnectionID, _ workspace: inout Int32) -> OSStatus

/// Returns the ManagedSpaceID of the currently active space.
@_silgen_name("CGSGetActiveSpace")
func CGSGetActiveSpace(_ conn: CGSConnectionID) -> UInt64

/// Returns an array of display dictionaries, each containing a "Spaces" array
/// and a "Current Space" dict with the currently active space on that display.
@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ conn: CGSConnectionID) -> CFArray

/// Switches the active space on the given display. Instant — no animation.
@_silgen_name("CGSManagedDisplaySetCurrentSpace")
@discardableResult
func CGSManagedDisplaySetCurrentSpace(_ conn: CGSConnectionID, _ displayID: CFString, _ spaceID: Int) -> OSStatus
