import AppKit

/// Switches Mission Control spaces using NSAppleScript (in-process).
/// Runs in the app's own TCC context, so the Accessibility + Automation
/// permissions already granted to the signed app apply directly.
enum SpaceSwitcher {

    static func switchTo(index: Int, observer: SpaceObserver) {
        let steps = index - observer.currentSpaceIndex
        guard steps != 0 else { return }

        let keyCode = steps > 0 ? 124 : 123   // Right Arrow / Left Arrow
        let count   = abs(steps)

        var lines = ["tell application \"System Events\""]
        for i in 0..<count {
            lines.append("    key code \(keyCode) using {control down}")
            if i < count - 1 { lines.append("    delay 0.35") }
        }
        lines.append("end tell")

        // NSAppleScript must run on the main thread.
        // The call is fast (single keystroke), so a brief block is fine.
        DispatchQueue.main.async {
            var error: NSDictionary?
            let script = NSAppleScript(source: lines.joined(separator: "\n"))
            script?.executeAndReturnError(&error)
            if let err = error {
                NSLog("ActiveSpace: AppleScript error: %@", err)
            }
        }
    }

    static func toggle(observer: SpaceObserver) {
        let next = observer.currentSpaceIndex == 1 ? 2 : 1
        switchTo(index: next, observer: observer)
    }
}
