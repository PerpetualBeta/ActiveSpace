import AppKit

/// Borderless floating HUD showing the candidate apps for the space-aware
/// Cmd-Tab switcher. Non-activating — the event tap owns the keyboard,
/// the HUD never becomes key. Space-local — no `.canJoinAllSpaces`, so it
/// disappears cleanly if the user Mission-Controls away mid-hold.
final class SwitcherHUDWindow: NSPanel {

    struct Item {
        let icon: NSImage
        let appName: String
        let windowTitle: String
        let hidden: Bool
        let minimised: Bool
    }

    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?

    private let content = SwitcherContentView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        ignoresMouseEvents = false

        let blur = NSVisualEffectView(frame: .zero)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 16
        blur.layer?.masksToBounds = true
        blur.translatesAutoresizingMaskIntoConstraints = false

        content.translatesAutoresizingMaskIntoConstraints = false
        content.onHover = { [weak self] idx in self?.onHover?(idx) }
        content.onClick = { [weak self] idx in self?.onClick?(idx) }

        let container = NSView()
        container.addSubview(blur)
        container.addSubview(content)
        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            blur.topAnchor.constraint(equalTo: container.topAnchor),
            blur.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        contentView = container
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func present(items: [Item], selectedIndex: Int) {
        content.setItems(items, selectedIndex: selectedIndex)
        let size = content.fittingSize
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        setFrame(NSRect(origin: origin, size: size), display: true)
        contentView?.layoutSubtreeIfNeeded()
        orderFrontRegardless()
    }

    func updateSelection(_ index: Int) {
        content.updateSelection(index)
    }

    func dismiss() {
        orderOut(nil)
    }
}

// MARK: - Content view

private final class SwitcherContentView: NSView {

    static let iconSize: CGFloat = 96
    static let iconGap: CGFloat = 24
    static let ringPadding: CGFloat = 10
    static let outerPadding: CGFloat = 28
    static let titleGap: CGFloat = 20
    static let titleHeight: CGFloat = 24

    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?

    private var items: [SwitcherHUDWindow.Item] = []
    private var iconViews: [NSImageView] = []
    private var badgeViews: [NSView?] = []
    private var trackingAreas_: [NSTrackingArea] = []
    private let ring = CALayer()
    private let titleLabel = NSTextField(labelWithString: "")
    private var selectedIndex = 0
    private var cachedFittingSize: NSSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        ring.backgroundColor = NSColor.white.withAlphaComponent(0.35).cgColor
        ring.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        ring.borderWidth = 2
        ring.cornerRadius = 18
        ring.isHidden = true
        layer?.addSublayer(ring)

        titleLabel.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        titleLabel.textColor = NSColor.labelColor
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.truncatesLastVisibleLine = true
        addSubview(titleLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { cachedFittingSize }
    override var fittingSize: NSSize { cachedFittingSize }

    func setItems(_ newItems: [SwitcherHUDWindow.Item], selectedIndex: Int) {
        items = newItems
        self.selectedIndex = selectedIndex

        iconViews.forEach { $0.removeFromSuperview() }
        badgeViews.compactMap { $0 }.forEach { $0.removeFromSuperview() }
        iconViews = newItems.map { item in
            let iv = NSImageView(image: item.icon)
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.imageFrameStyle = .none
            addSubview(iv)
            return iv
        }
        badgeViews = newItems.map { item in
            // Hidden wins over minimised when both — the user's action was "hide", not "minimise".
            if item.hidden { return Self.makeBadge(symbol: "eye.slash.fill", superview: self) }
            if item.minimised { return Self.makeBadge(symbol: "arrow.down", superview: self) }
            return nil
        }

        cachedFittingSize = computeFittingSize()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private static func makeBadge(symbol: String, superview: NSView) -> NSView {
        let size: CGFloat = 26
        let container = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.42).cgColor
        container.layer?.cornerRadius = size / 2
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.55).cgColor
        container.layer?.borderWidth = 1.5

        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        let iv = NSImageView(image: img ?? NSImage())
        iv.contentTintColor = NSColor.white.withAlphaComponent(0.82)
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.frame = NSRect(x: 0, y: 0, width: size, height: size)
        container.addSubview(iv)
        superview.addSubview(container)
        return container
    }

    override func layout() {
        super.layout()
        positionIcons()
        positionTitleLabel()
        rebuildTrackingAreas()
        updateSelection(selectedIndex)
    }

    private func positionTitleLabel() {
        let width = max(0, bounds.width - Self.outerPadding * 2)
        titleLabel.frame = NSRect(
            x: Self.outerPadding,
            y: Self.outerPadding,
            width: width,
            height: Self.titleHeight
        )
    }

    private func computeFittingSize() -> NSSize {
        let count = max(1, items.count)
        let rowWidth = CGFloat(count) * Self.iconSize + CGFloat(max(0, count - 1)) * Self.iconGap
        let width = rowWidth + Self.outerPadding * 2
        let height = Self.outerPadding + Self.iconSize + Self.titleGap + Self.titleHeight + Self.outerPadding
        return NSSize(width: width, height: height)
    }

    private func positionIcons() {
        let count = max(1, items.count)
        let rowWidth = CGFloat(count) * Self.iconSize + CGFloat(max(0, count - 1)) * Self.iconGap
        let startX = (bounds.width - rowWidth) / 2
        let iconY = Self.outerPadding + Self.titleHeight + Self.titleGap
        let badgeSize: CGFloat = 26

        for (i, iv) in iconViews.enumerated() {
            let x = startX + CGFloat(i) * (Self.iconSize + Self.iconGap)
            iv.frame = NSRect(x: x, y: iconY, width: Self.iconSize, height: Self.iconSize)
            if let badge = badgeViews[i] {
                badge.frame = NSRect(
                    x: x + Self.iconSize - badgeSize + 4,
                    y: iconY - 4,
                    width: badgeSize,
                    height: badgeSize
                )
            }
        }
    }

    func updateSelection(_ index: Int) {
        selectedIndex = index
        guard index >= 0, index < iconViews.count else {
            ring.isHidden = true
            titleLabel.stringValue = ""
            return
        }
        let iconFrame = iconViews[index].frame
        let ringFrame = iconFrame.insetBy(dx: -Self.ringPadding, dy: -Self.ringPadding)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = ringFrame
        ring.isHidden = false
        CATransaction.commit()

        let item = items[index]
        let title = item.windowTitle.isEmpty ? item.appName : item.windowTitle
        titleLabel.stringValue = title
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        rebuildTrackingAreas()
    }

    private func rebuildTrackingAreas() {
        trackingAreas_.forEach { removeTrackingArea($0) }
        trackingAreas_ = []
        for (i, iv) in iconViews.enumerated() {
            let area = NSTrackingArea(
                rect: iv.frame,
                options: [.mouseEnteredAndExited, .activeAlways],
                owner: self,
                userInfo: ["index": i]
            )
            addTrackingArea(area)
            trackingAreas_.append(area)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        if let idx = event.trackingArea?.userInfo?["index"] as? Int {
            onHover?(idx)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for (i, iv) in iconViews.enumerated() {
            if iv.frame.contains(p) {
                onClick?(i)
                return
            }
        }
    }
}
