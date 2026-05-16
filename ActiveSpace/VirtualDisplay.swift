import AppKit
import Foundation
import Darwin

/// Launches and supervises the bundled VirtualDisplayHost helper, which
/// owns the CGVirtualDisplay private-API lifecycle out-of-process. The
/// helper creates an off-screen virtual display whose only purpose is
/// to flip `NSScreen.screens.count` from 1 to 2 — the single operative
/// condition that disarms macOS-16's "Main"-identifier gesture-routing
/// bug on single-monitor setups (probe 2026-05-08; see KB note
/// `memory-project-activespace-virtual-size`).
///
/// **Why out-of-process.** In-process CGVirtualDisplay creation from
/// ActiveSpace collided with WindowServer's saved-state replay
/// (`~/Library/Preferences/ByHost/com.apple.windowserver.displays.*.plist`):
/// vendor `0xACE5` had accumulated mirror-master entanglements that
/// caused initial `CGCompleteDisplayConfiguration` to fail with
/// `kCGErrorIllegalArgument` and the resulting virtual never registered
/// in `NSScreen.screens`. The helper uses unique vendor `0x4A56` ("JV")
/// which the saved-state index has never seen, so each launch is a
/// clean first-time registration. As a side benefit, parking the
/// virtual at `(-32768,-32768)` — clamped by macOS to `(-width,-height)`
/// — makes the virtual fully unreachable by cursor or windows, which
/// eliminates the entire stack of in-process mitigations (cursor fence,
/// off-virtual sweep, AX window rescue, MouseCatcher, parkVirtual for
/// screen lock).
///
/// **Lifecycle.** `applicationDidFinishLaunching` calls `startManaging`,
/// which installs the screen-params observer and runs the initial
/// reconcile. On single-display setups the helper is launched as a
/// child `Process`; on 2+ display setups the helper is not needed and
/// stays unlaunched (or is stopped if it was previously running).
/// `applicationWillTerminate` calls `teardown`, which sends SIGTERM to
/// the helper. As a belt-and-braces against ActiveSpace crashing hard
/// before SIGTERM, the helper polls `getppid()` every two seconds and
/// exits when it changes (we got reparented to launchd / pid 1).
///
/// **Crash recovery.** Process.terminationHandler fires when the
/// helper exits unexpectedly. If we still need the virtual, relaunch
/// with exponential backoff (250ms, 500ms, 1s, 2s, 4s, 8s capped,
/// counter reset after a successful run lasting 30s+).
enum VirtualDisplay {

    /// Vendor ID the helper stamps onto its virtual. Matched here for
    /// physicalDisplayCount's exclusion logic — any active display
    /// reporting this vendor is one of ours.
    private static let helperVendorID: UInt32 = 0x4A56

    private static var helperProcess: Process?
    private static var screenObserver: NSObjectProtocol?
    private static var relaunchAttempt = 0
    private static var lastSuccessfulLaunch: Date?
    private static var stopRequested = false  // distinguishes intentional vs unexpected exit

