import AppKit

/// A full-screen blurred overlay shown during multi-step space transitions on
/// multi-display setups. The dock-swipe gesture sequence briefly renders the
/// intermediate space(s) between the start and the target — the "flash" —
/// and we can't suppress that via `CGSDisableUpdate` or by hiding windows.
/// Instead, we cover the flash with an intentional-looking heavy blur that
/// spans all displays and is visible on every space (so it stays on screen as
/// the transition walks through each space).
///
/// The user perceives this as a designed "blur wipe" transition rather than a
/// rendering glitch.
enum TransitionOverlay {

    private static var windows: [NSWindow] = []

    /// Show a blurred overlay that covers every connected display. Idempotent.
    static func show() {
        guard windows.isEmpty else { return }

        let screens = NSScreen.screens
        aslog("TransitionOverlay.show: \(screens.count) screen(s) — \(screens.map { $0.frame })")

        // One window per screen, sized to that screen's frame. Done per-screen
        // rather than as a single union-bounds window because a window whose
        // frame spans a gap between displays ends up with the blur rendering
        // oddly in the gap on some macOS versions.
        for (i, screen) in screens.enumerated() {
            let w = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.level = .screenSaver
            w.collectionBehavior = [
                .canJoinAllSpaces,
                .stationary,
                .ignoresCycle,
                .fullScreenAuxiliary
            ]
            // Make sure the window actually lands on the intended screen — the
            // initializer's screen: argument is a hint that can be overridden
            // when the contentRect doesn't match the target screen exactly.
            w.setFrame(screen.frame, display: false)

            let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: screen.frame.size))
            blur.material = .fullScreenUI
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.autoresizingMask = [.width, .height]

            w.contentView = blur
            w.orderFrontRegardless()
            aslog("TransitionOverlay.show: window[\(i)] frame=\(w.frame) actualScreen=\(w.screen?.frame.origin ?? .zero)")
            windows.append(w)
        }
    }

    /// Tear down the overlay windows.
    static func hide() {
        aslog("TransitionOverlay.hide: \(windows.count) window(s)")
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
    }
}
