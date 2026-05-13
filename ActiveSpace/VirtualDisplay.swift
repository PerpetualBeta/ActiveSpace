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
    private static var lockObservers: [NSObjectProtocol] = []
    private static var lastEnforceAttempt: Date?
    private static var enforceAttemptCount = 0
    private static let maxEnforceAttempts = 5
    private static let enforceMinInterval: TimeInterval = 0.5

    /// Backoff counter for `startCursorFence` retries. `CGEvent.tapCreate`
    /// can return nil at very early session start (Aqua up but the event-tap
    /// subsystem not yet ready, observed on fresh boot). Without retry the
    /// fence stays dead until next launch.
    private static var fenceTapRetryAttempts = 0
    private static let fenceTapMaxRetries = 8

    /// Set while the screen is locked / screensaver is running. macOS otherwise
    /// renders one of its per-display screensaver instances onto the 640×480
    /// virtual, where the user either sees nothing (it's invisible) or sees a
    /// tiny instance constrained to the virtual's bounds. Tearing the virtual
    /// down for the duration eliminates that surface; reconcile() short-circuits
    /// while this is true so polling/event-driven recreates don't fight the
    /// suspend.
    private static var suspendedForLock = false

    /// True between create and the first verified-correct enforceVirtualPosition.
    /// The post-create menu-bar reset fires only once position is confirmed —
    /// firing earlier (the previous "1s after create" pattern) was eaten by
    /// long CGCompleteDisplayConfiguration calls blocking the main thread.
    private static var pendingPostCreateReset = false

    /// Single-flight guard around the destroy path. Reconcile can be called
    /// re-entrantly while CG APIs pump the run loop; without this guard a
    /// second reconcile triggered destroy on a helper that was mid-tear-down,
    /// producing the "skipping shrink" path observed 2026-04-25.
    private static var destroyInFlight = false

    // MARK: - Off-virtual sweep
    //
    // Continuous trap that yanks anything appearing on the virtual back to
    // main. Layered on top of the existing event-driven cursor fence and
    // the on-fence-rect-change AX window rescue — the timer is the
    // backstop for surfaces that materialise *between* events (Spotlight,
    // system overlays, windows opened directly into the virtual's frame).
    //
    // Gated on `VirtualDisplaySweepEnabled` UserDefaults boolean (default
    // false). To enable while we're iterating:
    //
    //     defaults write cc.jorviksoftware.ActiveSpace \
    //         VirtualDisplaySweepEnabled -bool YES
    //
    // Quit + relaunch ActiveSpace.

    private static var sweepTimer: DispatchSourceTimer?
    private static let sweepInterval: DispatchTimeInterval = .milliseconds(150)

    /// Throttle for Spotlight Esc-dismiss. Spotlight's window can persist for
    /// a tick or two after Esc is sent (animation out), so we'd otherwise
    /// re-send Esc several times before the window list reflects the
    /// dismissal. One dismiss per second is plenty.
    private static var lastSpotlightDismiss: Date = .distantPast
    private static let spotlightDismissCooldown: TimeInterval = 1.0

    private static var sweepEnabled: Bool {
        UserDefaults.standard.bool(forKey: "VirtualDisplaySweepEnabled")
    }

    /// Call once at app launch. Creates the virtual display if there's only one
    /// physical display, and installs an observer so it's added/removed as the
    /// user's display configuration changes.
    static func startManaging() {
        MenuBarResetGate.install()
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

        installLockObservers()
    }

    /// Subscribe to multiple "screen is about to be locked / screensaver is
    /// about to start" signals so whichever fires first triggers the suspend.
    /// All paths funnel into `suspendForLock(reason:)` which is idempotent.
    /// Resume is symmetric: any unlock/didstop signal triggers `resumeAfterUnlock`.
    ///
    /// Why three suspend signals: testing on 2026-04-29 showed `loginwindow`
    /// activation fires ~235ms before `com.apple.screenIsLocked`, which is
    /// 235ms of head-start to tear down the virtual before macOS picks
    /// per-display screensaver targets. `com.apple.screensaver.willstart`
    /// (when present) is earlier still. Idempotent suspend means it's safe
    /// to subscribe to all three and let whichever fires first do the work.
    private static func installLockObservers() {
        let dnc = DistributedNotificationCenter.default()
        let suspendNames = [
            "com.apple.screensaver.willstart",
            "com.apple.screenIsLocked",
        ]
        for name in suspendNames {
            let obs = dnc.addObserver(
                forName: NSNotification.Name(name),
                object: nil,
                queue: .main
            ) { _ in
                Self.suspendForLock(reason: name)
            }
            lockObservers.append(obs)
        }
        let resumeNames = [
            "com.apple.screensaver.didstop",
            "com.apple.screenIsUnlocked",
        ]
        for name in resumeNames {
            let obs = dnc.addObserver(
                forName: NSNotification.Name(name),
                object: nil,
                queue: .main
            ) { _ in
                Self.resumeAfterUnlock(reason: name)
            }
            lockObservers.append(obs)
        }

        // NSWorkspace activation of com.apple.loginwindow is the earliest
        // signal observed in practice (2026-04-29 test: 235ms before
        // screenIsLocked). Filter on bundle ID so other app activations
        // don't churn through the suspend path.
        let workspaceObs = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            guard
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                app.bundleIdentifier == "com.apple.loginwindow"
            else { return }
            Self.suspendForLock(reason: "loginwindow.activated")
        }
        lockObservers.append(workspaceObs)
    }

    /// Park the virtual display before the screensaver / lock screen can pick
    /// it as a render target. Idempotent — repeated calls while already
    /// suspended are no-ops.
    ///
    /// **Why park, not destroy.** The first cut of this path destroyed the
    /// virtual (commit pending). Verified 2026-04-29: that produces a black
    /// screen for the entire screensaver duration when Flurry is the active
    /// screensaver. Flurry is OpenGL-backed; if it picks the virtual's display
    /// for its primary surface and we then remove that display from
    /// NSScreen.screens during init, its GL context binds to a now-defunct
    /// surface and never recovers — black render. Parking instead — moving
    /// the virtual to (-32768, -32768) without releasing the
    /// `CGVirtualDisplay` reference — keeps the display count stable so the
    /// screensaver's display-pick is consistent end-to-end, while putting any
    /// instance that lands on the virtual far enough off-screen that the user
    /// never sees it.
    private static func suspendForLock(reason: String) {
        if suspendedForLock { return }
        suspendedForLock = true
        aslog("VirtualDisplay.suspendForLock(\(reason))")
        parkVirtual()
    }

    /// Move the virtual to (-32768, -32768). Display stays in NSScreen.screens
    /// at its current size, so anything that picks displays at this moment
    /// gets a stable list — the virtual's instance is just unreachable.
    private static func parkVirtual() {
        guard VirtualDisplayHelper.isCreated() else { return }
        if destroyInFlight {
            aslog("parkVirtual: destroy in flight, skipping")
            return
        }
        let virtualID = VirtualDisplayHelper.displayID()
        guard virtualID != 0 else { return }
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success, let config else {
            aslog("parkVirtual: CGBeginDisplayConfiguration failed: \(begin.rawValue)")
            return
        }
        CGConfigureDisplayOrigin(config, virtualID, -32768, -32768)
        let complete = CGCompleteDisplayConfiguration(config, .forSession)
        aslog("parkVirtual: relocated to (-32768,-32768) → \(complete.rawValue)")
        updateCursorFence(nil)
    }

    /// Clear the suspend flag and reconcile. The reconcile pass takes care of
    /// the unpark via `enforceVirtualPosition`, which sees the parked origin
    /// drifted from expected right-of-main and re-applies. If displays were
    /// changed during the lock (e.g. an external was unplugged), reconcile
    /// also handles the create/destroy transition. Enforce attempt counters
    /// are reset so the unpark gets a fresh 5-attempt budget.
    private static func resumeAfterUnlock(reason: String) {
        if !suspendedForLock { return }
        suspendedForLock = false
        aslog("VirtualDisplay.resumeAfterUnlock(\(reason))")
        enforceAttemptCount = 0
        lastEnforceAttempt = nil
        reconcile()
    }

    /// Install the cursor-fence CGEventTap. Cheap to leave permanently
    /// installed: when `_cursorFenceVirtualRect` is nil (no virtual present)
    /// the callback short-circuits on the first check. Retries with backoff
    /// if `tapCreate` returns nil — observed at very early session start on
    /// fresh boot when the event-tap subsystem isn't yet ready.
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
            fenceTapRetryAttempts += 1
            if fenceTapRetryAttempts <= fenceTapMaxRetries {
                let delay = min(4.0, 0.25 * pow(2.0, Double(fenceTapRetryAttempts - 1)))
                aslog("CursorFence: tapCreate failed, retrying in \(delay)s (attempt \(fenceTapRetryAttempts)/\(fenceTapMaxRetries))")
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    Self.startCursorFence()
                }
            } else {
                aslog("CursorFence: tapCreate failed permanently after \(fenceTapMaxRetries) attempts")
            }
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        _cursorFenceTap = tap
        fenceTapRetryAttempts = 0
        aslog("CursorFence: tap installed")
        // If the tap came up after retries, the rect may already be set —
        // sweep any cursor/window stranded during the install gap.
        rescueCursorIfInsideVirtual()
        rescueWindowsInsideVirtual()
    }

    /// Update the fence rect so the tap callback knows what region to block.
    /// Pass nil to disable the fence (e.g. when the virtual is destroyed).
    private static func updateCursorFence(_ rect: CGRect?) {
        _cursorFenceVirtualRect = rect
        if let rect {
            aslog("CursorFence: rect=\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width))x\(Int(rect.height))")
            // Whenever the rect is (re)set — fresh-boot create, post-unlock
            // resume, display-change reconcile — sweep the cursor and any
            // fully-stranded windows out of the virtual. The fence's tap
            // only fires on mouseMoved/dragged, so anything that landed on
            // the virtual without an event (cursor restored at login,
            // window reopened on its last frame, etc.) needs an explicit
            // rescue here. Idempotent — a no-op when nothing's on it.
            rescueCursorIfInsideVirtual()
            rescueWindowsInsideVirtual()
            startSweepTimer()
        } else {
            aslog("CursorFence: disabled")
            stopSweepTimer()
        }
    }

    /// Continuous off-virtual sweep. Runs on `sweepTimer` while the virtual
    /// exists and is not parked, gated on the `VirtualDisplaySweepEnabled`
    /// UserDefaults flag.
    ///
    /// Two effects per tick:
    ///
    /// 1. **Cursor backstop.** Calls `rescueCursorIfInsideVirtual()`. Catches
    ///    cursor placements that don't fire mouseMoved (login restore, app
    ///    launch, post-config-change), which the event-driven fence misses.
    ///
    /// 2. **Spotlight Esc-dismiss.** If a Spotlight window has landed fully
    ///    inside the virtual rect (the bug — Spotlight invisible until
    ///    ActiveSpace is killed), post a synthetic Esc to dismiss it. The
    ///    user re-invokes via cmd+space, Spotlight follows the menu bar =
    ///    main display. Throttled to one dismiss per second so the dismiss
    ///    animation completes before we'd consider another.
    ///
    /// **What this is not.** A general window-move trap. The earlier design
    /// used `SLSMoveWindow` for cross-process moves; empirically that returns
    /// `kCGErrorFailure` (rc=1000) every time — SLS won't move another
    /// process's window from our connection without privileges we don't ship
    /// with. The targeted Esc-dismiss is the only system-UI rescue path we
    /// can actually deliver. Cooperating apps are still covered by the
    /// existing event-driven AX rescue (`rescueWindowsInsideVirtual`) which
    /// fires on fence-rect changes.
    private static func sweepVirtual() {
        guard sweepEnabled else { return }
        guard !suspendedForLock else { return }
        guard !destroyInFlight else { return }
        guard let virtualRect = _cursorFenceVirtualRect else { return }

        // Cursor backstop.
        rescueCursorIfInsideVirtual()

        // Spotlight check.
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return }

        for window in windowList {
            guard let boundsDict = window[kCGWindowBounds as String] as? [String: Any] else { continue }
            let x = (boundsDict["X"] as? NSNumber)?.doubleValue ?? 0
            let y = (boundsDict["Y"] as? NSNumber)?.doubleValue ?? 0
            let w = (boundsDict["Width"] as? NSNumber)?.doubleValue ?? 0
            let h = (boundsDict["Height"] as? NSNumber)?.doubleValue ?? 0
            guard w > 0, h > 0 else { continue }
            let frame = CGRect(x: x, y: y, width: w, height: h)
            guard virtualRect.contains(frame) else { continue }
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t else { continue }

            if isSpotlight(pid: pid, ownerName: window[kCGWindowOwnerName as String] as? String) {
                let now = Date()
                if now.timeIntervalSince(lastSpotlightDismiss) >= spotlightDismissCooldown {
                    postEscape()
                    lastSpotlightDismiss = now
                    aslog("sweep: Spotlight on virtual at \(NSStringFromRect(NSRectFromCGRect(frame))) — sent Esc to dismiss")
                }
                return  // Spotlight handled — no other windows worth checking on the same tick
            }
        }
    }

    /// Spotlight identification — owner name "Spotlight" is the fast path,
    /// bundle-ID `com.apple.Spotlight` is the belt-and-braces (handles
    /// renames or future macOS structural changes). Returns false when we
    /// can't resolve either signal — better to skip than wrongly Esc some
    /// other process.
    private static func isSpotlight(pid: pid_t, ownerName: String?) -> Bool {
        if ownerName == "Spotlight" { return true }
        if let app = NSRunningApplication(processIdentifier: pid),
           let bundle = app.bundleIdentifier,
           bundle == "com.apple.Spotlight" {
            return true
        }
        return false
    }

    /// Post a synthetic Esc keystroke. Used to dismiss Spotlight when its
    /// window has rendered on the virtual (invisible to the user). After
    /// dismissal the user re-invokes Spotlight, which follows the menu bar
    /// and renders on the main display.
    private static func postEscape() {
        let src = CGEventSource(stateID: .hidSystemState)
        let escapeKeyCode: CGKeyCode = 0x35
        let down = CGEvent(keyboardEventSource: src, virtualKey: escapeKeyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: escapeKeyCode, keyDown: false)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Start the sweep timer if the flag is on and not already running.
    /// Idempotent. Runs on the main queue so AX/CGS calls inside the handler
    /// observe consistent UI state.
    private static func startSweepTimer() {
        guard sweepEnabled else { return }
        guard sweepTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + sweepInterval,
            repeating: sweepInterval,
            leeway: .milliseconds(50)
        )
        timer.setEventHandler { sweepVirtual() }
        timer.resume()
        sweepTimer = timer
        aslog("sweep: timer started (interval 150ms)")
    }

    /// Cancel the sweep timer. Called from updateCursorFence(nil), teardown,
    /// and any path that destroys the virtual. Safe to call when no timer is
    /// running.
    private static func stopSweepTimer() {
        guard sweepTimer != nil else { return }
        sweepTimer?.cancel()
        sweepTimer = nil
        aslog("sweep: timer stopped")
    }

    /// Warp the cursor to the centre of the main display if it's currently
    /// inside the virtual's rect. Mirrors MouseCatcher's logic but runs
    /// automatically — recovers the cursor in cases where no mouseMoved
    /// event will fire to trigger the fence.
    private static func rescueCursorIfInsideVirtual() {
        guard let rect = _cursorFenceVirtualRect else { return }
        guard let loc = CGEvent(source: nil)?.location else { return }
        guard rect.contains(loc) else { return }
        let mainBounds = CGDisplayBounds(CGMainDisplayID())
        let target = CGPoint(x: mainBounds.midX, y: mainBounds.midY)
        aslog("rescueCursor: cursor at (\(Int(loc.x)),\(Int(loc.y))) inside virtual; warping to (\(Int(target.x)),\(Int(target.y)))")
        _ = CGAssociateMouseAndMouseCursorPosition(1)
        CGWarpMouseCursorPosition(target)
    }

    /// Move any window whose frame is fully inside the virtual's rect back
    /// to the centre of main. Only rescues windows fully contained in the
    /// virtual — windows that span main and virtual are left alone since
    /// the user may have intentionally parked them at main's right edge.
    /// Walks the on-screen CG list to find candidates, then resolves each
    /// to its AXUIElement via `_AXUIElementGetWindow` so we can SetPosition.
    private static func rescueWindowsInsideVirtual() {
        guard let virtualRect = _cursorFenceVirtualRect else { return }
        let mainBounds = CGDisplayBounds(CGMainDisplayID())

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return }

        // Group candidate CGWindowIDs by owning PID so we make at most one
        // AX enumeration per process.
        var candidatesByPID: [pid_t: Set<CGWindowID>] = [:]
        for window in windowList {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let boundsDict = window[kCGWindowBounds as String] as? [String: Any] else { continue }
            let x = (boundsDict["X"] as? NSNumber)?.doubleValue ?? 0
            let y = (boundsDict["Y"] as? NSNumber)?.doubleValue ?? 0
            let w = (boundsDict["Width"] as? NSNumber)?.doubleValue ?? 0
            let h = (boundsDict["Height"] as? NSNumber)?.doubleValue ?? 0
            guard w > 0, h > 0 else { continue }
            let frame = CGRect(x: x, y: y, width: w, height: h)
            guard virtualRect.contains(frame) else { continue }
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t else { continue }
            guard let cgID = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            candidatesByPID[pid, default: []].insert(CGWindowID(cgID))
        }

        if candidatesByPID.isEmpty { return }
        aslog("rescueWindows: \(candidatesByPID.values.reduce(0) { $0 + $1.count }) candidate(s) across \(candidatesByPID.count) process(es)")

        for (pid, cgIDs) in candidatesByPID {
            let appEl = AXUIElementCreateApplication(pid)
            var value: CFTypeRef?
            let rc = AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &value)
            guard rc == .success, let axWindows = value as? [AXUIElement] else { continue }

            for axWin in axWindows {
                var winID: CGWindowID = 0
                guard _AXUIElementGetWindow(axWin, &winID) == .success else { continue }
                guard cgIDs.contains(winID) else { continue }

                // Read size to centre the window on main; default to a
                // sensible offset if size lookup fails.
                var size = CGSize(width: 400, height: 300)
                var sizeRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(axWin, kAXSizeAttribute as CFString, &sizeRef) == .success,
                   let sizeVal = sizeRef, CFGetTypeID(sizeVal) == AXValueGetTypeID() {
                    let axVal = sizeVal as! AXValue
                    if AXValueGetType(axVal) == .cgSize {
                        var s = CGSize.zero
                        if AXValueGetValue(axVal, .cgSize, &s) { size = s }
                    }
                }

                var newOrigin = CGPoint(
                    x: mainBounds.midX - size.width / 2,
                    y: mainBounds.midY - size.height / 2
                )
                // Clamp so the title bar stays draggable.
                if newOrigin.x < mainBounds.minX { newOrigin.x = mainBounds.minX }
                if newOrigin.y < mainBounds.minY { newOrigin.y = mainBounds.minY }

                if let posVal = AXValueCreate(.cgPoint, &newOrigin) {
                    let setRC = AXUIElementSetAttributeValue(axWin, kAXPositionAttribute as CFString, posVal)
                    aslog("rescueWindow: pid=\(pid) winID=\(winID) → (\(Int(newOrigin.x)),\(Int(newOrigin.y))) rc=\(setRC.rawValue)")
                }
            }
        }
    }

    /// Returns the current virtual display's bounds if present, else nil.
    /// Uses the synchronously-captured `CGDirectDisplayID` from the helper rather
    /// than UUID-iterating `NSScreen.screens` — the UUID lookup is lazily resolved
    /// and races right after creation, leaving the cursor fence unarmed even when
    /// the virtual is fully created and queryable via its display ID.
    private static func currentVirtualRect() -> CGRect? {
        guard VirtualDisplayHelper.isCreated() else { return nil }
        let virtualID = VirtualDisplayHelper.displayID()
        guard virtualID != 0 else { return nil }
        return CGDisplayBounds(virtualID)
    }

    /// CFUUID-string identifier of the virtual display, or nil if not created.
    static var uuidString: String? {
        VirtualDisplayHelper.displayUUIDString()
    }

    /// Tear down and rebuild the virtual display at whatever size is currently
    /// stored in UserDefaults. Used by the size-walk experiment in Settings —
    /// the picker writes new VirtualDisplayWidth / VirtualDisplayHeight
    /// defaults, then calls this to recreate the display so the new size
    /// takes effect without an app relaunch. Multi-display configurations
    /// are short-circuited (no virtual is needed).
    static func recreate() {
        aslog("VirtualDisplay.recreate (settings size change)")
        guard physicalDisplayCount() <= 1 else {
            aslog("recreate: multi-display, no virtual to recreate")
            return
        }
        if VirtualDisplayHelper.isCreated() {
            if destroyInFlight {
                aslog("recreate: destroy already in flight — bailing")
                return
            }
            destroyInFlight = true
            VirtualDisplayHelper.destroy()
            updateCursorFence(nil)
            destroyInFlight = false
        }
        enforceAttemptCount = 0
        lastEnforceAttempt = nil
        // Brief delay so WindowServer fully releases the old display's
        // framebuffer before we register the new one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            Self.reconcile()
        }
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
        let dnc = DistributedNotificationCenter.default()
        let wnc = NSWorkspace.shared.notificationCenter
        for observer in lockObservers {
            dnc.removeObserver(observer)
            wnc.removeObserver(observer)
        }
        lockObservers.removeAll()
        stopSweepTimer()
        if VirtualDisplayHelper.isCreated() {
            VirtualDisplayHelper.destroy()
        }
    }

    // MARK: - Private

    /// Match the virtual display's presence to whether it's currently needed.
    private static func reconcile() {
        if suspendedForLock {
            aslog("VirtualDisplay.reconcile: suspended for lock — skipping")
            return
        }
        let realCount = physicalDisplayCount()
        let haveVirtual = VirtualDisplayHelper.isCreated()
        let needVirtual = realCount <= 1

        aslog("VirtualDisplay.reconcile: real=\(realCount) haveVirtual=\(haveVirtual) needVirtual=\(needVirtual)")

        // Heal: during a hot-swap that briefly drops to zero real displays, the
        // virtual is promoted to CGMainDisplayID and the Dock binds to it. When
        // a real display returns, the Dock stays trapped on the virtual until
        // the user quits ActiveSpace. Detect that state and destroy the virtual
        // ourselves — the next reconcile pass will recreate it cleanly with the
        // real display as main, and the Dock follows the real display in the gap.
        if haveVirtual {
            let mainID = CGMainDisplayID()
            let virtualID = VirtualDisplayHelper.displayID()
            if virtualID != 0 && mainID == virtualID && realCount >= 1 && !destroyInFlight {
                aslog("VirtualDisplay.reconcile: HEAL — main=virtual, realCount=\(realCount); destroying to free Dock")
                destroyInFlight = true
                defer { destroyInFlight = false }
                pendingPostCreateReset = false
                VirtualDisplayHelper.destroy()
                updateCursorFence(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                    Self.reconcile()
                }
                return
            }
        }

        if needVirtual && !haveVirtual {
            _ = VirtualDisplayHelper.create()
            enforceAttemptCount = 0   // fresh creation — reset drift counter
            // The post-create menu-bar reset fires from `firePendingPostCreateReset`
            // once `enforceVirtualPosition` has *verified* the placement. The old
            // "asyncAfter(.now() + 1.0)" pattern lost the reset entirely when
            // CGCompleteDisplayConfiguration blocked main for >1s during display
            // flapping — the queued block ran after destroy, by which point the
            // virtual that needed resetting was already gone.
            pendingPostCreateReset = true
        } else if !needVirtual && haveVirtual {
            if destroyInFlight {
                aslog("VirtualDisplay.reconcile: destroy already in flight, skipping duplicate")
                return
            }
            destroyInFlight = true
            defer { destroyInFlight = false }
            pendingPostCreateReset = false   // any pending reset is now moot
            VirtualDisplayHelper.destroy()
            // Belt-and-braces: after the system's display reconfiguration
            // settles, fire one final menu-bar reset. Catches residual
            // coordinate-space corruption from any anomalous virtual placement
            // (e.g. the Y=-480 we observed under display flapping) that might
            // not have been healed by an in-life reset.
            //
            // Routed through MenuBarResetGate: SLSSpaceResetMenuBar invoked
            // mid-reconfig was correlated with a WindowServer SIGABRT in
            // iosurface_create_common during display hot-swap (crash report
            // 2026-05-13). The gate defers the actual call until the CG
            // reconfiguration callback signals end-of-config + 200ms quiet
            // period, which subsumes (and is more precise than) the prior
            // fixed 1.0s asyncAfter.
            aslog("Post-destroy menu-bar reset requested (gated)")
            MenuBarResetGate.request()
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
        guard VirtualDisplayHelper.isCreated() else { return }

        // Use the synchronously-captured display ID rather than UUID-iterating
        // NSScreen.screens. The UUID lookup is racy right after creation —
        // when it fails we'd return silently here, defeating the verification
        // and retry logic below as well as keeping the cursor fence unarmed.
        let virtualID = VirtualDisplayHelper.displayID()
        guard virtualID != 0 else { return }

        let mainBounds = CGDisplayBounds(CGMainDisplayID())
        let expectedX = Int32(mainBounds.origin.x + mainBounds.size.width)
        let expectedY = Int32(mainBounds.origin.y)
        let current = CGDisplayBounds(virtualID)

        if Int32(current.origin.x) == expectedX && Int32(current.origin.y) == expectedY {
            firePendingPostCreateReset()
            return
        }

        // Rate-limit so a re-apply that macOS immediately overrides doesn't
        // spin in a notification loop.
        if let last = lastEnforceAttempt, Date().timeIntervalSince(last) < enforceMinInterval {
            aslog("enforceVirtualPosition: rate-limit skip (last attempt \(Int(Date().timeIntervalSince(last) * 1000))ms ago)")
            return
        }
        if enforceAttemptCount >= maxEnforceAttempts {
            aslog("enforceVirtualPosition: giving up after \(maxEnforceAttempts) attempts — virtual at (\(Int(current.origin.x)),\(Int(current.origin.y))); destroy+recreate")
            // A virtual stuck at a position we couldn't enforce is exactly the
            // "attractive landing spot for the Dock" condition the enforcement
            // was meant to prevent. Tear it down so reconcile can recreate it
            // cleanly with main re-evaluated; in the gap the Dock has only the
            // real display to bind to.
            firePendingPostCreateReset()
            enforceAttemptCount = 0
            if !destroyInFlight {
                destroyInFlight = true
                defer { destroyInFlight = false }
                VirtualDisplayHelper.destroy()
                updateCursorFence(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                    Self.reconcile()
                }
            }
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

            // Verify the position actually took. macOS sometimes accepts the
            // request but applies a different placement (e.g. Y=-480 above
            // main instead of Y=0 right of main, observed under display
            // flapping 2026-04-25). The old code wrote the cursor fence from
            // the post-CGComplete bounds and returned satisfied — we now
            // verify, then either fire the post-create reset (if good) or
            // schedule a retry past the rate-limit window (if still drifted).
            let postBounds = CGDisplayBounds(virtualID)
            let actualX = Int32(postBounds.origin.x)
            let actualY = Int32(postBounds.origin.y)
            updateCursorFence(postBounds)
            if actualX == expectedX && actualY == expectedY {
                aslog("enforceVirtualPosition: verified at (\(actualX),\(actualY))")
                firePendingPostCreateReset()
            } else {
                aslog("enforceVirtualPosition: STILL DRIFTED — bounds report (\(actualX),\(actualY)), expected (\(expectedX),\(expectedY)); scheduling retry")
                DispatchQueue.main.asyncAfter(deadline: .now() + enforceMinInterval + 0.25) {
                    enforceVirtualPosition()
                }
            }
        } else {
            aslog("enforceVirtualPosition: CGBeginDisplayConfiguration failed: \(begin.rawValue)")
        }
    }

    /// Fire the post-create menu-bar reset if one is pending, then clear the
    /// flag. Called from every path where placement is known to be correct
    /// (or where we've given up trying — best-effort).
    private static func firePendingPostCreateReset() {
        guard pendingPostCreateReset else { return }
        pendingPostCreateReset = false
        // Position verification ran inside a CGBeginDisplayConfiguration /
        // CGCompleteDisplayConfiguration pair, so a CG reconfig callback
        // may still be in flight. Route through the gate rather than calling
        // resetAllMenuBars directly — see MenuBarResetGate for rationale.
        aslog("Post-create menu-bar reset requested (gated, position verified)")
        MenuBarResetGate.request()
    }

    /// Calls SLSSpaceResetMenuBar on every user space across all displays.
    ///
    /// **Kill switch:** set `MenuBarResetDisabled` in UserDefaults to skip the
    /// SLS calls entirely (the gate and surrounding logging still run, so the
    /// log shows exactly when a reset *would* have fired). Used to bisect
    /// whether SLSSpaceResetMenuBar is the trigger for the WindowServer
    /// SIGABRT in iosurface_create_common during display hot-swap (crash
    /// report 2026-05-13). Disable with:
    ///
    ///     defaults write cc.jorviksoftware.ActiveSpace \
    ///         MenuBarResetDisabled -bool YES
    ///
    /// Quit + relaunch ActiveSpace. Re-enable by setting to NO or deleting
    /// the key. Key is negative so the default (unset = false) leaves
    /// production behaviour unchanged.
    static func resetAllMenuBars() {
        if UserDefaults.standard.bool(forKey: "MenuBarResetDisabled") {
            aslog("resetAllMenuBars: skipped — MenuBarResetDisabled is set")
            return
        }
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
    /// Matches our virtual by its `CGDirectDisplayID` (captured synchronously
    /// at create time) rather than by UUID — which is lazily resolved and
    /// therefore racy right after creation. The direct-ID comparison is
    /// stable and cheap.
    private static func physicalDisplayCount() -> Int {
        let virtualID = VirtualDisplayHelper.displayID()   // 0 if no virtual
        var count = 0
        for screen in NSScreen.screens {
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                count += 1
                continue
            }
            let cgID = CGDirectDisplayID(n.uint32Value)
            if virtualID != 0 && cgID == virtualID {
                continue   // our own virtual — don't count as physical
            }
            count += 1
        }
        return count
    }
}

