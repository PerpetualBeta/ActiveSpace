import AppKit
import SwiftUI
import Combine
import ServiceManagement
import Sparkle

// MARK: - Module-level hotkey state (required for C-compatible CGEvent tap callback)

private var _eventTap: CFMachPort?
private var _nextKeyCode: UInt16 = 0
private var _nextModifiers: CGEventFlags = []
private var _prevKeyCode: UInt16 = 0
private var _prevModifiers: CGEventFlags = []
private var _upKeyCode: UInt16 = 0
private var _upModifiers: CGEventFlags = []
private var _downKeyCode: UInt16 = 0
private var _downModifiers: CGEventFlags = []
private var _rowWidth: Int = 0
private var _switcherEnabled: Bool = false

/// Action dispatched from the tap callback back to the main thread.
private enum HotkeyAction { case next, prev, up, down }
private var _hotkeyAction: HotkeyAction?

/// The mask of modifier flags we care about when matching shortcuts.
private let _modifierMask: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

private func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // Re-enable tap if the system disabled it (timeout / user-input flood)
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = _eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        if _switcherEnabled { SwitcherController.shared.handleTapReEnabled() }
        return Unmanaged.passUnretained(event)
    }

    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    let fullFlags = event.flags
    let modFlags = fullFlags.intersection(_modifierMask)

    switch type {
    case .keyDown:
        if _nextKeyCode != 0 && keyCode == _nextKeyCode && modFlags == _nextModifiers {
            DispatchQueue.main.async { _hotkeyAction = .next; NotificationCenter.default.post(name: .activeSpaceHotkey, object: nil) }
            return nil
        }
        if _prevKeyCode != 0 && keyCode == _prevKeyCode && modFlags == _prevModifiers {
            DispatchQueue.main.async { _hotkeyAction = .prev; NotificationCenter.default.post(name: .activeSpaceHotkey, object: nil) }
            return nil
        }
        // Up/Down only intercept when grid mode is active. If the user has a
        // binding from a previous session but turned grid off, we let the
        // keystroke flow through to the system rather than silently no-op'ing.
        if _rowWidth >= 2 && _upKeyCode != 0 && keyCode == _upKeyCode && modFlags == _upModifiers {
            DispatchQueue.main.async { _hotkeyAction = .up; NotificationCenter.default.post(name: .activeSpaceHotkey, object: nil) }
            return nil
        }
        if _rowWidth >= 2 && _downKeyCode != 0 && keyCode == _downKeyCode && modFlags == _downModifiers {
            DispatchQueue.main.async { _hotkeyAction = .down; NotificationCenter.default.post(name: .activeSpaceHotkey, object: nil) }
            return nil
        }
        if _switcherEnabled,
           SwitcherController.shared.handleKeyDown(keyCode: keyCode, flags: fullFlags) {
            return nil
        }
        return Unmanaged.passUnretained(event)

    case .keyUp:
        if _switcherEnabled,
           SwitcherController.shared.handleKeyUp(keyCode: keyCode, flags: fullFlags) {
            return nil
        }
        return Unmanaged.passUnretained(event)

    case .flagsChanged:
        if _switcherEnabled,
           SwitcherController.shared.handleFlagsChanged(flags: fullFlags) {
            return nil
        }
        return Unmanaged.passUnretained(event)

    default:
        return Unmanaged.passUnretained(event)
    }
}

extension Notification.Name {
    fileprivate static let activeSpaceHotkey = Notification.Name("ActiveSpaceHotkey")
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Keep-alive agent

    private static let agentPlistName = "cc.jorviksoftware.ActiveSpace.agent.plist"
    private static let agentLabel     = "cc.jorviksoftware.ActiveSpace.agent"
    private var agentService: SMAppService { SMAppService.agent(plistName: Self.agentPlistName) }

    // MARK: - Drift observer + diagnostic monitor

    private var reconfigurationObserver: ReconfigurationObserver?
    private var driftMonitor: DriftMonitor?

