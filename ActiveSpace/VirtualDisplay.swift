import AppKit
import CoreGraphics

// MARK: - Cursor fence — module-level state for the C-compatible tap callback
//
// The virtual display's rect (CoreGraphics coordinate space, top-left origin).
// When non-nil, the tap below blocks cursor entry into this region by clamping
// the cursor to the adjacent edge. Updated whenever the virtual is created,
// repositioned, or destroyed.
private var _cursorFenceVirtualRect: CGRect?
private var _cursorFenceTap: CFMachPort?

/// Called for every mouse-move event while the fence is active. Fast path: if
/// the cursor's new location is outside the virtual's rect, pass through
/// unchanged. Slow path: warp the cursor to just inside the main display's
/// adjacent edge and consume the original event so the cursor doesn't visibly
/// enter the virtual.
private func cursorFenceCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = _cursorFenceTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard let rect = _cursorFenceVirtualRect else {
        return Unmanaged.passUnretained(event)
    }
    let loc = event.location
    guard rect.contains(loc) else {
        return Unmanaged.passUnretained(event)
    }

    // Cursor is trying to enter the virtual. Determine which edge of the
    // virtual is adjacent to main and clamp the cursor just inside main on
    // that edge, at the cursor's current y (clamped to main's extent).
    let mainBounds = CGDisplayBounds(CGMainDisplayID())
    let clampedX: CGFloat
    if rect.minX >= mainBounds.maxX {
        // Virtual is right of main — clamp to main's right edge.
        clampedX = mainBounds.maxX - 1
    } else if rect.maxX <= mainBounds.minX {
        // Virtual is left of main — clamp to main's left edge.
        clampedX = mainBounds.minX
    } else {
        // Some other arrangement (above/below). Fall through and let the
        // event pass — rare enough not to worry about yet.
        return Unmanaged.passUnretained(event)
    }
    let clampedY = min(max(loc.y, mainBounds.minY), mainBounds.maxY - 1)
    CGWarpMouseCursorPosition(CGPoint(x: clampedX, y: clampedY))
    return nil
}

/// Manages an invisible virtual display that's only needed when the user has a
/// single physical display. On macOS 16, single-monitor configurations use the
/// display identifier "Main", which causes the Dock's gesture processing to
/// malfunction (menu-bar PDMs and windows fail to repaint after space switches).
/// Adding a second display — even an invisible one — forces macOS to use
/// UUID-based identifiers instead, which fixes the gesture routing.
///
/// With 2+ physical displays already present, the virtual display is unnecessary
/// and harmful — it can shadow real displays in NSScreen enumeration and show up
/// in the plist as an "AutoCreated" display, interfering with our space-ordering
/// logic. So we only create it when physically needed, and drop it when no
/// longer needed (e.g. user plugs in an external monitor).
enum VirtualDisplay {

    private static var screenObserver: NSObjectProtocol?
    private static var lastEnforceAttempt: Date?
    private static var enforceAttemptCount = 0
    private static let maxEnforceAttempts = 5
    private static let enforceMinInterval: TimeInterval = 0.5

