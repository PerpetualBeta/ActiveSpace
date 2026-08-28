import AppKit

/// Housekeeping for the application menu — the first menu in the menu bar, the
/// one AppKit and SwiftUI populate on the app's behalf.
enum JorvikApplicationMenu {

    /// Removes redundant separators: one that opens the menu, one that closes it,
    /// and one that sits directly below another.
    ///
    /// A menu-bar app declares `Settings { EmptyView() }` only because SwiftUI's
    /// `App` must vend at least one scene — the Settings window the user sees is
    /// opened imperatively from the status-item menu. That scene also brings the
    /// standard "Settings…" item and its Command+, shortcut, and both open the
    /// empty placeholder as a second Settings window, so the app drops them with
    /// `CommandGroup(replacing: .appSettings) { }`. Dropping the item leaves its
    /// separator behind, doubled up with the one below it, and AppKit draws both
    /// rules. Call this from `applicationDidFinishLaunching` to take the spare
    /// one out.
    @MainActor
    static func removeRedundantSeparators() {
        // SwiftUI populates the menu after the launch callback returns, so wait
        // for the next pass of the run loop before reading it.
        DispatchQueue.main.async {
            guard let appMenu = NSApp.mainMenu?.item(at: 0)?.submenu else { return }

            var index = appMenu.numberOfItems - 1
            while index >= 0 {
                defer { index -= 1 }
                guard appMenu.items[index].isSeparatorItem else { continue }
                let opensMenu = index == 0
                let closesMenu = index == appMenu.numberOfItems - 1
                let followsSeparator = index > 0 && appMenu.items[index - 1].isSeparatorItem
                if opensMenu || closesMenu || followsSeparator {
                    appMenu.removeItem(at: index)
                }
            }
        }
    }
}