    private var statusItem: NSStatusItem!
    private let observer = SpaceObserver()
    private var popover: NSPopover?
    private var cancellables = Set<AnyCancellable>()
    let updateChecker = JorvikUpdateChecker(repoName: "ActiveSpace")
    let sparkleUserDriverDelegate = ActiveSpaceUserDriverDelegate()
    lazy var sparkleUpdater = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: sparkleUserDriverDelegate
    )

    // Shortcut state (mirrored to module-level vars for the tap callback)
    var nextKeyCode: UInt16 = 0   { didSet { _nextKeyCode = nextKeyCode } }
    var nextModifiers: NSEvent.ModifierFlags = [] { didSet { _nextModifiers = nextModifiers.cgEventFlags } }
    var prevKeyCode: UInt16 = 0   { didSet { _prevKeyCode = prevKeyCode } }
    var prevModifiers: NSEvent.ModifierFlags = [] { didSet { _prevModifiers = prevModifiers.cgEventFlags } }
    var upKeyCode: UInt16 = 0     { didSet { _upKeyCode = upKeyCode } }
    var upModifiers: NSEvent.ModifierFlags = [] { didSet { _upModifiers = upModifiers.cgEventFlags } }
    var downKeyCode: UInt16 = 0   { didSet { _downKeyCode = downKeyCode } }
    var downModifiers: NSEvent.ModifierFlags = [] { didSet { _downModifiers = downModifiers.cgEventFlags } }

    /// Conceptual grid row width. 0 = linear (default), ≥2 = grid mode active.
    /// Drives the popover layout and gates the Space Up / Space Down hotkeys.
    var rowWidth: Int = 0 { didSet { _rowWidth = rowWidth } }

    var switcherEnabled: Bool = false {
        didSet {
            _switcherEnabled = switcherEnabled
            SwitcherController.shared.setEnabled(switcherEnabled)
            if switcherEnabled && !oldValue {
                // AX is required by the forthcoming resolver; existing prompt is the feedback.
                SpaceSwitcher.ensureAccessibility()
            }
        }
    }

    /// Exposes the tap so JorvikShortcutRecorder can disable it during recording.
    var currentEventTap: CFMachPort? { _eventTap }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        aslog("applicationDidFinishLaunching: NSScreen.screens.count=\(NSScreen.screens.count)")
        NSApp.setActivationPolicy(.accessory)

        // Deploy the bundled MouseCatcher.app to /Applications/ if missing or
        // older than the embedded copy. Spotlight needs it at a top-level
        // path; the helper bundle inside our Contents/Helpers/ isn't
        // discoverable. Synchronous (~50 ms file copy worst case) — async on
        // a global queue raced the launchd handoff exit and didn't always
        // get a chance to run.
        Self.deployMouseCatcher()

        // Register the keep-alive agent on first launch so the app survives
        // crashes and respawns after self-restart on drift events. If this
        // process wasn't started by launchd (user double-clicked the .app),
        // hand off so KeepAlive actually applies — launchd only monitors
        // processes it started itself.
        registerKeepAliveAgentIfNeeded()
        if shouldHandOffToLaunchd() {
            handOffToLaunchdAndExit()
            return
        }

        SpaceSwitcher.ensureAccessibility()
        loadShortcuts()
        republishHotkeys()
        setupEventTap()

        VirtualDisplay.startManaging()

        // Drift detection → diagnostic log. The launchd keep-alive agent
        // still provides crash-resilience respawn; the monitor just
        // classifies and logs drift events for future debugging.
        let reconfObserver = ReconfigurationObserver { [weak self] event in
            self?.driftMonitor?.handle(event: event)
        }
        let monitor = DriftMonitor(observer: reconfObserver)
        self.reconfigurationObserver = reconfObserver
        self.driftMonitor = monitor
        monitor.start()
        reconfObserver.start()

        // Pre-warm + pre-render icons for every currently-running regular app
        // so the first Switcher HUD draw after launch doesn't pay icon-service
        // and scale-down rendering costs on the main thread. Observe app
        // launches to keep the cache warm as new apps come online.
        AppIconCache.warmRunningApps()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular else { return }
            AppIconCache.warm(for: app)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        updateIcon()
        // Sparkle (sparkleUpdater) handles update polling now. Legacy
        // JorvikUpdateChecker instance is kept around because
        // JorvikSettingsView.showWindow still requires one as a parameter,
        // pending JorvikKit retirement (see infrastructure-open-follow-ups §11.5).
        _ = sparkleUpdater  // forces lazy init so Sparkle starts at launch
        // updateChecker.checkOnSchedule()  // disabled — Sparkle owns this now

        observer.$currentSpaceIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)

        observer.$totalSpaces
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .activeSpaceHotkey)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handleHotkey() }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Tear down the virtual display before exit so a self-restart under
        // launchd doesn't inherit a lingering 640×480 that would poison the
        // respawned instance's initial fingerprint.
        VirtualDisplay.teardown()
    }

    // MARK: - Keep-alive agent

    private func registerKeepAliveAgentIfNeeded() {
        guard agentService.status == .notRegistered else { return }
        do {
            try agentService.register()
            aslog("Registered keep-alive agent (\(Self.agentPlistName))")
        } catch {
            NSLog("ActiveSpace: agent register failed: \(error)")
        }
    }

    /// True when the agent is enabled AND this process was NOT started by
    /// launchd. launchd injects `XPC_SERVICE_NAME` into the environment of
    /// jobs it starts — absence of that variable is the reliable signal
    /// that we're a user-launched instance.
    private func shouldHandOffToLaunchd() -> Bool {
        guard agentService.status == .enabled else { return false }
        let xpcService = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"]
        return xpcService != Self.agentLabel
    }

    /// Ask launchd to kickstart the agent and exit cleanly. The kickstarted
    /// instance comes up with `XPC_SERVICE_NAME` set and runs normally.
    /// `terminate(nil)` exits with code 0, which KeepAlive's
    /// `SuccessfulExit=false` rule correctly ignores.
    private func handOffToLaunchdAndExit() {
        aslog("User-launched instance detected; kickstarting launchd-owned instance")
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = ["kickstart", "gui/\(getuid())/\(Self.agentLabel)"]
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            NSLog("ActiveSpace: kickstart failed: \(error)")
        }
        NSApp.terminate(nil)
    }

    // MARK: - MouseCatcher self-deploy

    /// Mirrors the embedded `Contents/Helpers/MouseCatcher.app` to
    /// `/Applications/MouseCatcher.app` so Spotlight can find it. Idempotent
    /// — skips when the deployed `CFBundleShortVersionString` already
    /// matches the embedded one. Refuses to overwrite a foreign bundle
    /// (different `CFBundleIdentifier`) at the same path.
    ///
    /// Why `/Applications/` and not `/Applications/Utilities/`: the
    /// `Utilities` subfolder is owned by `root:wheel` mode 755 — even
    /// admin users can't write there without elevation. `/Applications/`
    /// itself is `drwxrwxr-x root:admin`, so admin-group users can deploy
    /// without an authorisation prompt. Sibling-of-ActiveSpace install also
    /// matches every other Jorvik utility's location.
    static func deployMouseCatcher() {
        let embeddedURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/MouseCatcher.app")
        guard FileManager.default.fileExists(atPath: embeddedURL.path) else {
            aslog("MouseCatcher: no embedded copy in this build, skipping deploy")
            return
        }

        let deployedURL = URL(fileURLWithPath: "/Applications/MouseCatcher.app")
        let embeddedID = readBundleString(at: embeddedURL, key: "CFBundleIdentifier")
        let embeddedVersion = readBundleString(at: embeddedURL, key: "CFBundleShortVersionString")

        if FileManager.default.fileExists(atPath: deployedURL.path) {
            let deployedID = readBundleString(at: deployedURL, key: "CFBundleIdentifier")
            let deployedVersion = readBundleString(at: deployedURL, key: "CFBundleShortVersionString")
            if deployedID != embeddedID {
                aslog("MouseCatcher: existing /Applications/MouseCatcher.app has bundle ID \(deployedID ?? "(unknown)") — refusing to overwrite")
                return
            }
            if deployedVersion == embeddedVersion {
                return  // already current
            }
            aslog("MouseCatcher: updating deployed copy \(deployedVersion ?? "?") → \(embeddedVersion ?? "?")")
        }

        do {
            if FileManager.default.fileExists(atPath: deployedURL.path) {
                try FileManager.default.removeItem(at: deployedURL)
            }
            try FileManager.default.copyItem(at: embeddedURL, to: deployedURL)
            aslog("MouseCatcher: deployed v\(embeddedVersion ?? "?") to \(deployedURL.path)")
        } catch {
            aslog("MouseCatcher: deploy failed: \(error.localizedDescription)")
        }
    }

    private static func readBundleString(at bundleURL: URL, key: String) -> String? {
        let plistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let raw = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let plist = raw as? [String: Any]
        else { return nil }
        return plist[key] as? String
    }

    // MARK: - Event tap

    private var hasShownInputMonitoringAlert = false

    private func setupEventTap() {
        guard _eventTap == nil else { return }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: nil
        ) else {
            NSLog("ActiveSpace: Failed to create CGEventTap")

            // If Accessibility is granted but the tap still fails,
            // the user likely needs to grant Input Monitoring.
            if AXIsProcessTrusted() && !hasShownInputMonitoringAlert {
                hasShownInputMonitoringAlert = true
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Input Monitoring Required"
                    alert.informativeText = "ActiveSpace needs Input Monitoring permission to use keyboard shortcuts for space switching.\n\nPlease add ActiveSpace in System Settings \u{2192} Privacy & Security \u{2192} Input Monitoring, then relaunch."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Open System Settings")
                    alert.addButton(withTitle: "Later")

                    if alert.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                    }
                }
            }
            return
        }

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        _eventTap = tap
    }

    // MARK: - Hotkey handling

    private func handleHotkey() {
        guard let action = _hotkeyAction else { return }
        _hotkeyAction = nil
        switch action {
        case .next: SpaceSwitcher.switchNext(rowWidth: rowWidth, observer: observer)
        case .prev: SpaceSwitcher.switchPrev(rowWidth: rowWidth, observer: observer)
        case .up:   SpaceSwitcher.switchUp(rowWidth: rowWidth, observer: observer)
        case .down: SpaceSwitcher.switchDown(rowWidth: rowWidth, observer: observer)
        }
    }

    // MARK: - Shortcut persistence

    private func loadShortcuts() {
        let d = UserDefaults.standard
        let nk = d.integer(forKey: "nextSpaceKeyCode")
        let nm = d.integer(forKey: "nextSpaceModifiers")
        if nk != 0 && nm != 0 {
            nextKeyCode = UInt16(nk)
            nextModifiers = NSEvent.ModifierFlags(rawValue: UInt(nm))
        }
        let pk = d.integer(forKey: "prevSpaceKeyCode")
        let pm = d.integer(forKey: "prevSpaceModifiers")
        if pk != 0 && pm != 0 {
            prevKeyCode = UInt16(pk)
            prevModifiers = NSEvent.ModifierFlags(rawValue: UInt(pm))
        }
        let uk = d.integer(forKey: "upSpaceKeyCode")
        let um = d.integer(forKey: "upSpaceModifiers")
        if uk != 0 && um != 0 {
            upKeyCode = UInt16(uk)
            upModifiers = NSEvent.ModifierFlags(rawValue: UInt(um))
        }
        let dk = d.integer(forKey: "downSpaceKeyCode")
        let dm = d.integer(forKey: "downSpaceModifiers")
        if dk != 0 && dm != 0 {
            downKeyCode = UInt16(dk)
            downModifiers = NSEvent.ModifierFlags(rawValue: UInt(dm))
        }
        rowWidth = d.integer(forKey: "rowWidth")           // 0 if absent
        switcherEnabled = d.bool(forKey: "switcherEnabled")
    }

    func saveShortcuts() {
        let d = UserDefaults.standard
        d.set(Int(nextKeyCode), forKey: "nextSpaceKeyCode")
        d.set(Int(nextModifiers.rawValue), forKey: "nextSpaceModifiers")
        d.set(Int(prevKeyCode), forKey: "prevSpaceKeyCode")
        d.set(Int(prevModifiers.rawValue), forKey: "prevSpaceModifiers")
        d.set(Int(upKeyCode), forKey: "upSpaceKeyCode")
        d.set(Int(upModifiers.rawValue), forKey: "upSpaceModifiers")
        d.set(Int(downKeyCode), forKey: "downSpaceKeyCode")
        d.set(Int(downModifiers.rawValue), forKey: "downSpaceModifiers")
        republishHotkeys()
    }

    /// Push the four space-switch bindings to the JorvikKit registry so
    /// ShortcutHUD can list them. Only emits entries the user has actually
    /// bound (keyCode != 0).
    func republishHotkeys() {
        var hotkeys: [JorvikHotkey] = []
        if nextKeyCode != 0 {
            hotkeys.append(JorvikHotkey(actionTitle: "Next Space",
                                        keyCode: nextKeyCode,
                                        modifiers: nextModifiers,
                                        activeContext: .anywhere))
        }
        if prevKeyCode != 0 {
            hotkeys.append(JorvikHotkey(actionTitle: "Previous Space",
                                        keyCode: prevKeyCode,
                                        modifiers: prevModifiers,
                                        activeContext: .anywhere))
        }
        if upKeyCode != 0 {
            hotkeys.append(JorvikHotkey(actionTitle: "Space Up",
                                        keyCode: upKeyCode,
                                        modifiers: upModifiers,
                                        activeContext: .anywhere))
        }
        if downKeyCode != 0 {
            hotkeys.append(JorvikHotkey(actionTitle: "Space Down",
                                        keyCode: downKeyCode,
                                        modifiers: downModifiers,
                                        activeContext: .anywhere))
        }
        JorvikHotkeyRegistry.publish(hotkeys)
    }

    func saveRowWidth() {
        UserDefaults.standard.set(rowWidth, forKey: "rowWidth")
    }

    func saveSwitcherEnabled() {
        UserDefaults.standard.set(switcherEnabled, forKey: "switcherEnabled")
    }

    func nextShortcutDisplayString() -> String {
        guard nextKeyCode != 0 else { return "Not set" }
        return JorvikShortcutPanel.displayString(keyCode: nextKeyCode, modifiers: nextModifiers)
    }

    func prevShortcutDisplayString() -> String {
        guard prevKeyCode != 0 else { return "Not set" }
        return JorvikShortcutPanel.displayString(keyCode: prevKeyCode, modifiers: prevModifiers)
    }

    func upShortcutDisplayString() -> String {
        guard upKeyCode != 0 else { return "Not set" }
        return JorvikShortcutPanel.displayString(keyCode: upKeyCode, modifiers: upModifiers)
    }

    func downShortcutDisplayString() -> String {
        guard downKeyCode != 0 else { return "Not set" }
        return JorvikShortcutPanel.displayString(keyCode: downKeyCode, modifiers: downModifiers)
    }

    // MARK: - Click handling

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }

        let count = observer.totalSpaces
        if count <= 1 {
            return
        } else if count == 2 {
            SpaceSwitcher.switchNext(rowWidth: rowWidth, observer: observer)
        } else {
            togglePopover(relativeTo: sender)
        }
    }

    // MARK: - Popover (3+ spaces)

    private func togglePopover(relativeTo button: NSView) {
        if let existing = popover, existing.isShown {
            existing.performClose(nil)
            return
        }

        let p = NSPopover()
        p.behavior = .transient
        p.animates = true
        p.contentViewController = NSHostingController(
            rootView: SpaceSelectorView(observer: observer, rowWidth: rowWidth) { [weak self, weak p] index in
                p?.performClose(nil)
                guard let self else { return }
                SpaceSwitcher.switchTo(index: index, observer: self.observer)
            }
        )

        // Activate the app so the popover takes key focus — without this, as an
        // accessory-policy app we don't have focus, so .transient's native Escape
        // and outside-click handling is unreliable.
        NSApp.activate(ignoringOtherApps: true)
        p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        p.contentViewController?.view.window?.makeKey()
        popover = p

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePopoverClosed),
            name: NSPopover.didCloseNotification,
            object: p
        )
    }

    @objc private func handlePopoverClosed() {
        popover = nil
    }

    // MARK: - Context menu (right-click)

    private func showContextMenu() {
        let actions: [JorvikMenuBuilder.ActionItem] = [
            .init(
                title: "Check for Updates\u{2026}",
                action: #selector(checkForUpdates(_:)),
                target: self
            )
        ]
        let menu = JorvikMenuBuilder.buildMenu(
            appName: "ActiveSpace",
            aboutAction: #selector(openAbout),
            settingsAction: #selector(openSettings),
            target: self,
            actions: actions
        )
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc func checkForUpdates(_ sender: Any?) {
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        sparkleUpdater.checkForUpdates(sender)
    }

    @objc private func openAbout() {
        JorvikAboutView.showWindow(
            appName: "ActiveSpace",
            repoName: "ActiveSpace",
            productPage: "utilities/activespace"
        )
    }

    @objc private func openSettings() {
        JorvikSettingsView.showWindow(
            appName: "ActiveSpace",
            updateChecker: updateChecker
        ) { [weak self] in
            guard let delegate = self else { return EmptyView().eraseToAnyView() }
            return ActiveSpaceSettingsContent(delegate: delegate).eraseToAnyView()
        }
    }

    // MARK: - Icon

    private func updateIcon() {
        statusItem.button?.image = MenuBarIcon.image(for: observer.currentSpaceIndex)
    }
}

