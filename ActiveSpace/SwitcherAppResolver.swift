import AppKit
import ApplicationServices

/// Enumerates regular apps with at least one window on the current Mission
/// Control space — including **minimised windows** and **hidden-app windows**.
///
/// v2 (2026-04-17): uses `SLSCopySpacesForWindows` (SkyLight private API) for
/// strict per-window space membership. Supersedes the v1 CG-on-screen filter
/// which silently dropped minimised windows and hidden apps.
///
/// Algorithm per app:
///   1. AX-walk its windows (all spaces, all states).
///   2. Resolve each AXUIElement to a CG window ID via `_AXUIElementGetWindow`.
///   3. Phase 1 — batch SLS call with the app's full window set; union check
///      against `currentSpaceID` to cull apps with nothing on this space.
///   4. Phase 2 — per-window SLS call to filter to just the windows on this
///      space; capture minimised state + AX title for each.
///   5. If any windows remain, emit an Entry. `minimisableWindow` is set iff
///      *every* window on this space is minimised — commit will then
///      unminimise one before activating so the app actually surfaces.
final class SwitcherAppResolver {

    struct Entry {
        let app: NSRunningApplication
        let bundleID: String
        let appName: String
        let icon: NSImage
        let frontWindowTitle: String
        /// Non-nil iff every window this app has on the current space is
        /// minimised. Controller unminimises this one before activating.
        let minimisableWindow: AXUIElement?
        /// App-level `NSRunningApplication.isHidden` at enumeration time.
        let appHidden: Bool
    }

    func currentSpaceApps(orderedBy stack: SwitcherAppStack) -> [Entry] {
        guard AXIsProcessTrusted() else { return [] }
        let currentSpace = currentManagedSpaceID()
        guard currentSpace != 0 else { return [] }
        let conn = CGSMainConnectionID()

        var entries: [Entry] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let pid = app.processIdentifier
            let axWindows = axWindowList(for: pid)
            guard !axWindows.isEmpty else { continue }

            var axToCG: [(ax: AXUIElement, cg: CGWindowID)] = []
            for ax in axWindows {
                var cg: CGWindowID = 0
                if _AXUIElementGetWindow(ax, &cg) == .success {
                    axToCG.append((ax, cg))
                }
            }
            guard !axToCG.isEmpty else { continue }

            // Phase 1 — cheap union check against app's full window set.
            let unionArray = axToCG.map { NSNumber(value: $0.cg) } as CFArray
            let unionSpaces = Set(SLSCopySpacesForWindows(conn, 0x7, unionArray)
                                    .map { $0.uint64Value })
            guard unionSpaces.contains(currentSpace) else { continue }

            // Phase 2 — per-window SLS to isolate windows actually on this space.
            var windowsOnSpace: [(ax: AXUIElement, minimised: Bool, title: String)] = []
            for pair in axToCG {
                let single = [NSNumber(value: pair.cg)] as CFArray
                let spaces = SLSCopySpacesForWindows(conn, 0x7, single)
                guard spaces.contains(where: { $0.uint64Value == currentSpace }) else { continue }
                windowsOnSpace.append((pair.ax, axIsMinimised(pair.ax), axTitle(pair.ax)))
            }
            guard !windowsOnSpace.isEmpty else { continue }

            let bundleID = app.bundleIdentifier ?? "unknown.\(pid)"
            let name = app.localizedName ?? bundleID
            let icon = app.icon ?? NSImage(size: NSSize(width: 1, height: 1))
            let title = windowsOnSpace
                .first(where: { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
                .title ?? ""
            let allMinimised = windowsOnSpace.allSatisfy { $0.minimised }
            let minimisableWin = allMinimised ? windowsOnSpace.first?.ax : nil

            entries.append(Entry(
                app: app,
                bundleID: bundleID,
                appName: name,
                icon: icon,
                frontWindowTitle: title,
                minimisableWindow: minimisableWin,
                appHidden: app.isHidden
            ))
        }

        let candidates = entries.map { CandidateApp(bundleID: $0.bundleID, localizedName: $0.appName) }
        let orderedIDs = stack.orderedBundleIDs(candidates: candidates)
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.bundleID, $0) })
        return orderedIDs.compactMap { byID[$0] }
    }

    // MARK: - AX helpers

    private func axWindowList(for pid: pid_t) -> [AXUIElement] {
        let appEl = AXUIElementCreateApplication(pid)
        var value: AnyObject?
        let rc = AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &value)
        guard rc == .success, let arr = value as? [AXUIElement] else { return [] }
        return arr
    }

    private func axIsMinimised(_ window: AXUIElement) -> Bool {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &ref) == .success,
              let flag = ref as? Bool else { return false }
        return flag
    }

    private func axTitle(_ window: AXUIElement) -> String {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &ref) == .success else { return "" }
        if let s = ref as? String { return s }
        if let a = ref as? NSAttributedString { return a.string }
        return ""
    }
}
