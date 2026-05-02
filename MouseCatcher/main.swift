import Cocoa
import CoreGraphics

// MouseCatcher: launched from Spotlight when the cursor has wandered onto the
// off-screen virtual display ActiveSpace uses for single-monitor setups (or
// any other off-screen region). One-shot — warps the cursor to the centre of
// the main display and exits. No UI, no Dock flash, no menu bar.

// 1. Re-associate the cursor with mouse motion in case CGS has detached it
//    (rare, but cheap insurance — the warp below has no visible effect if
//    motion tracking is suspended).
_ = CGAssociateMouseAndMouseCursorPosition(1)

// 2. Warp to the centre of the main display. CGMainDisplayID returns the
//    display owning the menu bar, which is always a real display for normal
//    use; ActiveSpace's virtual display sits off-screen and is never main.
let bounds = CGDisplayBounds(CGMainDisplayID())
let target = CGPoint(x: bounds.midX, y: bounds.midY)
CGWarpMouseCursorPosition(target)

exit(0)