// MARK: - Sparkle user driver delegate

/// Keeps Sparkle's update UI visible across the whole session, including
/// when the user switches to another app mid-download. See KB:
/// `conventions/sparkle-integration.md` §6 for the rationale.
final class ActiveSpaceUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    private var sessionObserver: NSObjectProtocol?
    private var elevatedWindows: [(window: NSWindow, originalLevel: NSWindow.Level)] = []

    func standardUserDriverWillShowModalAlert() {
        bringForward()
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        startFocusGuard()
        bringForward()
    }

    func standardUserDriverWillFinishUpdateSession() {
        stopFocusGuard()
    }

    private func bringForward() {
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        elevateAllWindows()
    }

    private func startFocusGuard() {
        guard sessionObserver == nil else { return }
        sessionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.bringForward()
        }
    }

    private func stopFocusGuard() {
        if let obs = sessionObserver {
            NotificationCenter.default.removeObserver(obs)
            sessionObserver = nil
        }
        for entry in elevatedWindows {
            entry.window.level = entry.originalLevel
        }
        elevatedWindows.removeAll()
    }

    private func elevateAllWindows() {
        for window in NSApp.windows where window.isVisible && window.level == .normal {
            elevatedWindows.append((window, window.level))
            window.level = .floating
        }
    }
}

