import AppKit
import ApplicationServices

/// Enumerates regular apps with at least one visible window on the current
/// Mission Control space. Lifted from SpaceMan's WindowCapture pattern:
/// CG on-screen list scopes to the current space; AX walk per-app surfaces
/// the windows; `_AXUIElementGetWindow` cross-references the two.
final class SwitcherAppResolver {

    struct Entry {
        let app: NSRunningApplication
        let bundleID: String
        let appName: String
        let icon: NSImage
        let frontWindowTitle: String
    }

    func currentSpaceApps(orderedBy stack: SwitcherAppStack) -> [Entry] {
        guard AXIsProcessTrusted() else { return [] }

        let listOpts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let cgList = (CGWindowListCopyWindowInfo(listOpts, kCGNullWindowID) as? [[String: Any]]) ?? []

        var onScreenIDs = Set<CGWindowID>()
        var cgTitleByID: [CGWindowID: String] = [:]
        for entry in cgList {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let id = entry[kCGWindowNumber as String] as? CGWindowID else { continue }
            onScreenIDs.insert(id)
            if let title = entry[kCGWindowName as String] as? String, !title.isEmpty {
                cgTitleByID[id] = title
            }
        }

        var entries: [Entry] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let pid = app.processIdentifier
            let axWindows = axWindowList(for: pid)
            let onSpace = axWindows.filter { isOnCurrentSpace($0, onScreenIDs: onScreenIDs) }
            guard !onSpace.isEmpty else { continue }

            let bundleID = app.bundleIdentifier ?? "unknown.\(pid)"
            let name = app.localizedName ?? bundleID
            let icon = app.icon ?? NSImage(size: NSSize(width: 1, height: 1))
            let title = frontWindowTitle(onSpace: onSpace, cgTitleByID: cgTitleByID)

            entries.append(Entry(app: app, bundleID: bundleID, appName: name,
                                 icon: icon, frontWindowTitle: title))
        }

        let candidates = entries.map { CandidateApp(bundleID: $0.bundleID, localizedName: $0.appName) }
        let orderedIDs = stack.orderedBundleIDs(candidates: candidates)
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.bundleID, $0) })
        return orderedIDs.compactMap { byID[$0] }
    }

    // MARK: - Helpers

    private func axWindowList(for pid: pid_t) -> [AXUIElement] {
        let appEl = AXUIElementCreateApplication(pid)
        var value: AnyObject?
        let rc = AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &value)
        guard rc == .success, let arr = value as? [AXUIElement] else { return [] }
        return arr
    }

    private func isOnCurrentSpace(_ element: AXUIElement, onScreenIDs: Set<CGWindowID>) -> Bool {
        var windowID: CGWindowID = 0
        guard _AXUIElementGetWindow(element, &windowID) == .success else { return false }
        return onScreenIDs.contains(windowID)
    }

    private func frontWindowTitle(onSpace axWindows: [AXUIElement],
                                  cgTitleByID: [CGWindowID: String]) -> String {
        for win in axWindows {
            var ref: AnyObject?
            if AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &ref) == .success,
               let title = ref as? String, !title.isEmpty {
                return title
            }
            var windowID: CGWindowID = 0
            if _AXUIElementGetWindow(win, &windowID) == .success,
               let title = cgTitleByID[windowID], !title.isEmpty {
                return title
            }
        }
        return ""
    }
}
