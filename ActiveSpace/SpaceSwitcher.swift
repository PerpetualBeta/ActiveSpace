import AppKit
import CoreGraphics

/// Switches Mission Control spaces instantly by synthesising dock-swipe gesture
/// events with high velocity, causing the Dock to skip its sliding animation.
/// Adapted from https://github.com/jurplel/InstantSpaceSwitcher
enum SpaceSwitcher {

    // MARK: - Private CGEvent field indices (reverse-engineered)

    private static let fieldEventSubType       = CGEventField(rawValue: 55)!
    private static let fieldHIDType            = CGEventField(rawValue: 110)!
    private static let fieldScrollY            = CGEventField(rawValue: 119)!
    private static let fieldSwipeMotion        = CGEventField(rawValue: 123)!
    private static let fieldSwipeProgress      = CGEventField(rawValue: 124)!
    private static let fieldSwipeVelocityX     = CGEventField(rawValue: 129)!
    private static let fieldSwipeVelocityY     = CGEventField(rawValue: 130)!
    private static let fieldGesturePhase       = CGEventField(rawValue: 132)!
    private static let fieldScrollFlagBits     = CGEventField(rawValue: 135)!
    private static let fieldZoomDeltaX         = CGEventField(rawValue: 139)!

    // Private event-type / HID constants
    private static let kCGSEventGesture:         Int64 = 29
    private static let kCGSEventDockControl:     Int64 = 30
    private static let kIOHIDEventTypeDockSwipe: Int64 = 23
    private static let kGestureMotionHorizontal: Int64 = 1
    private static let kPhaseBegan:              Int64 = 1
    private static let kPhaseEnded:              Int64 = 4

    // MARK: - Public API

    /// Prompts for Accessibility permission if not already granted.
    static func ensureAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Switch to a specific space index (1-based). No wrap-around.
    static func switchTo(index: Int, observer: SpaceObserver) {
        guard index != observer.currentSpaceIndex else { return }
        guard index >= 1, index <= observer.totalSpaces else { return }

        guard AXIsProcessTrusted() else {
            NSLog("ActiveSpace: Accessibility permission not granted")
            ensureAccessibility()
            return
        }

        let steps = index - observer.currentSpaceIndex
        let right = steps > 0

        for _ in 0..<abs(steps) {
            postSwitchGesture(right: right)
        }

        // After the switch, check if there's a visible app window on
        // the new space. If not, nudge Finder to refresh the menu bar.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if !hasVisibleAppWindow() {
                nudgeDesktop()
            }
        }
    }

    /// Move to the next space, wrapping from last → first.
    static func switchNext(observer: SpaceObserver) {
        let total = observer.totalSpaces
        guard total > 1 else { return }
        let next = observer.currentSpaceIndex < total ? observer.currentSpaceIndex + 1 : 1
        switchTo(index: next, observer: observer)
    }

    /// Move to the previous space, wrapping from first → last.
    static func switchPrev(observer: SpaceObserver) {
        let total = observer.totalSpaces
        guard total > 1 else { return }
        let prev = observer.currentSpaceIndex > 1 ? observer.currentSpaceIndex - 1 : total
        switchTo(index: prev, observer: observer)
    }

    /// Toggle between space 1 and 2 (legacy convenience).
    static func toggle(observer: SpaceObserver) {
        switchNext(observer: observer)
    }

    // MARK: - Synthetic gesture posting

    /// Posts a complete Begin + End dock-swipe gesture pair.
    /// Each phase posts two events: DockControl first, then a Gesture companion.
    static func postSwitchGesture(right: Bool) {
        let flagDir: Int64   = right ? 1 : 0
        let progress: Double = right ? 2.0 : -2.0
        let velocity: Double = right ? 400.0 : -400.0

        // ── Begin phase ──

        guard let beginGesture = CGEvent(source: nil),
              let beginDock    = CGEvent(source: nil) else { return }

        beginGesture.type = CGEventType(rawValue: UInt32(kCGSEventGesture))!
        beginGesture.setIntegerValueField(fieldEventSubType, value: kCGSEventGesture)

        beginDock.type = CGEventType(rawValue: UInt32(kCGSEventDockControl))!
        beginDock.setIntegerValueField(fieldEventSubType,   value: kCGSEventDockControl)
        beginDock.setIntegerValueField(fieldHIDType,        value: kIOHIDEventTypeDockSwipe)
        beginDock.setIntegerValueField(fieldGesturePhase,   value: kPhaseBegan)
        beginDock.setIntegerValueField(fieldScrollFlagBits, value: flagDir)
        beginDock.setIntegerValueField(fieldSwipeMotion,    value: kGestureMotionHorizontal)
        beginDock.setDoubleValueField(fieldScrollY,         value: 0)
        beginDock.setDoubleValueField(fieldZoomDeltaX,      value: Double(Float.leastNonzeroMagnitude))

        beginDock.post(tap: .cgSessionEventTap)
        beginGesture.post(tap: .cgSessionEventTap)

        // ── End phase ──

        guard let endGesture = CGEvent(source: nil),
              let endDock    = CGEvent(source: nil) else { return }

        endGesture.type = CGEventType(rawValue: UInt32(kCGSEventGesture))!
        endGesture.setIntegerValueField(fieldEventSubType, value: kCGSEventGesture)

        endDock.type = CGEventType(rawValue: UInt32(kCGSEventDockControl))!
        endDock.setIntegerValueField(fieldEventSubType,   value: kCGSEventDockControl)
        endDock.setIntegerValueField(fieldHIDType,        value: kIOHIDEventTypeDockSwipe)
        endDock.setIntegerValueField(fieldGesturePhase,   value: kPhaseEnded)
        endDock.setDoubleValueField(fieldSwipeProgress,   value: progress)
        endDock.setIntegerValueField(fieldScrollFlagBits, value: flagDir)
        endDock.setIntegerValueField(fieldSwipeMotion,    value: kGestureMotionHorizontal)
        endDock.setDoubleValueField(fieldScrollY,         value: 0)
        endDock.setDoubleValueField(fieldSwipeVelocityX,  value: velocity)
        endDock.setDoubleValueField(fieldSwipeVelocityY,  value: 0)
        endDock.setDoubleValueField(fieldZoomDeltaX,      value: Double(Float.leastNonzeroMagnitude))

        endDock.post(tap: .cgSessionEventTap)
        endGesture.post(tap: .cgSessionEventTap)
    }

    /// Returns true if there's at least one visible app window (layer 0) on screen.
    private static func hasVisibleAppWindow() -> Bool {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        let myPID = ProcessInfo.processInfo.processIdentifier
        for entry in list {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != myPID,
                  let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Double],
                  (bounds["Width"] ?? 0) >= 50, (bounds["Height"] ?? 0) >= 50 else { continue }
            return true
        }
        return false
    }

    /// Activate Finder to force the Dock to refresh menu bar ownership.
    /// Uses AppleScript — lightweight and doesn't interfere with mouse state.
    private static func nudgeDesktop() {
        let script = NSAppleScript(source: """
            tell application "Finder" to activate
        """)
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
    }
}