    /// Call once at app launch. Creates the virtual display if there's only one
    /// physical display, and installs an observer so it's added/removed as the
    /// user's display configuration changes.
    static func startManaging() {
        startCursorFence()
        reconcile()

        // Observe screen configuration changes (plug/unplug, lid open/close).
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            reconcile()
        }
    }

    /// Install the cursor-fence CGEventTap. Cheap to leave permanently
    /// installed: when `_cursorFenceVirtualRect` is nil (no virtual present)
    /// the callback short-circuits on the first check.
    private static func startCursorFence() {
        guard _cursorFenceTap == nil else { return }
        let mask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: cursorFenceCallback,
            userInfo: nil
        ) else {
            aslog("CursorFence: tapCreate failed")
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        _cursorFenceTap = tap
        aslog("CursorFence: tap installed")
    }

    /// Update the fence rect so the tap callback knows what region to block.
    /// Pass nil to disable the fence (e.g. when the virtual is destroyed).
    private static func updateCursorFence(_ rect: CGRect?) {
        _cursorFenceVirtualRect = rect
        if let rect {
            aslog("CursorFence: rect=\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width))x\(Int(rect.height))")
        } else {
            aslog("CursorFence: disabled")
        }
    }

    /// Returns the current virtual display's bounds if present, else nil.
    private static func currentVirtualRect() -> CGRect? {
        guard VirtualDisplayHelper.isCreated(),
              let virtualUUID = VirtualDisplayHelper.displayUUIDString() else { return nil }
        for screen in NSScreen.screens {
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let cgID = CGDirectDisplayID(n.uint32Value)
            if let uuid = CGDisplayCreateUUIDFromDisplayID(cgID)?.takeRetainedValue(),
               let uuidStr = CFUUIDCreateString(nil, uuid) as String?,
               uuidStr == virtualUUID {
                return CGDisplayBounds(cgID)
            }
        }
        return nil
    }

    /// CFUUID-string identifier of the virtual display, or nil if not created.
    static var uuidString: String? {
        VirtualDisplayHelper.displayUUIDString()
    }

    /// Remove the screen observer and destroy the virtual display if present.
    /// Called from `applicationWillTerminate` so a self-restart under launchd
    /// doesn't inherit a lingering virtual display that would confuse the
    /// respawned instance's initial fingerprint.
    static func teardown() {
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
            screenObserver = nil
        }
        if VirtualDisplayHelper.isCreated() {
            VirtualDisplayHelper.destroy()
        }
    }

    // MARK: - Private

    /// Match the virtual display's presence to whether it's currently needed.
    private static func reconcile() {
        let realCount = physicalDisplayCount()
        let haveVirtual = VirtualDisplayHelper.isCreated()
        let needVirtual = realCount <= 1

        aslog("VirtualDisplay.reconcile: real=\(realCount) haveVirtual=\(haveVirtual) needVirtual=\(needVirtual)")

        if needVirtual && !haveVirtual {
            _ = VirtualDisplayHelper.create()
            enforceAttemptCount = 0   // fresh creation — reset drift counter
            // Reset menu bars on all spaces after creating the virtual display.
            // The extended coordinate space can corrupt menu positioning; this
            // SkyLight API resets the menu bar rendering for each space.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                Self.resetAllMenuBars()
            }
        } else if !needVirtual && haveVirtual {
            VirtualDisplayHelper.destroy()
        }

        // Whenever screen params change, macOS may silently reposition the
        // virtual from our requested right-of-main origin to left-of-main —
        // which drags the Dock off-screen onto the (invisible-but-routable)
        // virtual. Re-apply the intended position if we see it has drifted.
        enforceVirtualPosition()

        // Update the cursor fence so it blocks cursor entry into the current
        // virtual rect (or disables the fence if the virtual is gone).
        updateCursorFence(currentVirtualRect())
    }

    /// If the virtual exists but macOS has moved it away from our intended
    /// right-of-main origin, call CGConfigureDisplayOrigin again. Rate-limited
    /// to one attempt every 500ms and capped at 5 attempts per creation to
    /// avoid fighting macOS in a loop if the reposition can't be made to stick.
    private static func enforceVirtualPosition() {
        guard VirtualDisplayHelper.isCreated(),
              let virtualUUID = VirtualDisplayHelper.displayUUIDString() else { return }

        // Find the virtual display's current CGDirectDisplayID via its UUID
        // (the ID itself churns across recreation; UUID is stable).
        var virtualID: CGDirectDisplayID?
        for screen in NSScreen.screens {
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let cgID = CGDirectDisplayID(n.uint32Value)
            if let uuid = CGDisplayCreateUUIDFromDisplayID(cgID)?.takeRetainedValue(),
               let uuidStr = CFUUIDCreateString(nil, uuid) as String?,
               uuidStr == virtualUUID {
                virtualID = cgID
                break
            }
        }
        guard let virtualID else { return }

        let mainBounds = CGDisplayBounds(CGMainDisplayID())
        let expectedX = Int32(mainBounds.origin.x + mainBounds.size.width)
        let expectedY = Int32(mainBounds.origin.y)
        let current = CGDisplayBounds(virtualID)

        if Int32(current.origin.x) == expectedX && Int32(current.origin.y) == expectedY {
            return
        }

        // Rate-limit so a re-apply that macOS immediately overrides doesn't
        // spin in a notification loop.
        if let last = lastEnforceAttempt, Date().timeIntervalSince(last) < enforceMinInterval {
            aslog("enforceVirtualPosition: rate-limit skip (last attempt \(Int(Date().timeIntervalSince(last) * 1000))ms ago)")
            return
        }
        if enforceAttemptCount >= maxEnforceAttempts {
            aslog("enforceVirtualPosition: giving up after \(maxEnforceAttempts) attempts — virtual at (\(Int(current.origin.x)),\(Int(current.origin.y)))")
            return
        }

        enforceAttemptCount += 1
        lastEnforceAttempt = Date()
        aslog("enforceVirtualPosition: drifted to (\(Int(current.origin.x)),\(Int(current.origin.y))) — re-applying (\(expectedX),\(expectedY)) [attempt \(enforceAttemptCount)/\(maxEnforceAttempts)]")

        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        if begin == .success, let config {
            CGConfigureDisplayOrigin(config, virtualID, expectedX, expectedY)
            let complete = CGCompleteDisplayConfiguration(config, .forSession)
            aslog("enforceVirtualPosition: CGCompleteDisplayConfiguration → \(complete.rawValue)")
            // Sync fence to the post-reposition rect.
            updateCursorFence(CGDisplayBounds(virtualID))
        } else {
            aslog("enforceVirtualPosition: CGBeginDisplayConfiguration failed: \(begin.rawValue)")
        }
    }

    /// Calls SLSSpaceResetMenuBar on every user space across all displays.
    static func resetAllMenuBars() {
        let conn = CGSMainConnectionID()
        guard let displays = CGSCopyManagedDisplaySpaces(conn) as? [[String: Any]] else { return }
        for display in displays {
            guard let spaces = display["Spaces"] as? [[String: Any]] else { continue }
            for space in spaces {
                guard let type = space["type"] as? Int, type == 0,
                      let spaceID = space["ManagedSpaceID"] as? Int else { continue }
                let rc = SLSSpaceResetMenuBar(conn, UInt64(spaceID))
                aslog("SLSSpaceResetMenuBar(space=\(spaceID)) → \(rc)")
            }
        }
    }

    /// Counts NSScreen.screens excluding our own virtual display if present.
    private static func physicalDisplayCount() -> Int {
        let virtualUUID = VirtualDisplayHelper.displayUUIDString()
        var count = 0
        for screen in NSScreen.screens {
            if let virtualUUID,
               let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                let cgID = CGDirectDisplayID(number.uint32Value)
                if let uuid = CGDisplayCreateUUIDFromDisplayID(cgID)?.takeRetainedValue(),
                   let uuidStr = CFUUIDCreateString(nil, uuid) as String?,
                   uuidStr == virtualUUID {
                    continue   // skip our own virtual display
                }
            }
            count += 1
        }
        return count
    }
}
