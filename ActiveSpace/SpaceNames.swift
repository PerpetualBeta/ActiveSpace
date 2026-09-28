import Foundation
import Combine

/// The names the user has given their spaces, and where to show them.
///
/// A name is stored against the space's UUID, never its position. macOS
/// reorders spaces on its own (after a screensaver wake, see DriftMonitor), and
/// a name stored as "space 3" would then sit on the wrong desktop. The UUID is
/// what SkyLight itself calls the space's name (`SLSSpaceCopyName` returned
/// the UUID for every space, measured 2026-09-28), and it was measured to
/// survive a reboot: the same eight UUIDs, in the same
/// order, were logged on 2026-09-15 and again after the 2026-09-25 restart.
///
/// Names live in ActiveSpace's own defaults. Nothing here writes to
/// com.apple.spaces.plist or asks SkyLight to rename a space: SkyLight's
/// "name" IS that UUID, so changing it would cut every link macOS keeps to the
/// space, app bindings included.
final class SpaceNames: ObservableObject {

    static let shared = SpaceNames()

    private static let namesKey = "spaceNames"
    private static let menuBarKey = "showSpaceNameInMenuBar"
    private static let missionControlKey = "showSpaceNamesInMissionControl"

    /// UUID → name. A name whose space has gone is kept, not pruned: a display
    /// change can take a space away and bring the same UUID back. Settings lists
    /// those as not present, with a Remove button.
    @Published private(set) var names: [String: String]

    /// Both off by default, so an existing user sees nothing change until they
    /// opt in.
    @Published var showInMenuBar: Bool {
        didSet { UserDefaults.standard.set(showInMenuBar, forKey: Self.menuBarKey) }
    }
    @Published var showInMissionControl: Bool {
        didSet { UserDefaults.standard.set(showInMissionControl, forKey: Self.missionControlKey) }
    }

    private init() {
        let d = UserDefaults.standard
        names = d.dictionary(forKey: Self.namesKey) as? [String: String] ?? [:]
        showInMenuBar = d.bool(forKey: Self.menuBarKey)
        showInMissionControl = d.bool(forKey: Self.missionControlKey)
    }

    /// Whether any saved name says something the automatic label does not.
    /// A name that is empty, only whitespace, or just "Space 3" / "Desktop 3"
    /// (any number, any case) does not count, so someone who has typed nothing
    /// real sees ActiveSpace exactly as before. setName already drops empty
    /// names; the check repeats it for values written with `defaults`.
    var hasMeaningfulName: Bool {
        names.values.contains { !Self.isDefaultLabel($0) }
    }

    private static let defaultLabel = /^(space|desktop)\s*\d+$/.ignoresCase()

    private static func isDefaultLabel(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.wholeMatch(of: defaultLabel) != nil
    }

    func name(for uuid: String) -> String? {
        names[uuid]
    }

    /// An empty or all-whitespace name removes the entry, so clearing the field
    /// is how a space goes back to having no name.
    func setName(_ name: String, for uuid: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            names.removeValue(forKey: uuid)
        } else {
            names[uuid] = trimmed
        }
        UserDefaults.standard.set(names, forKey: Self.namesKey)
    }

    func removeName(for uuid: String) {
        setName("", for: uuid)
    }
}