// MARK: - Menu-bar reset gating

/// Defers `VirtualDisplay.resetAllMenuBars()` until the system has finished
/// applying a display reconfiguration.
///
/// **Why:** `SLSSpaceResetMenuBar` forces WindowServer to re-allocate the
/// per-connection menu-bar `IOSurface` for every space. Calling it while a
/// display reconfiguration is still in flight has been correlated with a
/// WindowServer `SIGABRT` in `iosurface_create_common` during display
/// hot-swap (crash report 2026-05-13, MacBook Pro driving 5 externals + the
/// virtual). The notification we previously keyed off
/// (`NSApplication.didChangeScreenParametersNotification`) arrives *during*
/// the reconfig window, not after it. The CG reconfiguration callback is
/// the precise signal: it pairs a begin-flag call with a matching end-flag
/// call per affected display, so we know when the system has settled.
///
/// **Behaviour:** A `request()` either fires immediately (with a 200ms quiet
/// period to absorb cascaded reconfigs — wake-from-sleep produces two
/// rounds in practice) or defers until the in-flight counter returns to
/// zero. Repeated requests while pending coalesce into one reset. All state
/// mutation hops to the main thread so there's a single owner.
enum MenuBarResetGate {

    /// Pair counter: incremented on each `.beginConfigurationFlag` callback,
    /// decremented on each matching end-flag callback. Non-zero means a
    /// system reconfiguration is in progress and the gate is closed.
    private static var inFlightCount = 0

