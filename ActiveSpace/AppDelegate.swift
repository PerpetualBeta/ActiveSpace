import AppKit
import SwiftUI
import Combine

// MARK: - Module-level hotkey state (required for C-compatible CGEvent tap callback)

private var _eventTap: CFMachPort?
private var _nextKeyCode: UInt16 = 0
private var _nextModifiers: CGEventFlags = []
private var _prevKeyCode: UInt16 = 0
private var _prevModifiers: CGEventFlags = []

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
        return Unmanaged.passUnretained(event)
    }

    guard type == .keyDown else { return Unmanaged.passUnretained(event) }

    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags.intersection(_modifierMask)

    if _nextKeyCode != 0 && keyCode == _nextKeyCode && flags == _nextModifiers {
        DispatchQueue.main.async { _hotkeyAction = .next; NotificationCenter.default.post(name: .activeSpaceHotkey, object: nil) }
        return nil  // consume the event
    }
    if _prevKeyCode != 0 && keyCode == _prevKeyCode && flags == _prevModifiers {
        DispatchQueue.main.async { _hotkeyAction = .prev; NotificationCenter.default.post(name: .activeSpaceHotkey, object: nil) }
        return nil
    }

    return Unmanaged.passUnretained(event)
}

extension Notification.Name {
    fileprivate static let activeSpaceHotkey = Notification.Name("ActiveSpaceHotkey")
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {

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

    /// Exposes the tap so JorvikShortcutRecorder can disable it during recording.
    var currentEventTap: CFMachPort? { _eventTap }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        aslog("applicationDidFinishLaunching: NSScreen.screens.count=\(NSScreen.screens.count)")
        NSApp.setActivationPolicy(.accessory)
        SpaceSwitcher.ensureAccessibility()
        loadShortcuts()
        setupEventTap()

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

    // MARK: - Event tap

    private var hasShownInputMonitoringAlert = false

    private func setupEventTap() {
        guard _eventTap == nil else { return }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
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
    }

    func saveShortcuts() {
        let d = UserDefaults.standard
        d.set(Int(nextKeyCode), forKey: "nextSpaceKeyCode")
        d.set(Int(nextModifiers.rawValue), forKey: "nextSpaceModifiers")
        d.set(Int(prevKeyCode), forKey: "prevSpaceKeyCode")
        d.set(Int(prevModifiers.rawValue), forKey: "prevSpaceModifiers")
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
