import SwiftUI

@main
struct ActiveSpaceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // This scene exists only because App requires one — the Settings window
        // the user sees is opened from the status-item menu, imperatively, by
        // JorvikSettingsView.showWindow. A Settings scene also brings the
        // standard "Settings…" item and its Command+, shortcut, and both opened
        // this empty placeholder as a second Settings window. Replacing the
        // command group removes the item and the shortcut with it; removing the
        // menu item on its own does not, the shortcut still reaches the scene.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) { }
            }
    }
}