    /// Call once at app launch. Installs the screen-params observer and
    /// runs an initial reconcile to bring the helper up if needed.
    static func startManaging() {
        MenuBarResetGate.install()
        reconcile()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            reconcile()
        }
    }

    /// Call from `applicationWillTerminate` so the helper is signalled
    /// before launchd cleans us up. The helper's SIGTERM handler
    /// releases its CGVirtualDisplay reference, which deregisters the
    /// virtual cleanly.
    static func teardown() {
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
            screenObserver = nil
        }
        stopHelper()
    }

    /// Kill+relaunch the helper. Used by the size-walk-down experiment
    /// in Settings ("Apply" after picking a new VirtualDisplayWidth /
    /// VirtualDisplayHeight). The helper currently hardcodes 800×600,
    /// so this is effectively a no-op for size changes — it still
    /// bounces the virtual, which is useful for ad-hoc testing.
    static func recreate() {
        aslog("VirtualDisplay.recreate")
        stopHelper()
        // Brief delay so WindowServer fully tears down before we
        // register the new instance.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            reconcile()
        }
    }

    // MARK: - Reconcile

    private static func reconcile() {
        let realCount = physicalDisplayCount()
        let helperRunning = (helperProcess?.isRunning ?? false)
        let needHelper = (realCount <= 1)

        aslog("VirtualDisplay.reconcile: real=\(realCount) helperRunning=\(helperRunning) needHelper=\(needHelper)")

        if needHelper && !helperRunning {
            launchHelper()
        } else if !needHelper && helperRunning {
            stopHelper()
        }
    }

    /// Counts active displays excluding our helper's virtual (matched
    /// by vendor ID). With the helper running, expected output on a
    /// single-monitor Mac is 1.
    private static func physicalDisplayCount() -> Int {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success,
              displayCount > 0 else { return 0 }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displays, &displayCount) == .success else { return 0 }
        let active = Array(displays.prefix(Int(displayCount)))
        let descs = active.map { id -> String in
            let b = CGDisplayBounds(id)
            let vendor = CGDisplayVendorNumber(id)
            let mark = (vendor == helperVendorID) ? " OURS" : ""
            return "id=\(id) v=\(String(vendor, radix: 16)) (\(Int(b.origin.x)),\(Int(b.origin.y))) \(Int(b.size.width))x\(Int(b.size.height))\(mark)"
        }
        aslog("physicalDisplayCount: active=\(active.count) [\(descs.joined(separator: " | "))]")
        return active.filter { CGDisplayVendorNumber($0) != helperVendorID }.count
    }

    // MARK: - Helper lifecycle

    private static func launchHelper() {
        // Guard against the reconcile-vs-scheduleRelaunch race: when the
        // helper dies, both NSApplication.didChangeScreenParameters and
        // terminationHandler fire; reconcile launches one helper, and
        // scheduleRelaunch's delayed asyncAfter would launch another a
        // moment later. Idempotency here is cheaper than coordinating
        // the two paths.
        if let existing = helperProcess, existing.isRunning {
            aslog("launchHelper: already running (PID \(existing.processIdentifier)), skipping")
            return
        }
        guard let helperURL = locateHelper() else {
            aslog("launchHelper: helper bundle not found at Contents/Helpers/VirtualDisplayHost.app — single-display mitigation unavailable")
            return
        }
        stopRequested = false
        let process = Process()
        process.executableURL = helperURL
        // Combine helper stderr into our log so its diagnostics live in
        // /tmp/activespace.log alongside ActiveSpace's. The helper's
        // log() writes to stderr.
        if let logHandle = FileHandle(forWritingAtPath: "/tmp/activespace.log") {
            logHandle.seekToEndOfFile()
            process.standardOutput = logHandle
            process.standardError = logHandle
        }
        process.terminationHandler = { proc in
            DispatchQueue.main.async {
                helperTerminated(proc)
            }
        }
        do {
            try process.run()
            helperProcess = process
            lastSuccessfulLaunch = Date()
            aslog("launchHelper: started PID \(process.processIdentifier)")
            // The helper's CGCompleteDisplayConfiguration will fire a
            // CG reconfig event in this process. Request a gated
            // menu-bar reset that the gate will flush after the quiet
            // period — same machinery that handled the old in-process
            // create path.
            MenuBarResetGate.request()
        } catch {
            aslog("launchHelper: run() failed — \(error)")
            scheduleRelaunch()
        }
    }

    private static func stopHelper() {
        guard let process = helperProcess else { return }
        stopRequested = true
        helperProcess = nil
        if process.isRunning {
            kill(process.processIdentifier, SIGTERM)
            aslog("stopHelper: sent SIGTERM to PID \(process.processIdentifier)")
        }
        // Helper's exit fires a CG reconfig event too — request a
        // post-destroy menu-bar reset.
        MenuBarResetGate.request()
    }

    private static func helperTerminated(_ process: Process) {
        let status = process.terminationStatus
        let reason = process.terminationReason.rawValue
        if stopRequested {
            aslog("helper exited (intentional): reason=\(reason) status=\(status)")
            stopRequested = false
            return
        }
        // helperProcess might already be nil if stopHelper ran concurrently —
        // in that case treat as intentional.
        guard helperProcess === process else {
            aslog("helper exited (superseded): reason=\(reason) status=\(status)")
            return
        }
        helperProcess = nil
        aslog("helper exited UNEXPECTEDLY: reason=\(reason) status=\(status)")
        // The CG reconfig from the helper's death triggers
        // didChangeScreenParameters → reconcile, which will launch a
        // replacement helper directly. scheduleRelaunch's delayed asyncAfter
        // is the backstop for the case where reconcile doesn't run (which
        // shouldn't normally happen, but: belt and braces).
        scheduleRelaunch()
    }

    private static func scheduleRelaunch() {
        // Reset the attempt counter if the previous run survived long
        // enough — a one-off crash followed by a stable run shouldn't
        // accumulate backoff against future crashes.
        if let last = lastSuccessfulLaunch, Date().timeIntervalSince(last) >= 30 {
            relaunchAttempt = 0
        }
        let delay = min(8.0, 0.25 * pow(2.0, Double(relaunchAttempt)))
        relaunchAttempt += 1
        aslog("scheduleRelaunch: attempt \(relaunchAttempt) in \(delay)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // Only relaunch if reconcile still wants the helper. If
            // a real external has been plugged in during the backoff,
            // we don't need the helper any more.
            if physicalDisplayCount() <= 1 {
                launchHelper()
            } else {
                aslog("scheduleRelaunch: real count > 1 now, helper no longer needed")
                relaunchAttempt = 0
            }
        }
    }

    private static func locateHelper() -> URL? {
        let helperBinary = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/VirtualDisplayHost.app/Contents/MacOS/VirtualDisplayHost")
        guard FileManager.default.isExecutableFile(atPath: helperBinary.path) else {
            return nil
        }
        return helperBinary
    }
}

