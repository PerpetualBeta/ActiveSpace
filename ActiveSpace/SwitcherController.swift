import AppKit

enum SwitcherState { case idle, active }

/// Space-aware Cmd-Tab switcher. Owns the state machine that intercepts
/// Cmd+Tab and drives the HUD. Gated by `_switcherEnabled`; when disabled
/// every handler short-circuits so native Cmd-Tab is untouched.
final class SwitcherController {

    static let shared = SwitcherController()

    private(set) var state: SwitcherState = .idle
    private var enabled = false

    private let resolver = SwitcherAppResolver()
    private let stack = SwitcherAppStack()
    private var candidates: [SwitcherAppResolver.Entry] = []
    private var selectedIndex = 0
    private var lastCGFlags: CGEventFlags = []
    private lazy var hud: SwitcherHUDWindow = {
        let h = SwitcherHUDWindow()
        h.onHover = { [weak self] idx in self?.hoverSelect(index: idx) }
        h.onClick = { [weak self] idx in self?.clickCommit(index: idx) }
        return h
    }()

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }

    @objc private func activeSpaceDidChange() {
        if state == .active {
            aslog("SwitcherController: active space changed mid-switch — cancelling")
            cancel()
        }
    }

    func setEnabled(_ on: Bool) {
        guard enabled != on else { return }
        enabled = on
        if !on && state == .active { cancel() }
        aslog("SwitcherController: setEnabled(\(on))")
    }

    // MARK: - Tap callback entry points (main thread)

    /// Returns true iff the tap should consume the event (return nil).
    func handleKeyDown(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        guard enabled else { return false }

        if state == .idle {
            if keyCode == 48 /* Tab */ && flags.contains(.maskCommand) {
                return begin(reverse: flags.contains(.maskShift))
            }
            return false
        }

        switch keyCode {
        case 48:   advance(forward: !flags.contains(.maskShift)); return true
        case 123:  advance(forward: false); return true   // left arrow
        case 124:  advance(forward: true);  return true   // right arrow
        case 53:   cancel();  return true                  // Escape
        case 36:   commit();  return true                  // Return
        default:   return true                             // swallow Cmd-Q etc. mid-pick
        }
    }

    func handleKeyUp(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        _ = keyCode; _ = flags
        return false
    }

    func handleFlagsChanged(flags: CGEventFlags) -> Bool {
        defer { lastCGFlags = flags }
        guard enabled, state == .active else { return false }

        let hadCmd = lastCGFlags.contains(.maskCommand)
        let hasCmd = flags.contains(.maskCommand)
        if hadCmd && !hasCmd {
            commit()
            return true
        }
        return false
    }

    /// Called from the tap callback when macOS re-enables the tap after a
    /// timeout or user-input flood — state may be stale, so cancel.
    func handleTapReEnabled() {
        if state == .active {
            aslog("SwitcherController: tap re-enabled mid-switch — cancelling")
            cancel()
        }
    }

    // MARK: - State transitions

    // MARK: - HUD entry points

    func hoverSelect(index: Int) {
        guard state == .active, index >= 0, index < candidates.count else { return }
        selectedIndex = index
        hud.updateSelection(index)
    }

    func clickCommit(index: Int) {
        guard state == .active, index >= 0, index < candidates.count else { return }
        selectedIndex = index
        commit()
    }

    // MARK: - State transitions

    private func begin(reverse: Bool) -> Bool {
        candidates = resolver.currentSpaceApps(orderedBy: stack)
        guard candidates.count > 1 else {
            aslog("SwitcherController: begin rejected (candidates=\(candidates.count))")
            candidates = []
            return false
        }
        selectedIndex = reverse ? (candidates.count - 1) : min(1, candidates.count - 1)
        state = .active
        aslog("SwitcherController: triggered reverse=\(reverse) count=\(candidates.count) selected=\(selectedIndex) [\(candidates[selectedIndex].appName)]")
        presentHUD()
        return true
    }

    private func advance(forward: Bool) {
        guard !candidates.isEmpty else { return }
        selectedIndex = forward
            ? (selectedIndex + 1) % candidates.count
            : (selectedIndex - 1 + candidates.count) % candidates.count
        aslog("SwitcherController: advance forward=\(forward) selected=\(selectedIndex) [\(candidates[selectedIndex].appName)]")
        hud.updateSelection(selectedIndex)
    }

    private func commit() {
        let name = (selectedIndex < candidates.count) ? candidates[selectedIndex].appName : "<none>"
        aslog("SwitcherController: commit selected=\(selectedIndex) [\(name)]")
        if selectedIndex < candidates.count {
            let entry = candidates[selectedIndex]
            if let win = entry.minimisableWindow {
                AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                aslog("SwitcherController: unminimised window before activate [\(entry.appName)]")
            }
            if entry.appHidden {
                entry.app.unhide()
                aslog("SwitcherController: unhid app before activate [\(entry.appName)]")
            }
            entry.app.activate()
        }
        reset()
    }

    private func cancel() {
        aslog("SwitcherController: cancel")
        reset()
    }

    private func reset() {
        state = .idle
        candidates = []
        selectedIndex = 0
        hud.dismiss()
    }

    private func presentHUD() {
        let items = candidates.map {
            SwitcherHUDWindow.Item(
                icon: $0.icon,
                appName: $0.appName,
                windowTitle: $0.frontWindowTitle,
                hidden: $0.appHidden,
                minimised: $0.minimisableWindow != nil
            )
        }
        hud.present(items: items, selectedIndex: selectedIndex)
    }
}
