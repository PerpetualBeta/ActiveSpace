import AppKit
import Combine

/// Switches Mission Control spaces by raising an invisible anchor window that
/// already lives in the target space. macOS's native behaviour is to switch
/// to the space containing the focused window of the activated app, so a
/// `[anchor makeKeyAndOrderFront:nil]` after `NSApp.activate(...)` produces a
/// natural-looking switch with no Dock gesture events, no `CGSManagedDisplay
/// SetCurrentSpace` call, and — most importantly — no virtual display.
///
/// Anchors are planted lazily: every time `SpaceObserver.activeSpaceID`
/// changes, this manager checks whether it has an anchor in the new current
/// space, and creates one in-place if not. After the user has visited every
/// Space once during normal use, all clicks switch via the anchor path.
/// Until then, clicks for not-yet-visited spaces fall back to whatever
/// switching mechanism `SpaceSwitcher` chooses (direct CGS API on
/// single-display, gesture on multi-display).
///
/// Anchors are 1×1 px, fully transparent, no-shadow, mouse-pass-through
/// `NSWindow`s. They appear as a near-invisible 1-pixel dot in Mission
/// Control's overview against most wallpapers — that's the unavoidable cost
/// of the mechanism, since the windows have to exist and be findable for
/// macOS to switch to them.
///
/// Multi-display: this manager only operates on the user's current display.
/// On systems with two or more physical displays, the existing gesture-based
/// switching path in `SpaceSwitcher` already works (UUID identifiers are
/// already in use), and the virtual display isn't created in the first place.
final class AnchorWindowSwitcher {

    static let shared = AnchorWindowSwitcher()

    /// Anchors keyed by ManagedSpaceID (the same identifier `SpaceObserver`
    /// publishes). Stays in lockstep with the spaces the user has visited
    /// since the manager started; spaces removed via Mission Control are
    /// pruned by `pruneStaleAnchors()`.
    private var anchors: [Int: NSWindow] = [:]

    private weak var observer: SpaceObserver?
    private var cancellables: Set<AnyCancellable> = []
    private var spaceChangeObserver: NSObjectProtocol?
    private var screenChangeObserver: NSObjectProtocol?

    private init() {}

    // MARK: - Lifecycle

    /// Begin tracking. Idempotent — calling twice is harmless.
    func start(observer: SpaceObserver) {
        guard self.observer == nil else { return }
        self.observer = observer

        // Plant an anchor in the current space immediately so the user's
        // starting space always supports anchor-based switching.
        plantAnchorIfNeeded()

        // Plant lazily on every Space change. The notification fires on the
        // main thread; observer.refresh() runs synchronously before this
        // observer's sink, so the observer's activeSpaceID is up-to-date by
        // the time we read it.
        spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.plantAnchorIfNeeded()
            self?.pruneStaleAnchors()
        }