// MARK: - Helpers

private extension NSEvent.ModifierFlags {
    /// Convert AppKit modifier flags to CGEventFlags for the tap callback.
    var cgEventFlags: CGEventFlags {
        var result: CGEventFlags = []
        if contains(.command)  { result.insert(.maskCommand) }
        if contains(.control)  { result.insert(.maskControl) }
        if contains(.option)   { result.insert(.maskAlternate) }
        if contains(.shift)    { result.insert(.maskShift) }
        return result
    }
}

private extension View {
    func eraseToAnyView() -> AnyView { AnyView(self) }
}

// MARK: - Settings content

/// All ActiveSpace-specific Settings sections, hosted as a single SwiftUI
/// view so that `@State rowWidth` drives both the Stepper's label *and* the
/// conditional disclosure of the Space Up / Space Down shortcut recorders.
/// AppDelegate is not @ObservableObject, so without consolidating the
/// settings UI here, the closure passed to `JorvikSettingsView` would have
/// no way to react to changes.
private struct ActiveSpaceSettingsContent: View {

    let delegate: AppDelegate
    @State private var rowWidth: Int

    init(delegate: AppDelegate) {
        self.delegate = delegate
        self._rowWidth = State(initialValue: delegate.rowWidth)
    }

    var body: some View {
        Group {
            Section("Switcher") {
                Toggle("Space-aware Command-Tab", isOn: Binding(
                    get: { delegate.switcherEnabled },
                    set: { delegate.switcherEnabled = $0; delegate.saveSwitcherEnabled() }
                ))
                Text("Replaces native Command-Tab with a switcher that only shows apps with windows on the current space. Requires Accessibility (see Permissions below).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Grid") {
                Stepper(value: $rowWidth, in: 0...12) {
                    Text(rowWidth == 0 ? "Row width: linear"
                                       : "Row width: \(rowWidth) per row")
                }
                .onChange(of: rowWidth) { _, newValue in
                    delegate.rowWidth = newValue
                    delegate.saveRowWidth()
                }
                Text("Lay out the popover as a grid of this width and enable Space Up / Space Down keyboard shortcuts. Set to 0 for the original linear strip.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Keyboard Shortcuts") {
                JorvikShortcutRecorder(
                    label: "Previous Space",
                    keyCode: Binding(
                        get: { delegate.prevKeyCode },
                        set: { delegate.prevKeyCode = $0 }
                    ),
                    modifiers: Binding(
                        get: { delegate.prevModifiers },
                        set: { delegate.prevModifiers = $0 }
                    ),
                    displayString: { delegate.prevShortcutDisplayString() },
                    onChanged: { delegate.saveShortcuts() },
                    eventTapToDisable: delegate.currentEventTap
                )
                JorvikShortcutRecorder(
                    label: "Next Space",
                    keyCode: Binding(
                        get: { delegate.nextKeyCode },
                        set: { delegate.nextKeyCode = $0 }
                    ),
                    modifiers: Binding(
                        get: { delegate.nextModifiers },
                        set: { delegate.nextModifiers = $0 }
                    ),
                    displayString: { delegate.nextShortcutDisplayString() },
                    onChanged: { delegate.saveShortcuts() },
                    eventTapToDisable: delegate.currentEventTap
                )

                if rowWidth >= 2 {
                    JorvikShortcutRecorder(
                        label: "Space Up",
                        keyCode: Binding(
                            get: { delegate.upKeyCode },
                            set: { delegate.upKeyCode = $0 }
                        ),
                        modifiers: Binding(
                            get: { delegate.upModifiers },
                            set: { delegate.upModifiers = $0 }
                        ),
                        displayString: { delegate.upShortcutDisplayString() },
                        onChanged: { delegate.saveShortcuts() },
                        eventTapToDisable: delegate.currentEventTap
                    )
                    JorvikShortcutRecorder(
                        label: "Space Down",
                        keyCode: Binding(
                            get: { delegate.downKeyCode },
                            set: { delegate.downKeyCode = $0 }
                        ),
                        modifiers: Binding(
                            get: { delegate.downModifiers },
                            set: { delegate.downModifiers = $0 }
                        ),
                        displayString: { delegate.downShortcutDisplayString() },
                        onChanged: { delegate.saveShortcuts() },
                        eventTapToDisable: delegate.currentEventTap
                    )
                }

                Text("To avoid conflicts, disable the matching shortcuts in System Settings \u{2192} Keyboard \u{2192} Keyboard Shortcuts \u{2192} Mission Control.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VirtualDisplaySizeSection()

            Section("Permissions") {
                HStack {
                    Text("Accessibility")
                    Spacer()
                    if AXIsProcessTrusted() {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    } else {
                        Button("Grant Access") {
                            SpaceSwitcher.ensureAccessibility()
                        }
                        .font(.caption)
                    }
                }
                HStack {
                    Text("Input Monitoring")
                    Spacer()
                    if delegate.currentEventTap != nil {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    } else {
                        Button("Grant Access") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                        }
                        .font(.caption)
                    }
                }
            }
        }
    }
}

// MARK: - Virtual Display size walk-down experiment
//
// Built 2026-05-08 to find the smallest virtual-display size that still
// triggers BOTH (1) NSScreen.screens.count → 2 and (2) the CGS "Display
// Identifier" flip from "Main" to a UUID. These are the two conditions
// the virtual exists to satisfy. A smaller virtual = smaller surface for
// cursor traps, Spotlight mis-routing, and screensaver mis-sizing.
//
// Picker writes VirtualDisplayWidth / VirtualDisplayHeight defaults; the
// "Apply" button calls VirtualDisplay.recreate() to take them live. The
// diagnostic block reads the live state so the threshold is visible
// in-place without a separate probe.
private struct VirtualDisplaySizeSection: View {

    private struct Preset: Identifiable {
        let w: Int
        let h: Int
        var id: String { "\(w)x\(h)" }
        var label: String { "\(w) × \(h)" }
    }

    private let presets: [Preset] = [
        Preset(w: 640, h: 480),
        Preset(w: 480, h: 360),
        Preset(w: 400, h: 300),
        Preset(w: 320, h: 240),
        Preset(w: 256, h: 192),
        Preset(w: 200, h: 150),
        Preset(w: 160, h: 120),
        Preset(w: 128, h: 96),
        Preset(w: 96, h: 72),
        Preset(w: 64, h: 48),
        Preset(w: 32, h: 32),
        Preset(w: 16, h: 16),
    ]

    @AppStorage("VirtualDisplayWidth") private var storedWidth: Int = 640
    @AppStorage("VirtualDisplayHeight") private var storedHeight: Int = 480
    @State private var diagnosticTick: Int = 0

    var body: some View {
        Section("Virtual Display (experimental)") {
            Picker("Size", selection: Binding<String>(
                get: { "\(storedWidth)x\(storedHeight)" },
                set: { tag in
                    let parts = tag.split(separator: "x").compactMap { Int($0) }
                    guard parts.count == 2 else { return }
                    storedWidth = parts[0]
                    storedHeight = parts[1]
                }
            )) {
                ForEach(presets) { p in
                    Text(p.label).tag(p.id)
                }
            }

            HStack {
                Button("Apply (recreate now)") {
                    VirtualDisplay.recreate()
                    // Refresh the diagnostic ~1.2s after the recreate kicks
                    // off so WindowServer has settled before we read.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        diagnosticTick &+= 1
                    }
                }
                Spacer()
                Button("Refresh diagnostic") { diagnosticTick &+= 1 }
                    .font(.caption)
            }

            DiagnosticView(tick: diagnosticTick)

            Text("Smaller is better for reducing cursor traps and Spotlight / screensaver mis-routing — but the virtual must stay large enough to register as an extended display. 1 × 1 puts macOS into mirror-source mode and breaks the system. Walk down from 640 × 480 until the diagnostic flips to bad, then go one step back up.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private struct DiagnosticView: View {
        let tick: Int

        var body: some View {
            let count = NSScreen.screens.count
            let ident = readDisplayIdentifier()
            let countOK = count >= 2
            let identOK = ident != "Main" && ident != "?" && !ident.isEmpty
            let bothOK = countOK && identOK

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("NSScreen count").font(.caption)
                    Spacer()
                    Text("\(count) \(countOK ? "✓" : "✗")")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(countOK ? .green : .red)
                }
                HStack {
                    Text("Display Identifier").font(.caption)
                    Spacer()
                    Text("\(short(ident)) \(identOK ? "✓" : "✗")")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(identOK ? .green : .red)
                }
                Text(bothOK
                     ? "Both flips OK — this size is viable."
                     : "Size doesn't trigger the flips we need.")
                    .font(.caption2)
                    .foregroundStyle(bothOK ? .green : .orange)
            }
            .id(tick)
        }

        private func readDisplayIdentifier() -> String {
            guard let arr = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]] else { return "?" }
            guard let first = arr.first else { return "?" }
            if let s = first["Display Identifier"] as? String { return s }
            return "?"
        }

        private func short(_ s: String) -> String {
            if s.count <= 14 { return s }
            return String(s.prefix(8)) + "…"
        }
    }
}