// MARK: - Menu-bar reset gating

/// Defers `SLSSpaceResetMenuBar` until the system has finished applying a
/// display reconfiguration.
///
/// **Why:** `SLSSpaceResetMenuBar` forces WindowServer to re-allocate the
/// per-connection menu-bar `IOSurface` for every space. Calling it while
/// a display reconfiguration is still in flight has been correlated with
/// a WindowServer `SIGABRT` in `iosurface_create_common` during display
/// hot-swap (crash report 2026-05-13). The
/// `NSApplication.didChangeScreenParametersNotification` arrives *during*
/// the reconfig window, not after it; the CG reconfiguration callback
/// pairs a begin-flag call with a matching end-flag call per affected
/// display, so we can detect when the system has settled.
///
/// **Behaviour:** `request()` either fires immediately (with a 200ms
/// quiet period to absorb cascaded reconfigs — wake-from-sleep produces
/// two rounds in practice) or defers until the in-flight counter
/// returns to zero. Repeated requests while pending coalesce into one
/// reset. A hard 2.0s `maxDeferral` backstop fires the reset regardless
/// of inFlight if a begin/end pair fails to balance back to zero.
enum MenuBarResetGate {

    private static var inFlightCount = 0
    private static var requestPending = false
    private static var flushWorkItem: DispatchWorkItem?
    private static var maxDeferralWorkItem: DispatchWorkItem?
    private static var installed = false

    private static let quietPeriod: TimeInterval = 0.2
    private static let maxDeferral: TimeInterval = 2.0

    static func install() {
        guard !installed else { return }
        installed = true
        CGDisplayRegisterReconfigurationCallback(cgCallback, nil)
        aslog("MenuBarResetGate: installed")
    }

    static func request() {
        dispatchPrecondition(condition: .onQueue(.main))
        let firstRequest = !requestPending
        requestPending = true
        aslog("MenuBarResetGate: request (inFlight=\(inFlightCount), firstRequest=\(firstRequest))")
        if firstRequest { armMaxDeferralTimer() }
        scheduleFlushIfPossible()
    }

    private static let cgCallback: CGDisplayReconfigurationCallBack = { _, flags, _ in
        DispatchQueue.main.async {
            if flags.contains(.beginConfigurationFlag) {
                inFlightCount += 1
                aslog("MenuBarResetGate: CG begin → inFlight=\(inFlightCount)")
                flushWorkItem?.cancel()
                flushWorkItem = nil
            } else {
                inFlightCount = max(0, inFlightCount - 1)
                aslog("MenuBarResetGate: CG end flags=\(String(flags.rawValue, radix: 16)) → inFlight=\(inFlightCount)")
                scheduleFlushIfPossible()
            }
        }
    }

    private static func scheduleFlushIfPossible() {
        guard requestPending, inFlightCount == 0 else { return }
        flushWorkItem?.cancel()
        let work = DispatchWorkItem {
            guard inFlightCount == 0, requestPending else { return }
            performFlush(reason: "quiet-period")
        }
        flushWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + quietPeriod, execute: work)
    }

    private static func armMaxDeferralTimer() {
        maxDeferralWorkItem?.cancel()
        let work = DispatchWorkItem {
            guard requestPending else { return }
            aslog("MenuBarResetGate: max-deferral hit (inFlight=\(inFlightCount)) — forcing flush")
            performFlush(reason: "max-deferral")
        }
        maxDeferralWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + maxDeferral, execute: work)
    }

    private static func performFlush(reason: String) {
        requestPending = false
        flushWorkItem?.cancel()
        flushWorkItem = nil
        maxDeferralWorkItem?.cancel()
        maxDeferralWorkItem = nil
        aslog("MenuBarResetGate: flush (\(reason)) — invoking resetAllMenuBars")
        resetAllMenuBars()
    }

    /// Calls SLSSpaceResetMenuBar on every user space across all
    /// displays. Kill switch: `MenuBarResetDisabled` UserDefault skips
    /// the SLS calls entirely (gate + log still run) for bisecting
    /// whether SLSSpaceResetMenuBar is the trigger for the WindowServer
    /// `SIGABRT` in `iosurface_create_common`.
    private static func resetAllMenuBars() {
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
}
