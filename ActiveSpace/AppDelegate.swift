import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private let observer = SpaceObserver()
    private var popover: NSPopover?
    private var aboutPopover: NSPopover?
    private var aboutMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        updateIcon()

        observer.$currentSpaceIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)

        observer.$totalSpaces
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
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
            SpaceSwitcher.toggle(observer: observer)
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
        p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover = p
    }

    // MARK: - Context menu (right-click)

    private func showContextMenu() {
        let menu = NSMenu()

        let aboutItem = NSMenuItem(title: "About ActiveSpace", action: #selector(openAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit ActiveSpace", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openAbout() {
        guard let button = statusItem.button else { return }
        let p = NSPopover()
        p.behavior = .applicationDefined
        p.animates = true
        let hc = NSHostingController(rootView: AboutView(appName: "ActiveSpace", onDismiss: { [weak self] in self?.closeAbout() }))
        hc.view.wantsLayer = true
        hc.view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        p.contentViewController = hc
        p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        aboutPopover = p
        aboutMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closeAbout()
        }
    }

    private func closeAbout() {
        aboutPopover?.performClose(nil)
        aboutPopover = nil
        if let m = aboutMonitor { NSEvent.removeMonitor(m); aboutMonitor = nil }
    }

    // MARK: - Icon

    private func updateIcon() {
        statusItem.button?.image = MenuBarIcon.image(for: observer.currentSpaceIndex)
    }
}
