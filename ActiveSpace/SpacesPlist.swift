import Foundation

/// Reads macOS's Spaces state for fingerprinting. Pulls the visual-order list
/// of type-0 (user) space UUIDs from ~/Library/Preferences/com.apple.spaces.plist,
/// and the currently-active space UUID from CGS.
///
/// Kept separate from SpaceObserver so the fingerprint layer doesn't drag in
/// SpaceObserver's Combine/ObservableObject machinery and can be evaluated
/// synchronously as a pure snapshot.
enum SpacesPlist {

    /// Returns (flat ordered list of all user-space UUIDs across all monitors
    /// in plist visual order, currently active space UUID or nil).
    ///
    /// The flat form deliberately dodges the CGS-vs-plist display-id matching
    /// problem — we don't need per-display granularity to detect add/remove
    /// or reorder events. Monitors are concatenated in the plist's own order,
    /// which is stable across reads.
    static func captureCurrent() -> (ordered: [String], active: String?) {
        let ordered = readOrderedUUIDsAcrossAllMonitors()
        let active = readActiveSpaceUUID()
        return (ordered, active)
    }

    private static func readOrderedUUIDsAcrossAllMonitors() -> [String] {
        let path = ("~/Library/Preferences/com.apple.spaces.plist" as NSString).expandingTildeInPath
        guard let plist = NSDictionary(contentsOfFile: path) as? [String: Any],
              let config = plist["SpacesDisplayConfiguration"] as? [String: Any],
              let mgmt = config["Management Data"] as? [String: Any],
              let monitors = mgmt["Monitors"] as? [[String: Any]] else { return [] }

        var out: [String] = []
        for monitor in monitors {
            guard let spaces = monitor["Spaces"] as? [[String: Any]] else { continue }
            for space in spaces {
                let type = space["type"] as? Int ?? 0
                guard type == 0 else { continue }
                if let uuid = space["uuid"] as? String {
                    out.append(uuid)
                }
            }
        }
        return out
    }

    private static func readActiveSpaceUUID() -> String? {
        let conn = CGSMainConnectionID()
        guard let raw = CGSCopyManagedDisplaySpaces(conn) as? [[String: Any]] else { return nil }
        for display in raw {
            if let current = display["Current Space"] as? [String: Any],
               let type = current["type"] as? Int, type == 0,
               let uuid = current["uuid"] as? String {
                return uuid
            }
        }
        return nil
    }
}