    /// True between `request()` and the corresponding flush. Multiple
    /// requests while pending coalesce into one reset.
    private static var requestPending = false

    private static var flushWorkItem: DispatchWorkItem?
    private static var installed = false

    /// Quiet period after `inFlightCount` returns to zero before flushing.
    /// 200ms is enough for the second round of a wake-from-sleep cascade to
    /// arrive without being painted over by an early reset.
    private static let quietPeriod: TimeInterval = 0.2

    /// Install the CG reconfiguration callback. Idempotent. Call once at launch.
    static func install() {
        guard !installed else { return }
        installed = true
        CGDisplayRegisterReconfigurationCallback(cgCallback, nil)
        aslog("MenuBarResetGate: installed")
    }

    /// Ask the gate to issue a `resetAllMenuBars()` call. Fires after the
    /// current reconfiguration (if any) settles, plus the quiet period.
    static func request() {
        dispatchPrecondition(condition: .onQueue(.main))
        requestPending = true
        aslog("MenuBarResetGate: request (inFlight=\(inFlightCount))")
        scheduleFlushIfPossible()
    }

    /// CG calls this on its own thread; we hop to main so every read/write
    /// of the static state happens on a single queue.
    private static let cgCallback: CGDisplayReconfigurationCallBack = { _, flags, _ in
        DispatchQueue.main.async {
            if flags.contains(.beginConfigurationFlag) {
                inFlightCount += 1
                // A new reconfig started — any in-progress flush is now
                // premature. Cancel it; the matching end callback will
                // reschedule.
                flushWorkItem?.cancel()
                flushWorkItem = nil
            } else {
                inFlightCount = max(0, inFlightCount - 1)
                scheduleFlushIfPossible()
            }
        }
    }

    private static func scheduleFlushIfPossible() {
        guard requestPending, inFlightCount == 0 else { return }
        flushWorkItem?.cancel()
        let work = DispatchWorkItem {
            // Re-check at fire time: a fresh begin callback may have
            // arrived between scheduling and now (it would have cancelled
            // this work item; defensive check anyway).
            guard inFlightCount == 0, requestPending else { return }
            requestPending = false
            flushWorkItem = nil
            aslog("MenuBarResetGate: flush — invoking resetAllMenuBars")
            VirtualDisplay.resetAllMenuBars()
        }
        flushWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + quietPeriod, execute: work)
    }
}
