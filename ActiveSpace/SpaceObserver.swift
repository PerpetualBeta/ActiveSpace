import AppKit
import Combine

/// A single ordered Space entry returned by CGSCopyManagedDisplaySpaces.
struct SpaceInfo {
    let managedSpaceID: Int
    let uuid: String
    let displayIdentifier: String   // needed by CGSManagedDisplaySetCurrentSpace
}

/// Tracks the current space index (1-based) and total space count across all displays.
/// Updates on active-space changes, screen-parameter changes, and a 2-second poll
/// (the poll catches add/remove in Mission Control that don't fire a notification).
final class SpaceObserver: ObservableObject {

    @Published private(set) var currentSpaceIndex: Int = 1
    @Published private(set) var totalSpaces: Int = 1

    /// All spaces in order (aggregated across all displays).
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

        var all: [SpaceInfo] = []
        var currentID: Int?

        for display in raw {
            let displayID = display["Display Identifier"] as? String ?? ""

            if let spaces = display["Spaces"] as? [[String: Any]] {
                for space in spaces {
                    if let id = space["ManagedSpaceID"] as? Int,
                       let uuid = space["uuid"] as? String {
                        all.append(SpaceInfo(managedSpaceID: id, uuid: uuid,
                                             displayIdentifier: displayID))
                    }
                }
            }

            if let current = display["Current Space"] as? [String: Any],
               let id = current["ManagedSpaceID"] as? Int {
                currentID = id
            }
        }

        orderedSpaces = all
        totalSpaces = all.count

        if let id = currentID,
           let idx = all.firstIndex(where: { $0.managedSpaceID == id }) {
            currentSpaceIndex = idx + 1   // 1-based
        }
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
