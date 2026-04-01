import AppKit

/// Switches Mission Control spaces using AppleScript keystroke injection
/// via System Events. Requires Accessibility permission.
enum SpaceSwitcher {

    /// Prompts for Accessibility permission if not already granted.
    /// Call once at app launch.
    static func ensureAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func switchTo(index: Int, observer: SpaceObserver) {
        let steps = index - observer.currentSpaceIndex
        guard steps != 0 else { return }

        guard AXIsProcessTrusted() else {
            NSLog("ActiveSpace: Accessibility permission not granted, cannot switch spaces")
            ensureAccessibility()
            return
        }

        let keyCode = steps > 0 ? 124 : 123   // Right Arrow / Left Arrow
        let count   = abs(steps)

        var lines = ["tell application \"System Events\""]
        for i in 0..<count {
            lines.append("    key code \(keyCode) using {control down}")
            if i < count - 1 { lines.append("    delay 0.35") }
        }
        lines.append("end tell")

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
