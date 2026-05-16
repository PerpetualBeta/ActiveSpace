import AppKit
import ApplicationServices

/// Toggle "follow across spaces" on the frontmost app. When on,
/// `SLSProcessAssignToAllSpaces(conn, pid)` is invoked — exactly the
/// call the Dock's right-click "Options → Assign To → All Desktops"
/// menu makes — so every window owned by the app appears on every
/// Mission Control user space. When off, `SLSProcessAssignToSpace`
/// pins the app back to whichever space the user was on when they
/// first toggled it.
///
/// **Per-app, not per-window.** This was originally written as a
/// per-window API on top of `SLSAddWindowsToSpaces`, but that call is
/// a no-op on macOS 14.5+ (returns success but the window's space
/// membership stays unchanged — empirically verified 2026-05-16). The
/// per-process API still works because Apple keeps the Dock's menu
/// option functional. Matches the user's "app-by-app basis" framing:
/// the hotkey is triggered against the focused window, but the effect
/// extends to all of that app's windows.
///
/// State is session-only — held in an in-memory `[pid_t: UInt64]` map
/// of (process → original space ManagedSpaceID). PIDs aren't stable
/// across reboots and toggle state is uninteresting across launches
/// anyway, so persistence would add fragility without continuity.
///
/// Feedback fires through `FollowHUD.show(...)` in both directions.
enum WindowFollow {

    /// Maps a followed process to the user space it was on when first
    /// toggled. Entries are cleared when the user toggles the same app
    /// off. Stale entries (process quit) are harmless: the next call
    /// to `SLSProcessAssignToSpace` for a dead PID returns an error
    /// we ignore, and the entry is removed when the user toggles a
    /// different app.
    private static var followed: [pid_t: UInt64] = [:]

    static func toggle() {
        dispatchPrecondition(condition: .onQueue(.main))

        guard let app = NSWorkspace.shared.frontmostApplication else {
            aslog("WindowFollow.toggle: no frontmost app")
            FollowHUD.show(text: "No frontmost app", subtext: nil)
            return
        }
        let appName = app.localizedName ?? "Unknown"
        let pid = app.processIdentifier

        // Read the focused window's title for HUD identification — purely
        // cosmetic, helps the user confirm which app they're toggling.
        let windowTitle = focusedWindowTitle(pid: pid) ?? ""

        let conn = CGSMainConnectionID()

        if let originalSpace = followed[pid] {
            // Toggle OFF: pin process back to the originally-recorded space.
            let rc = SLSProcessAssignToSpace(conn, pid, originalSpace)
            followed.removeValue(forKey: pid)
            aslog("WindowFollow.toggle OFF: \(appName) pid=\(pid) rc=\(rc) → space \(originalSpace)")
            FollowHUD.show(text: "No longer following", subtext: hudSubtitle(app: appName, title: windowTitle))
        } else {
            // Toggle ON: record current space, assign process to all spaces.
            let currentSpace = currentManagedSpaceID()
            if currentSpace == 0 {
                aslog("WindowFollow.toggle: current space is non-user (fullscreen/tiled); refusing to follow")
                FollowHUD.show(text: "Can't follow from a full-screen space", subtext: nil)
                return
            }
            let rc = SLSProcessAssignToAllSpaces(conn, pid)
            followed[pid] = currentSpace
            aslog("WindowFollow.toggle ON: \(appName) pid=\(pid) rc=\(rc) original-space=\(currentSpace)")
            FollowHUD.show(text: "Following across spaces", subtext: hudSubtitle(app: appName, title: windowTitle))
        }
    }

    /// Best-effort read of the frontmost focused window's title via AX,
    /// used only for HUD display. Returns nil if AX isn't granted,
    /// there's no focused window, or the title is unreadable.
    private static func focusedWindowTitle(pid: pid_t) -> String? {
        let appEl = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
              let focusedRef else { return nil }
        let focused = focusedRef as! AXUIElement
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXTitleAttribute as CFString, &titleRef) == .success,
              let s = titleRef as? String, !s.isEmpty else { return nil }
        return s
    }

    private static func hudSubtitle(app: String, title: String) -> String {
        if title.isEmpty { return app }
        let trimmedTitle = title.count > 60 ? String(title.prefix(57)) + "…" : title
        return "\(app) — \(trimmedTitle)"
    }
}

// MARK: - Toast HUD

/// Brief borderless pill that appears at the bottom-centre of the active
/// screen and auto-dismisses after ~1.4s. Single-instance — a fresh
/// `show()` cancels any pending dismiss and replaces the previous toast.
/// Modelled on Rainy Day / CopyLens's HUD pattern; doesn't try to be
/// generic — `WindowFollow` is the only caller.
enum FollowHUD {

    private static var current: NSPanel?
    private static var dismissWorkItem: DispatchWorkItem?

    static func show(text: String, subtext: String?) {
        dispatchPrecondition(condition: .onQueue(.main))

        dismissWorkItem?.cancel()
        current?.orderOut(nil)
        current = nil

        guard let screen = NSScreen.main else { return }

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textColor = .white
        label.alignment = .center

        let sub: NSTextField? = subtext.map { s in
            let f = NSTextField(labelWithString: s)
            f.font = .systemFont(ofSize: 12, weight: .regular)
            f.textColor = NSColor.white.withAlphaComponent(0.75)
            f.alignment = .center
            return f
        }

        let stack = NSStackView(views: [label] + (sub.map { [$0] } ?? []))
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 22, bottom: 14, right: 22)

        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor(white: 0, alpha: 0.78).cgColor
        pill.layer?.cornerRadius = 14
        pill.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
            stack.topAnchor.constraint(equalTo: pill.topAnchor),
            stack.bottomAnchor.constraint(equalTo: pill.bottomAnchor),
        ])

        pill.layoutSubtreeIfNeeded()
        let fitted = stack.fittingSize
        let size = NSSize(width: fitted.width, height: fitted.height)
        let origin = NSPoint(x: screen.frame.midX - size.width / 2,
                             y: screen.frame.minY + 120)

        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        // Stick the HUD itself to all spaces so the toggle-on confirmation
        // is visible after the user immediately swipes to another space —
        // a small bit of self-eating dogfood (`NSWindow.canJoinAllSpaces`
        // does exactly what we're inflicting on third-party windows).
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.contentView = pill
        panel.orderFrontRegardless()
        current = panel

        let dismiss = DispatchWorkItem {
            current?.orderOut(nil)
            current = nil
            dismissWorkItem = nil
        }
        dismissWorkItem = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: dismiss)
    }
}
