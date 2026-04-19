import AppKit
import SwiftUI
import Combine
import ServiceManagement

// MARK: - Module-level hotkey state (required for C-compatible CGEvent tap callback)

private var _eventTap: CFMachPort?
private var _nextKeyCode: UInt16 = 0
private var _nextModifiers: CGEventFlags = []
private var _prevKeyCode: UInt16 = 0
private var _prevModifiers: CGEventFlags = []
private var _switcherEnabled: Bool = false

/// Action dispatched from the tap callback back to the main thread.
private enum HotkeyAction { case next, prev }
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

    // MARK: - Drift-mitigation observer + restart

    private var reconfigurationObserver: ReconfigurationObserver?
    private var restartCoordinator: RestartCoordinator?

    private var statusItem: NSStatusItem!
    private let observer = SpaceObserver()
    private var popover: NSPopover?
    private var cancellables = Set<AnyCancellable>()
    let updateChecker = JorvikUpdateChecker(repoName: "ActiveSpace")

    // Shortcut state (mirrored to module-level vars for the tap callback)
    var nextKeyCode: UInt16 = 0   { didSet { _nextKeyCode = nextKeyCode } }
    var nextModifiers: NSEvent.ModifierFlags = [] { didSet { _nextModifiers = nextModifiers.cgEventFlags } }
    var prevKeyCode: UInt16 = 0   { didSet { _prevKeyCode = prevKeyCode } }
    var prevModifiers: NSEvent.ModifierFlags = [] { didSet { _prevModifiers = prevModifiers.cgEventFlags } }

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
        setupEventTap()

        VirtualDisplay.startManaging()

        // Drift detection → self-restart. Observer captures the initial
        // fingerprint in its init; coordinator evaluates absolute triggers
        // against it on start() before any event fires.
        let reconfObserver = ReconfigurationObserver { [weak self] event in
            self?.restartCoordinator?.handle(event: event)
        }
        let coordinator = RestartCoordinator(observer: reconfObserver)
        self.reconfigurationObserver = reconfObserver
        self.restartCoordinator = coordinator
        coordinator.start()
        reconfObserver.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        updateIcon()
        updateChecker.checkOnSchedule()

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
            ActiveSpaceLogger.log("Registered keep-alive agent (\(Self.agentPlistName))")
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
        ActiveSpaceLogger.log("User-launched instance detected; kickstarting launchd-owned instance")
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
        case .next: SpaceSwitcher.switchNext(observer: observer)
        case .prev: SpaceSwitcher.switchPrev(observer: observer)
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
        switcherEnabled = d.bool(forKey: "switcherEnabled")
    }

    func saveShortcuts() {
        let d = UserDefaults.standard
        d.set(Int(nextKeyCode), forKey: "nextSpaceKeyCode")
        d.set(Int(nextModifiers.rawValue), forKey: "nextSpaceModifiers")
        d.set(Int(prevKeyCode), forKey: "prevSpaceKeyCode")
        d.set(Int(prevModifiers.rawValue), forKey: "prevSpaceModifiers")
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
            SpaceSwitcher.switchNext(observer: observer)
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
            rootView: SpaceSelectorView(observer: observer) { [weak self, weak p] index in
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
        let menu = JorvikMenuBuilder.buildMenu(
            appName: "ActiveSpace",
            aboutAction: #selector(openAbout),
            settingsAction: #selector(openSettings),
            target: self
        )
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
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
            return Group {
                Section("Switcher") {
                    Toggle("Space-aware Command-Tab", isOn: Binding(
                        get: { delegate.switcherEnabled },
                        set: { delegate.switcherEnabled = $0; delegate.saveSwitcherEnabled() }
                    ))
                    Text("Replaces native Command-Tab with a switcher that only shows apps with windows on the current space. Requires Accessibility (see Permissions below).")
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

                    Text("To avoid conflicts, disable the matching shortcuts in System Settings \u{2192} Keyboard \u{2192} Keyboard Shortcuts \u{2192} Mission Control.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

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
                        if _eventTap != nil {
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
            }.eraseToAnyView()
        }
    }

    // MARK: - Icon

    private func updateIcon() {
        statusItem.button?.image = MenuBarIcon.image(for: observer.currentSpaceIndex)
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
