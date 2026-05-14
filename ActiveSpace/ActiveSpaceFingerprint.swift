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
        // sets to a single entry. When a mirror set is actually present we
        // append a `mirror=[...]` segment listing the master and slaves so
        // the log surfaces the cause of any NSScreen-vs-CG mismatch. In the
        // common no-mirror case the segment is omitted entirely — no point
        // adding a "mirrors=" label that misleads when mirroring is off.
        let mirrorSeg = Self.mirrorSegment().map { " \($0)" } ?? ""
        return "displays=\(displays.count) main=\(mainDisplayID) mainOrigin=(\(Int(mainBounds.origin.x)),\(Int(mainBounds.origin.y))) mainSize=\(Int(mainBounds.width))x\(Int(mainBounds.height)) screens=[\(screensDesc)]\(mirrorSeg) spaces=[\(spacesDesc)]"
    }

    /// Returns a `mirror=[id=X MASTER, id=Y→X]`-style segment iff one or more
    /// active displays are part of a mirror set, else nil. Detection uses
    /// `CGDisplayIsInMirrorSet` so we include the master (whose
    /// `CGDisplayMirrorsDisplay` returns 0) as well as the slaves.
    private static func mirrorSegment() -> String? {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success,
              displayCount > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &ids, &displayCount) == .success else {
            return nil
        }
        let active = ids.prefix(Int(displayCount))
        let inMirror = active.filter { CGDisplayIsInMirrorSet($0) != 0 }
        guard !inMirror.isEmpty else { return nil }
        let parts = inMirror.map { id -> String in
            let mirrored = CGDisplayMirrorsDisplay(id)
            return mirrored == 0 ? "id=\(id) MASTER" : "id=\(id)→\(mirrored)"
        }
        return "mirror=[\(parts.joined(separator: ", "))]"
    }
}
