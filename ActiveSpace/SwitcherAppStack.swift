import AppKit
import Combine

/// Per-space MRU (most-recently-used) bundleID stack. Observes
/// `NSWorkspace.didActivateApplicationNotification` and tags each activation
/// with the current Mission Control space ID at fire-time.
///
/// v1: in-memory only. Resets on ActiveSpace relaunch (rebuilds organically
/// within seconds of normal use).
struct CandidateApp {
    let bundleID: String
    let localizedName: String
}

final class SwitcherAppStack {

    private struct Bucket {
        var entries: [String] = []
        mutating func touch(_ bundleID: String) {
            entries.removeAll { $0 == bundleID }
            entries.insert(bundleID, at: 0)
        }
    }

    private var buckets: [UInt64: Bucket] = [:]
    private var cancellables = Set<AnyCancellable>()
    private static let ownBundleID = Bundle.main.bundleIdentifier ?? ""

    init() {
        // Seed with the current frontmost app so slot 0 is meaningful on the
        // first switcher invocation after launch.
        if let front = NSWorkspace.shared.frontmostApplication,
           let bid = front.bundleIdentifier,
           bid != Self.ownBundleID {
            noteActivation(bundleID: bid, onSpace: Self.currentSpaceID())
        }

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] note in self?.handleActivation(note) }
            .store(in: &cancellables)
    }

    /// Returns candidates ordered [frontmost-on-this-space, previous, earlier…]
    /// followed by alphabetically-sorted unseen candidates. Stack entries not
    /// in `candidates` are dropped silently.
    func orderedBundleIDs(candidates: [CandidateApp]) -> [String] {
        let spaceID = Self.currentSpaceID()
        let candidateIDs = Set(candidates.map(\.bundleID))
        let mru = (buckets[spaceID]?.entries ?? []).filter(candidateIDs.contains)
        let seen = Set(mru)
        let unseen = candidates
            .filter { !seen.contains($0.bundleID) }
            .sorted { $0.localizedName.localizedCaseInsensitiveCompare($1.localizedName) == .orderedAscending }
            .map(\.bundleID)
        aslog("SwitcherAppStack: query space=\(spaceID) candidates=\(candidates.count) mru=\(mru.count) unseen=\(unseen.count)")
        return mru + unseen
    }

    func noteActivation(bundleID: String, onSpace spaceID: UInt64) {
        buckets[spaceID, default: Bucket()].touch(bundleID)
    }

    func forgetSpace(_ spaceID: UInt64) {
        if buckets.removeValue(forKey: spaceID) != nil {
            aslog("SwitcherAppStack: forgetSpace \(spaceID)")
        }
    }

    // MARK: - Observation

    private func handleActivation(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier,
              bundleID != Self.ownBundleID
        else { return }
        let spaceID = Self.currentSpaceID()
        noteActivation(bundleID: bundleID, onSpace: spaceID)
        aslog("SwitcherAppStack: activation bundleID=\(bundleID) space=\(spaceID)")
    }

    /// Reads the current user space's ManagedSpaceID via CGS. Returns 0 on
    /// fullscreen/tiled spaces (type != 0) — those activations land in an
    /// inert bucket and are never queried.
    private static func currentSpaceID() -> UInt64 {
        let conn = CGSMainConnectionID()
        guard let raw = CGSCopyManagedDisplaySpaces(conn) as? [[String: Any]] else { return 0 }
        for display in raw {
            guard let current = display["Current Space"] as? [String: Any],
                  let type = current["type"] as? Int, type == 0,
                  let id = current["ManagedSpaceID"] as? Int
            else { continue }
            return UInt64(id)
        }
        return 0
    }
}
