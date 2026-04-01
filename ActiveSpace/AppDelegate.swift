import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private let observer = SpaceObserver()
    private var popover: NSPopover?
    private var cancellables = Set<AnyCancellable>()
    let updateChecker = JorvikUpdateChecker(repoName: "ActiveSpace")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        SpaceSwitcher.ensureAccessibility()

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
            }

            // No pill settings — ActiveSpace already has a custom icon with built-in contrast
        }
    }

    // MARK: - Icon

    private func updateIcon() {
        statusItem.button?.image = MenuBarIcon.image(for: observer.currentSpaceIndex)
    }
}
