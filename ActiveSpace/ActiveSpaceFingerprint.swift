import AppKit

/// One display's presence in a fingerprint — stable across attach cycles via
/// its UUID (the CGDirectDisplayID churns when a display is re-attached).
struct DisplayInfo: Equatable {
    let displayID: CGDirectDisplayID
    let uuid: String
    let origin: CGPoint
    let size: CGSize
    let isMain: Bool
}

/// A combined display + Spaces snapshot. Diffing two fingerprints yields the
/// restart-trigger classification used by RestartCoordinator.
struct ActiveSpaceFingerprint: Equatable, CustomStringConvertible {

    // Display layer
    let mainDisplayID: CGDirectDisplayID
    let mainBounds: CGRect
    let displays: [DisplayInfo]              // sorted by uuid — stable comparison

    // Spaces layer — flat ordered list of type-0 (user) space UUIDs across
    // all monitors, in plist visual order. Catches set changes and reorders
    // without needing to solve the CGS-vs-plist display-id matching problem.
    let allSpaceUUIDsOrdered: [String]
    let activeSpaceUUID: String?

    // MARK: - Absolute triggers
    //
    // Evaluated against the current state alone, no diff needed. `dock-on-virtual`
    // manifests almost entirely at startup (macOS transiently routes main/Dock
    // to ActiveSpace's 640×480 virtual), so must fire from t=0 without a grace
    // window.

    /// Main display's size is ≤ 1024 × 768 — heuristic for "main has been
    /// re-elected onto the 640×480 virtual display". No real monitor is that
    /// small, so a small main is almost certainly the virtual one.
    var mainIsSmall: Bool { mainBounds.width <= 1024 && mainBounds.height <= 768 }

    // MARK: - Capture

    static func current() -> ActiveSpaceFingerprint {
        let mainID = CGMainDisplayID()
        let mainBounds = CGDisplayBounds(mainID)

        var displays: [DisplayInfo] = []
        for screen in NSScreen.screens {
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let cgID = CGDirectDisplayID(n.uint32Value)
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(cgID)?.takeRetainedValue(),
                  let uuidStr = CFUUIDCreateString(nil, uuid) as String? else { continue }
            let bounds = CGDisplayBounds(cgID)
            displays.append(DisplayInfo(
                displayID: cgID,
                uuid: uuidStr,
                origin: bounds.origin,
                size: bounds.size,
                isMain: cgID == mainID
            ))
        }
        displays.sort { $0.uuid < $1.uuid }

        let (ordered, active) = SpacesPlist.captureCurrent()

        return ActiveSpaceFingerprint(
            mainDisplayID: mainID,
            mainBounds: mainBounds,
            displays: displays,
            allSpaceUUIDsOrdered: ordered,
            activeSpaceUUID: active
        )
    }

    // MARK: - Description

    var description: String {
        let screensDesc = displays.map { d -> String in
            let tag = d.isMain ? " MAIN" : ""
            return "id=\(d.displayID) (\(Int(d.origin.x)),\(Int(d.origin.y))) \(Int(d.size.width))x\(Int(d.size.height))\(tag)"
        }.joined(separator: " | ")
        let spacesDesc = allSpaceUUIDsOrdered.map { uuid -> String in
            let short = String(uuid.prefix(8))
            let marker = (uuid == activeSpaceUUID) ? "*" : ""
            return "\(short)\(marker)"
        }.joined(separator: ",")
        // `displays` is sourced from NSScreen.screens, which collapses mirror
        // sets to a single entry. Surface the underlying active-display count
        // and any mirror relationships so the log reveals mirror state at a
        // glance (NSScreen=1 + active=2 + mirror master/slave both listed →
        // user is mirroring two externals). Diagnostic only — the underlying
        // `displays` field is unchanged so drift-detection still keys off the
        // AppKit-visible state.
        return "displays=\(displays.count) main=\(mainDisplayID) mainOrigin=(\(Int(mainBounds.origin.x)),\(Int(mainBounds.origin.y))) mainSize=\(Int(mainBounds.width))x\(Int(mainBounds.height)) screens=[\(screensDesc)] mirrors=[\(Self.mirrorSummary())] spaces=[\(spacesDesc)]"
    }

    /// Summary of active displays + mirror relationships. Empty string when
    /// there are no mirror slaves (the common case). Format example:
    /// `active=2 slaves=[id=7→2]` — display 7 is slaved to (mirroring) 2.
    private static func mirrorSummary() -> String {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success,
              displayCount > 0 else { return "active=0" }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &ids, &displayCount) == .success else {
            return "active=?"
        }
        let active = ids.prefix(Int(displayCount))
        let slaves = active.compactMap { id -> String? in
            let mirrored = CGDisplayMirrorsDisplay(id)
            guard mirrored != 0 else { return nil }   // not a mirror slave
            return "id=\(id)→\(mirrored)"
        }
        if slaves.isEmpty { return "active=\(displayCount)" }
        return "active=\(displayCount) slaves=[\(slaves.joined(separator: ", "))]"
    }
}
