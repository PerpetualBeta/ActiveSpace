import SwiftUI

@main
struct ActiveSpaceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No windows — menu bar only. Settings scene kept empty so @main compiles.
        Settings { EmptyView() }
    }
}
