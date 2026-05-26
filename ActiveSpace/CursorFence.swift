import AppKit
import CoreGraphics

/// Pins the cursor to the main display while ActiveSpace's helper-owned
/// virtual display is present. Engaged on `VirtualDisplay.launchHelper`
/// and disengaged on `stopHelper` — bracketed by the virtual's lifetime,
/// so it cannot fire when there's a legitimate second physical display
/// to traverse to.
///
/// **Why this exists.** `VirtualDisplayHost` requests origin
/// `(-32768, -32768)` for the virtual, which macOS clamps to
/// `(-width, -height)`. We previously believed this put the virtual
/// "fully unreachable" by cursor or windows, but the clamping actually
/// places the virtual's bottom-right corner at main's top-left corner
/// `(0, 0)` — the displays share exactly one point. macOS allows
/// diagonal cursor traversal across that shared corner under some
/// conditions (lid/wake/screen-lock race windows are the most common
/// trigger), so the cursor occasionally slips off-main onto the
/// invisible virtual and is unrecoverable without MouseCatcher.
///
/// **Mechanism.** A `cgAnnotatedSessionEventTap` on `.mouseMoved` plus
/// the three drag variants sees the cursor position before downstream
/// consumers. If the event location is outside main's bounds:
///   1. Compute the nearest in-bounds point on main.
///   2. Call `CGWarpMouseCursorPosition` so the hardware cursor jumps
///      back.
///   3. Re-associate mouse + cursor (CGWarpMouseCursorPosition
///      disassociates for ~250ms by default; calling associate(true)
///      restores responsiveness immediately).
///   4. Rewrite the event's location to the clamped point and pass it
///      through, so downstream apps mid-drag see consistent positions.
///
/// **Lifecycle policy.** The fence stays engaged across helper
/// crash + relaunch cycles — pinning during the brief no-virtual
/// window costs nothing, and the alternative (toggle off/on per crash)
/// opens small race windows for cursor escape.
enum CursorFence {

    private static var tap: CFMachPort?
    private static var runLoopSource: CFRunLoopSource?

    static func engage() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard tap == nil else { return }

        let mask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue)

        // Same tap layer as AppDelegate's keyboard tap: after HID-level
        // rewriters, last in chain. Mouse rewriting is uncommon, but
        // consistency with the keyboard tap means any third-party tools
        // that synthesize / massage events get to see them first.
        guard let port = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: cursorFenceTapCallback,
            userInfo: nil
        ) else {
            aslog("CursorFence: tapCreate failed — fence inactive")
            return
        }

        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        runLoopSource = source
        aslog("CursorFence: engaged")
    }

    static func disengage() {
        dispatchPrecondition(condition: .onQueue(.main))
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let port = tap {
            CGEvent.tapEnable(tap: port, enable: false)
            tap = nil
        }
        aslog("CursorFence: disengaged")
    }

    /// Re-enable the tap after macOS disables it on timeout or
    /// user-input flood. Same recovery pattern as the keyboard tap in
    /// AppDelegate.
    fileprivate static func reenableIfNeeded() {
        if let port = tap {
            CGEvent.tapEnable(tap: port, enable: true)
            aslog("CursorFence: tap re-enabled after system disable")
        }
    }

    fileprivate static func handle(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let loc = event.location
        let main = CGDisplayBounds(CGMainDisplayID())
        if main.contains(loc) {
            return Unmanaged.passUnretained(event)
        }
        let clamped = CGPoint(
            x: max(main.minX, min(main.maxX - 1, loc.x)),
            y: max(main.minY, min(main.maxY - 1, loc.y))
        )
        CGWarpMouseCursorPosition(clamped)
        CGAssociateMouseAndMouseCursorPosition(1)
        event.location = clamped
        aslog("CursorFence: clamped (\(Int(loc.x)),\(Int(loc.y))) → (\(Int(clamped.x)),\(Int(clamped.y)))")
        return Unmanaged.passUnretained(event)
    }
}

private func cursorFenceTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        CursorFence.reenableIfNeeded()
        return Unmanaged.passUnretained(event)
    }
    return CursorFence.handle(event)
}
