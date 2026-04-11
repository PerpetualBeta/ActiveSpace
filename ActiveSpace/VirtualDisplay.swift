import Foundation
import CoreGraphics

/// Creates and holds a tiny invisible virtual display for the lifetime of the app.
/// On macOS 16, single-monitor configurations use display identifier "Main" which
/// causes the Dock's gesture processing to malfunction. A virtual display forces
/// macOS to use UUID-based identifiers, fixing the issue.
enum VirtualDisplay {

    private static var display: NSObject?

    /// Create the virtual display. Call once at app launch.
    static func create() {
        guard display == nil else { return }
        display = VirtualDisplayHelper.create()
    }
}
