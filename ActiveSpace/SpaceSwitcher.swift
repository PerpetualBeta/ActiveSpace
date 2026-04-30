import AppKit
import CoreGraphics

/// Switches Mission Control spaces. Uses two techniques depending on the
/// display configuration, because each has different failure modes on the
/// other:
///
///   - **Single display** → `CGSManagedDisplaySetCurrentSpace` (direct API).
///     Instant, no flash, no progressive Dock-state corruption. The gesture
///     approach degrades on single-display configs (windows/menu-bars stop
///     repainting after repeated switches).
///
///   - **Multi-display (incl. spans-displays mode)** → synthetic dock-swipe
///     gesture. The direct API only flips CGS's current-space flag without
///     telling WindowServer to move windows or update Mission Control state,
///     so spaces change numerically but windows stay put and F3 breaks.
///     The gesture drives a full visual transition across all displays.
enum SpaceSwitcher {

    // MARK: - Public API

    /// Prompts for Accessibility permission if not already granted.
    static func ensureAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Switch to a specific space index (1-based). No wrap-around.
    static func switchTo(index: Int, observer: SpaceObserver) {
        observer.refresh()
        guard let target = observer.spaceInfo(forIndex: index) else {
            aslog("switchTo(\(index)): no SpaceInfo — ignoring")
            return
        }
        guard AXIsProcessTrusted() else {
            aslog("switchTo(\(index)): Accessibility permission not granted")
            ensureAccessibility()
            return
        }

        let current = observer.currentSpaceIndex
        if index == current {
            aslog("switchTo(\(index)): already on target, skipping")
            return
        }

        if isSingleDisplay() {
            directSwitch(to: target, from: observer.spaceInfo(forIndex: current))
        } else {
            gestureSwitch(from: current, to: index, observer: observer)
        }
    }

    /// Move to the next space, wrapping from last → first.
    static func switchNext(observer: SpaceObserver) {
        observer.refresh()
        let total = observer.totalSpaces
        guard total > 1 else { return }
        let current = observer.currentSpaceIndex
        let target = current < total ? current + 1 : 1
        aslog("switchNext: current=\(current) total=\(total) → target=\(target)")
        switchTo(index: target, observer: observer)
    }

    /// Move to the previous space, wrapping from first → last.
    static func switchPrev(observer: SpaceObserver) {
        observer.refresh()
        let total = observer.totalSpaces
        guard total > 1 else { return }
        let current = observer.currentSpaceIndex
        let target = current > 1 ? current - 1 : total
        aslog("switchPrev: current=\(current) total=\(total) → target=\(target)")
        switchTo(index: target, observer: observer)
    }

    /// Toggle between space 1 and 2 (legacy convenience).
    static func toggle(observer: SpaceObserver) {
        switchNext(observer: observer)
    }

    /// Move one "row" up in the conceptual grid (current − rowWidth), with
    /// column-cycling wrap. No-op when grid mode is inactive
    /// (rowWidth < 2 or totalSpaces ≤ rowWidth).
    static func switchUp(rowWidth: Int, observer: SpaceObserver) {
        step(direction: -1, rowWidth: rowWidth, observer: observer)
    }

    /// Move one row down (current + rowWidth), with column-cycling wrap.
    /// No-op when grid mode is inactive.
    static func switchDown(rowWidth: Int, observer: SpaceObserver) {
        step(direction: 1, rowWidth: rowWidth, observer: observer)
    }

    /// Column-cycling navigation. The user thinks of spaces as a grid of
    /// `rowWidth` columns; this moves through column N independently of
    /// other columns. With a partial last row, columns past the partial-row
    /// edge have only one row each, so up/down on those columns no-ops.
    private static func step(direction: Int, rowWidth: Int, observer: SpaceObserver) {
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
        let newRow = ((row + direction) % rowsInColumn + rowsInColumn) % rowsInColumn
        let target = column + newRow * rowWidth + 1
        aslog("step(\(direction)): current=\(current) col=\(column) row=\(row) rowsInCol=\(rowsInColumn) → target=\(target)")
        if target != current {
            switchTo(index: target, observer: observer)
        }
    }

    // MARK: - Single-display path (direct API)

