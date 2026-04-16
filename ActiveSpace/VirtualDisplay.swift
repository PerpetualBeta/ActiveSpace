import AppKit
import CoreGraphics

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

    /// The physical display count at the time we last ran reconcile.
    /// Used to distinguish real config changes (plug/unplug) from
    /// notifications triggered by our own virtual display creation.
    private static var lastPhysicalCount = -1

    /// Call once at app launch. Creates the virtual display if there's only one
    /// physical display, and installs an observer so it's added/removed as the
    /// user's display configuration changes.
    static func startManaging() {
        reconcile()

        // Observe screen configuration changes (plug/unplug, lid open/close).
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            let currentPhysical = physicalDisplayCount()
            if currentPhysical == lastPhysicalCount {
                aslog("VirtualDisplay: config notification but physical count unchanged (\(currentPhysical)) — ignoring")
                return
            }
            aslog("VirtualDisplay: physical count changed \(lastPhysicalCount) → \(currentPhysical)")
            reconcile()
        }
    }

    /// CFUUID-string identifier of the virtual display, or nil if not created.
    static var uuidString: String? {
        VirtualDisplayHelper.displayUUIDString()
    }

    // MARK: - Private

    /// Match the virtual display's presence to whether it's currently needed.
    /// When the physical display count changes while a virtual display is
    /// already active, relaunch the app so it starts clean against the new
    /// display layout rather than trying to patch state in-place.
    private static func reconcile() {
        let realCount = physicalDisplayCount()
        let haveVirtual = VirtualDisplayHelper.isCreated()
        let needVirtual = realCount <= 1

        lastPhysicalCount = realCount

        aslog("VirtualDisplay.reconcile: real=\(realCount) haveVirtual=\(haveVirtual) needVirtual=\(needVirtual)")

        if needVirtual && !haveVirtual {
            _ = VirtualDisplayHelper.create()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                Self.resetAllMenuBars()
            }
        } else if !needVirtual && haveVirtual {
            VirtualDisplayHelper.destroy()
        }
        // needVirtual && haveVirtual: no action needed — the observer
        // only calls reconcile when the physical count actually changed,
        // and a real change (e.g. undock → still single display) triggers
        // a relaunch via the observer guard above. This path is only
        // reached from startManaging() on a fresh launch where the
        // virtual display already exists (shouldn't happen in practice).
    }

    /// Relaunch the app by spawning a new instance and terminating this one.
    static func relaunch() {
        guard let bundleURL = Bundle.main.bundleURL as URL? else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
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