        // Display config change can add/remove spaces. Re-prune; lazy plant
        // handles new spaces as the user visits them.
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.pruneStaleAnchors()
        }

        aslog("AnchorWindowSwitcher.start: planted initial anchor; \(anchors.count) anchor(s) total")
    }

    /// Stop tracking and tear down all anchors. Safe to call repeatedly.
    func stop() {
        if let token = spaceChangeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            spaceChangeObserver = nil
        }
        if let token = screenChangeObserver {
            NotificationCenter.default.removeObserver(token)
            screenChangeObserver = nil
        }
        for (_, window) in anchors { window.orderOut(nil) }
        anchors.removeAll()
        observer = nil
        aslog("AnchorWindowSwitcher.stop: torn down")
    }

    // MARK: - Switching

    /// Attempts to switch to the given space via the anchor for that space.
    /// Returns true if an anchor existed and was raised; false if no anchor
    /// is currently planted for that space (caller should fall back to its
    /// existing switching mechanism).
    @discardableResult
    func switchTo(managedSpaceID: Int) -> Bool {
        guard let anchor = anchors[managedSpaceID] else {
            aslog("AnchorWindowSwitcher.switchTo: no anchor for space \(managedSpaceID) — fallback")
            return false
        }
        // NSApp.activate alone doesn't always trigger the Space switch — the
        // window has to also be brought to front *and* keyed so macOS
        // recognises it as the activation target. orderFrontRegardless is
        // the load-bearing call: the target space isn't current, so a plain
        // orderFront would no-op.
        NSApp.activate(ignoringOtherApps: true)
        anchor.makeKeyAndOrderFront(nil)
        anchor.orderFrontRegardless()
        aslog("AnchorWindowSwitcher.switchTo: raised anchor for space \(managedSpaceID)")
        return true
    }

    /// True iff an anchor is currently planted for the given space. Used by
    /// SpaceSwitcher to decide whether to take the anchor path or fall back.
    func hasAnchor(forSpace managedSpaceID: Int) -> Bool {
        anchors[managedSpaceID] != nil
    }

    // MARK: - Plant / prune

    private func plantAnchorIfNeeded() {
        guard let observer else { return }
        observer.refresh()
        guard let info = observer.spaceInfo(forIndex: observer.currentSpaceIndex) else { return }
        let id = info.managedSpaceID
        guard anchors[id] == nil else { return }

        let window = makeAnchorWindow(label: "Space \(id)")
        // Window is created in the current space because we are in it right
        // now — no special API needed. `orderFrontRegardless` is the moment
        // WindowServer registers the window as belonging to the current
        // space. Without it the window exists but isn't space-bound, and
        // makeKeyAndOrderFront from another space won't trigger a switch.
        window.orderFrontRegardless()
        anchors[id] = window
        aslog("AnchorWindowSwitcher.plant: planted anchor for space \(id) (now \(anchors.count) total)")
    }

    private func pruneStaleAnchors() {
        guard let observer else { return }
        let liveIDs = Set(observer.orderedSpaces.map(\.managedSpaceID))
        let staleIDs = anchors.keys.filter { !liveIDs.contains($0) }
        for id in staleIDs {
            anchors[id]?.orderOut(nil)
            anchors.removeValue(forKey: id)
            aslog("AnchorWindowSwitcher.prune: removed stale anchor for space \(id)")
        }
    }

    // MARK: - Window construction

    private func makeAnchorWindow(label: String) -> NSWindow {
        // Borderless NSWindow's default `canBecomeKey` is false, which
        // silently breaks our switching mechanism: makeKeyAndOrderFront
        // would order the window forward but never make it key, and macOS
        // only switches Space when the activated app's *key* window is in
        // a different Space. The subclass overrides those properties so
        // the borderless anchor really does become key.
        let window = AnchorWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.title = label
        // alphaValue = 1.0 (NOT 0.001) — observed empirically that macOS's
        // space-switch heuristic skips windows with effective alpha near
        // zero. Visual invisibility is achieved instead by clear background
        // and no content view: the window exists at 1×1 with no pixels to
        // render. WindowServer still considers it a real space-bound window;
        // the user sees nothing.
        window.alphaValue = 1.0
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .normal           // normal level so macOS treats it as a real space-bound window
        window.isReleasedWhenClosed = false
        window.collectionBehavior = []   // default: stays in the space it was born in
        window.hidesOnDeactivate = false
        // Position bottom-right of the main display, off any reasonable user
        // attention zone. 1×1 means the visual artefact in Mission Control
        // is, at most, a single pixel dot.
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: f.maxX - 2, y: f.minY))
        }
        return window
    }
}

/// Borderless `NSWindow` that can become key and main. Required because
/// `[.borderless]` style mask defaults `canBecomeKey` and `canBecomeMain`
/// to false, which silently breaks `makeKeyAndOrderFront` — the window
/// gets ordered front but never made key, and macOS only switches Space
/// when the activated app's key window is in another Space.
private final class AnchorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