    private static func directSwitch(to target: SpaceInfo, from current: SpaceInfo?) {
        let conn = CGSMainConnectionID()
        aslog("directSwitch: display=\(target.displayIdentifier) current=\(current?.managedSpaceID ?? -1) → target=\(target.managedSpaceID)")
        if let current {
            CGSHideSpaces(conn, [current.managedSpaceID] as CFArray)
        }
        CGSShowSpaces(conn, [target.managedSpaceID] as CFArray)
        CGSManagedDisplaySetCurrentSpace(conn,
                                         target.displayIdentifier as CFString,
                                         UInt64(target.managedSpaceID))

        // SkyLight: tell WindowServer to complete the switch — this may be the
        // missing step that prevents window bleed-through on single display.
        let rc = SLSEnsureSpaceSwitchToActiveProcess(conn)
        aslog("directSwitch: SLSEnsureSpaceSwitchToActiveProcess → \(rc)")

        // Reset menu bar on the target space to fix any coordinate confusion.
        let mrc = SLSSpaceResetMenuBar(conn, UInt64(target.managedSpaceID))
        aslog("directSwitch: SLSSpaceResetMenuBar → \(mrc)")
    }

    // MARK: - Multi-display path (synthetic dock-swipe gesture)

    private static func gestureSwitch(from current: Int, to target: Int, observer: SpaceObserver) {
        // The gesture doesn't wrap, so for wraparound we walk back the long way:
        // (total - 1) spaces in the opposite direction. Each dock-swipe advances
        // by exactly one space — the Dock clamps larger progress values.
        let delta = target - current
        let steps: Int
        let right: Bool
        if delta > 0 {
            steps = delta
            right = true
        } else if delta < 0 {
            steps = -delta
            right = false
        } else {
            return
        }

        aslog("gestureSwitch: current=\(current) → target=\(target) via \(steps) \(right ? "right" : "left") swipe(s)")

        if steps == 1 {
            postSwitchGesture(right: right)
            activateTopmostWindow()
            return
        }

        // Multi-step. The flash between gestures is the intermediate space
        // being rendered — something we can't suppress via CGSDisableUpdate or
        // CGSHideSpaces (both tried, neither prevents it fully). Instead, cover
        // the transition with a full-screen heavy blur overlay that sits on
        // every space. The user sees a deliberate-looking blur wipe rather than
        // a rendering glitch.
        aslog("gestureSwitch: multi-step, showing blur overlay")
        TransitionOverlay.show()

        for _ in 0..<steps { postSwitchGesture(right: right) }

        // Let the gesture events drain (and the Dock land on the target space)
        // before we pull the overlay down.
        let deadline = Date().addingTimeInterval(0.100)
        RunLoop.current.run(until: deadline)

        TransitionOverlay.hide()
        activateTopmostWindow()
    }

    /// After a synthetic gesture switch, macOS may not activate a window in
    /// the destination space. Find the topmost normal-layer window on screen
    /// and activate its owning application so the menu bar updates and
    /// focus-dependent apps (like RainbowApple) can re-query correctly.
    private static func activateTopmostWindow() {
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
                    aslog("activateTopmostWindow: activated \(app.localizedName ?? "?") (pid \(pid))")
                    return
                }
            }
            aslog("activateTopmostWindow: no suitable window found")
        }
    }

    // MARK: - Synthetic gesture posting

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

    private static let kCGSEventGesture:         Int64 = 29
    private static let kCGSEventDockControl:     Int64 = 30
    private static let kIOHIDEventTypeDockSwipe: Int64 = 23
    private static let kGestureMotionHorizontal: Int64 = 1
    private static let kPhaseBegan:              Int64 = 1
    private static let kPhaseEnded:              Int64 = 4

    /// Posts a complete Begin + End dock-swipe gesture pair that advances the
    /// visible cycle by one space, at high velocity so the Dock skips its
    /// sliding animation. The Dock clamps one gesture = one space regardless
    /// of progress magnitude, so multi-space jumps require posting N of these.
    private static func postSwitchGesture(right: Bool) {
        let flagDir: Int64   = right ? 1 : 0
        let progress: Double = right ? 2.0 : -2.0
        let velocity: Double = right ? 400.0 : -400.0

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

    // MARK: - Display count

    private static func isSingleDisplay() -> Bool {
        NSScreen.screens.count <= 1
    }
}
