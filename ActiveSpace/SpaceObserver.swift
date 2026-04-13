import AppKit
import Combine

/// A single ordered Space entry returned by CGSCopyManagedDisplaySpaces.
struct SpaceInfo {
    let managedSpaceID: Int
    let uuid: String
    let displayIdentifier: String
}

/// Tracks the current space index (1-based) and total space count for the user's
/// active display, in visual (Mission Control) order. Fullscreen and tiled
/// spaces (type != 0) are excluded — they aren't part of the left/right cycle.
final class SpaceObserver: ObservableObject {

    @Published private(set) var currentSpaceIndex: Int = 1
    @Published private(set) var totalSpaces: Int = 1

    /// All spaces on the active display, in visual order.
    private(set) var orderedSpaces: [SpaceInfo] = []

    private var cancellables = Set<AnyCancellable>()
    private var pollTimer: Timer?

    init() {
        refresh()

        // Fires when you switch between spaces.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        // Fires when Mission Control adds/removes a space (display config change).
        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        // Backstop poll — catches any edge case where neither notification fires.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit { pollTimer?.invalidate() }

    // MARK: - Refresh

    func refresh() {
        let conn = CGSMainConnectionID()
        guard let raw = CGSCopyManagedDisplaySpaces(conn) as? [[String: Any]] else { return }

        // Pick the display the user is currently on — the one whose "Current
        // Space" is a user space (type 0). Fall back to the first display if
        // nothing matches.
        var chosen: [String: Any]?
        for display in raw {
            if chosen == nil { chosen = display }
            if let current = display["Current Space"] as? [String: Any],
               let type = current["type"] as? Int, type == 0 {
                chosen = display
                break
            }
        }
        guard let chosen else { return }

        // Second pass: build the ordered list of user spaces on that display only.
        var spaces: [SpaceInfo] = []
        let displayID = chosen["Display Identifier"] as? String ?? ""
        if let raw = chosen["Spaces"] as? [[String: Any]] {
            for space in raw {
                let type = space["type"] as? Int ?? 0
                guard type == 0 else { continue }   // skip fullscreen / tiled
                if let id = space["ManagedSpaceID"] as? Int,
                   let uuid = space["uuid"] as? String {
                    spaces.append(SpaceInfo(managedSpaceID: id, uuid: uuid,
                                            displayIdentifier: displayID))
                }
            }
        }

        // Sort into visual (Mission Control) order. CGS sometimes returns spaces
        // in creation order rather than visual position; the spaces preferences
        // plist is the authoritative source for the on-screen layout.
        let spaceUUIDs = Set(spaces.map(\.uuid))
        let visualOrder = Self.readVisualOrder(matchingSpaceUUIDs: spaceUUIDs)
        if !visualOrder.isEmpty {
            spaces.sort {
                let a = visualOrder[$0.uuid] ?? Int.max
                let b = visualOrder[$1.uuid] ?? Int.max
                return a < b
            }
        }

        let currentID = (chosen["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int

        orderedSpaces = spaces
        totalSpaces = max(1, spaces.count)

        if let id = currentID,
           let idx = spaces.firstIndex(where: { $0.managedSpaceID == id }) {
            currentSpaceIndex = idx + 1   // 1-based
        } else {
            currentSpaceIndex = 1
        }
    }

    // MARK: - Visual order (from spaces preferences plist)

    /// Returns a map of space UUID → visual position (0-based) for the monitor
    /// whose Spaces array contains the given UUIDs. Identifies the right monitor
    /// by space-UUID content (which is globally unique) rather than by Display
    /// Identifier, because CGS and the plist sometimes encode display IDs
    /// differently on multi-monitor setups.
    private static func readVisualOrder(matchingSpaceUUIDs uuids: Set<String>) -> [String: Int] {
        let path = ("~/Library/Preferences/com.apple.spaces.plist" as NSString).expandingTildeInPath
        guard let plist = NSDictionary(contentsOfFile: path) as? [String: Any],
              let config = plist["SpacesDisplayConfiguration"] as? [String: Any],
              let mgmt = config["Management Data"] as? [String: Any],
              let monitors = mgmt["Monitors"] as? [[String: Any]] else { return [:] }

        // Find the monitor with the most overlap against the UUIDs we care about.
        var bestMonitorSpaces: [[String: Any]]?
        var bestOverlap = 0
        for monitor in monitors {
            guard let spaces = monitor["Spaces"] as? [[String: Any]] else { continue }
            let monitorUUIDs = Set(spaces.compactMap { $0["uuid"] as? String })
            let overlap = monitorUUIDs.intersection(uuids).count
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestMonitorSpaces = spaces
            }
        }

        guard let visualSpaces = bestMonitorSpaces else { return [:] }

        var positions: [String: Int] = [:]
        var visualIndex = 0
        for space in visualSpaces {
            let type = space["type"] as? Int ?? 0
            guard type == 0 else { continue }   // skip fullscreen / tiled
            if let uuid = space["uuid"] as? String {
                positions[uuid] = visualIndex
                visualIndex += 1
            }
        }
        return positions
    }

    /// Returns the SpaceInfo for a 1-based space index.
    func spaceInfo(forIndex index: Int) -> SpaceInfo? {
        guard index >= 1, index <= orderedSpaces.count else { return nil }
        return orderedSpaces[index - 1]
    }

    /// Returns the ManagedSpaceID for a 1-based space index, or nil if out of range.
    func managedSpaceID(forIndex index: Int) -> Int? {
        spaceInfo(forIndex: index)?.managedSpaceID
    }
}
