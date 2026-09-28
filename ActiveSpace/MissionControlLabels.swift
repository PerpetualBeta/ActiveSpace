import AppKit
import ApplicationServices
import Combine

/// Draws the user's space names over Mission Control's "Desktop 1", "Desktop 2"
/// captions.
///
/// Nothing lets another app change those captions. What can be done, and what
/// MacSpaceLabeler (github.com/JohnSparham/MacSpaceLabeler) showed working on
/// macOS 26, is to read where each thumbnail is through Accessibility and float
/// a small click-through label window over each caption. The captions
/// underneath are untouched.
///
/// **macOS 27 moved the Spaces Bar.** Measured 2026-09-28 on 27.0 (26A428):
/// the Dock still grows an AXGroup "Mission Control" while Mission Control is
/// open, but it is an empty 0x0 stub with no children, with or without
/// AXEnhancedUserInterface. The bar now lives in **WindowManager**
/// (com.apple.WindowManager), found by scanning every running app's tree:
///
///     AXApplication "WindowManager"
///       AXGroup id=mc.display              one per display
///         AXGroup "Spaces Bar" id=mc.spaces
///           AXList id=mc.spaces.list
///             AXButton "Desktop 1" desc="exit to Desktop 1"   one per space
///
/// The Dock path is kept for macOS 26 and earlier, with MacSpaceLabeler's
/// shape and geometry. It is not tested here: there is no macOS 26 machine.
///
/// Differences from MacSpaceLabeler, each deliberate:
/// - Names are matched to thumbnails by UUID, not by position, so a macOS
///   reorder cannot move a name onto the wrong desktop.
/// - Every Spaces Bar is labelled, one per display, not only the first found,
///   including the copies macOS 27 draws without an AX tree (see
///   `windowManagerCaptions`).
/// - AX coordinates are converted against the primary screen, which is what
///   they are relative to, not `NSScreen.main`, which follows the key window.
/// - It only polls while "Show names in Mission Control" is on.
final class MissionControlLabels {

    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var windows: [LabelWindow] = []
    private var apps: [String: (pid: pid_t, element: AXUIElement)] = [:]

    /// macOS 27 moved the Spaces Bar to WindowManager and left the Dock an
    /// empty stub, so on 27 and later the Dock is never asked. Asking it on
    /// every poll while Mission Control was closed was half of the poll's cost
    /// in a 20 s sample, for an answer that is always empty.
    private static let spacesBarIsInDock = ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27
    private var wasOpen = false
    /// The last mismatch logged, so a bar that stays unmatched is logged once
    /// per Mission Control opening rather than four times a second.
    private var lastMismatch: String?

    /// How often to look for Mission Control while the setting is on. 250 ms is
    /// MacSpaceLabeler's value: slow enough to cost little, quick enough that
    /// the labels arrive as Mission Control finishes opening. Tune it live:
    ///
    ///   defaults write cc.jorviksoftware.ActiveSpace ActiveSpace.missionControlPollMs -int 250
    ///
    /// Read when the poll starts, so toggle the setting off and on to apply.
    private static var pollInterval: TimeInterval {
        let ms = UserDefaults.standard.object(forKey: "ActiveSpace.missionControlPollMs") as? Int ?? 250
        return TimeInterval(max(50, ms)) / 1000
    }

    /// How late, as a fraction of the interval, the poll may fire. See `start`.
    private static let pollToleranceFraction = 0.2

    /// Why this polls at all. Measured 2026-09-28 on 27.0, nothing announces
    /// Mission Control opening or closing:
    /// - AXObserver on WindowManager and the Dock: AXCreated,
    ///   AXUIElementDestroyed and AXFocusedUIElementChanged register, and the
    ///   Dock also takes AXExposeShowAllWindows, AXExposeShowFrontWindows,
    ///   AXExposeShowDesktop and AXExposeExit (the names yabai used). None
    ///   fired across two opens and closes, while the same observer code
    ///   received AXApplicationActivated from Finder as a control.
    /// - Distributed and Darwin notifications, subscribed by name, for the
    ///   nine candidates in the two binaries (com.apple.expose.awake and
    ///   others): none fired. A subscription to ALL distributed notifications
    ///   is no evidence either way, because it silently receives nothing.
    /// vorssaint-utils PR #1845 reports the Expose notifications silent on 27.2.
    ///
    /// The longest one AX call may block the main thread. The system default is
    /// six seconds, and WindowManager and the Dock are busiest exactly while
    /// Mission Control animates, so an unbounded call could freeze the menu bar
    /// icon. A timed-out poll just draws nothing and the next one tries again.
    private static let axMessagingTimeout: Float = 0.1

    /// How far below a WindowManager button's AX position the centre of its
    /// caption sits, in points. **Measured, not derived**: on macOS 27 the AX
    /// "position" of each Spaces Bar button is the thumbnail's CENTRE, not its
    /// top-left corner. Every caption's centre x matched the AX x to within
    /// 0.5 pt, collapsed and expanded, and the caption centre sat 53.5 pt
    /// (collapsed bar, AX y = -33) and 52.5 pt (expanded, AX y = 102) below the
    /// AX y, read from screen captures on 2026-09-28. Nothing in the AX frame
    /// predicts it: the reported size, 190x129, is not the drawn thumbnail
    /// (166x92) in either state. Tune it live:
    ///
    ///   defaults write cc.jorviksoftware.ActiveSpace ActiveSpace.missionControlCaptionOffset -float 53
    private static var captionOffset: CGFloat {
        (UserDefaults.standard.object(forKey: "ActiveSpace.missionControlCaptionOffset") as? Double)
            .map { CGFloat($0) } ?? 53
    }

    /// Clear space kept between neighbouring labels. The collapsed bar puts
    /// captions only 88 pt apart, while each button reports a width of 190, so
    /// a label must be bounded by its neighbours, not by its button.
    private static let labelGap: CGFloat = 4

    init() {
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] app in
                self?.apps = self?.apps.filter { $0.value.pid != app.processIdentifier } ?? [:]
            }
            .store(in: &cancellables)

        SpaceNames.shared.$showInMissionControl
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in on ? self?.start() : self?.stop() }
            .store(in: &cancellables)
    }

    private func start() {
        guard timer == nil else { return }
        aslog("MissionControlLabels: polling every \(Int(Self.pollInterval * 1000)) ms")
        let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in self?.poll() }
        // Let macOS fire this up to a fifth of an interval late (50 ms at the
        // default), so it can share a wake-up with other timers instead of
        // waking the CPU four times a second on its own. Apple's guidance is
        // at least 10%. A label arriving 50 ms later is not visible against
        // Mission Control's own opening animation.
        t.tolerance = Self.pollInterval * Self.pollToleranceFraction
        // .common, or the poll pauses while a menu or the popover is tracking.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        hideAll()
        wasOpen = false
        aslog("MissionControlLabels: stopped")
    }

    // MARK: - Poll

    /// Where one label goes: the centre of the caption it covers, in AX
    /// coordinates, the widest it may be, and the caption's own text, so the
    /// label is never narrower than what it has to hide.
    private struct Caption {
        let centre: CGPoint
        let maxWidth: CGFloat
        let covers: String
        let name: String
    }

    private func poll() {
        guard AXIsProcessTrusted() else { hideAll(); return }

        // WindowManager first: macOS 27. Its Spaces Bar exists only while
        // Mission Control is open, so finding one IS the open check.
        var captions: [Caption] = []
        var found = false
        if let wm = appElement("com.apple.WindowManager") {
            let bars = spacesBars(in: wm, depthLimit: 2) { identifier(of: $0) == "mc.spaces" }
            found = !bars.isEmpty
            let mirror = bars.count == 1 && NSScreen.screens.count > 1 && Self.displaysShareSpaces()
            for bar in bars { captions += windowManagerCaptions(in: bar, mirrorToOtherScreens: mirror) }
        }
        if !found, Self.spacesBarIsInDock, let dock = appElement("com.apple.dock"),
           let mc = children(of: dock).first(where: { title(of: $0) == "Mission Control" }) {
            let bars = spacesBars(in: mc, depthLimit: 3) { title(of: $0) == "Spaces Bar" }
            found = !bars.isEmpty
            for bar in bars { captions += dockCaptions(in: bar) }
        }

        if found != wasOpen {
            wasOpen = found
            lastMismatch = nil
            aslog("MissionControlLabels: Mission Control \(found ? "open" : "closed")")
        }
        found ? show(captions) : hideAll()
    }

    /// The AX element for a running app, kept until that process ends.
    /// Looking the app up by bundle ID walks every running application, and
    /// doing it on each poll was 61% of the poll's cost in a 20 s sample
    /// (132 of 217 samples).
    ///
    /// Nothing is checked per poll. The entry is dropped when AppKit reports
    /// the process ended (see `init`), so a restart (killall Dock, a crash) is
    /// looked up again. Both per-poll checks tried cost more than the work
    /// they guarded: `NSRunningApplication.isTerminated` makes a synchronous
    /// XPC call to LaunchServices (36 of 55 samples), and `kill(pid, 0)` still
    /// took 19 of 29, about 0.24 ms a call on this Mac.
    private func appElement(_ bundleID: String) -> AXUIElement? {
        if let cached = apps[bundleID] { return cached.element }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            apps[bundleID] = nil
            return nil
        }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, Self.axMessagingTimeout)
        apps[bundleID] = (app.processIdentifier, el)
        return el
    }

    /// Every Spaces Bar under `root`, one per display when "Displays have
    /// separate Spaces" is on.
    private func spacesBars(in root: AXUIElement, depthLimit: Int,
                            matching isBar: (AXUIElement) -> Bool) -> [AXUIElement] {
        var found: [AXUIElement] = []
        func walk(_ el: AXUIElement, depth: Int) {
            guard depth <= depthLimit else { return }
            for child in children(of: el) {
                if isBar(child) { found.append(child); continue }
                walk(child, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return found
    }

    /// The buttons in one bar, bar → list → buttons on both macOS versions.
    private func buttons(in bar: AXUIElement) -> [(frame: CGRect, title: String)] {
        for list in children(of: bar) {
            let found = children(of: list).compactMap { b in frame(of: b).map { ($0, title(of: b) ?? "") } }
            if !found.isEmpty { return found }
        }
        return []
    }

    /// macOS 27: a button's AX position is its thumbnail's centre, and the
    /// caption sits `captionOffset` below it (see there).
    ///
    /// With "Displays have separate Spaces" off, every display draws its own
    /// copy of the one Spaces Bar, but WindowManager exposes only the first
    /// display's to Accessibility. Measured 2026-09-28 on two 2560x1440
    /// displays, the other copy uses the same spacing and height and is always
    /// CENTRED on its own screen: the first display's bar shifts to follow the
    /// pointer (Desktop 1 at 1000 with the pointer there), while the second
    /// stayed centred (606 in a capture, 608 predicted). So each other screen
    /// gets the same layout, re-centred. Screens of different sizes are
    /// untested.
    private func windowManagerCaptions(in bar: AXUIElement, mirrorToOtherScreens mirror: Bool) -> [Caption] {
        let found = buttons(in: bar)
        let centres = found.map { CGPoint(x: $0.frame.minX, y: $0.frame.minY + Self.captionOffset) }
        var captions = match(found, centres: centres, fallbackWidth: found.first?.frame.width ?? 0)

        guard mirror, let first = centres.first, let last = centres.last,
              let source = screen(containingAX: first) else { return captions }
        let layoutMid = (first.x + last.x) / 2
        for target in NSScreen.screens where target != source {
            let dx = axFrame(of: target).midX - layoutMid
            let dy = axFrame(of: target).minY - axFrame(of: source).minY
            let moved = centres.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            captions += match(found, centres: moved, fallbackWidth: found.first?.frame.width ?? 0)
        }
        return captions
    }

    /// True when "Displays have separate Spaces" is off: CGS then reports a
    /// single display carrying every space.
    private static func displaysShareSpaces() -> Bool {
        let conn = CGSMainConnectionID()
        return (CGSCopyManagedDisplaySpaces(conn) as? [[String: Any]])?.count == 1
    }

    private func screen(containingAX p: CGPoint) -> NSScreen? {
        NSScreen.screens.first { axFrame(of: $0).contains(p) }
    }

    /// A screen's frame in AX coordinates (origin at the primary display's top left).
    private func axFrame(of screen: NSScreen) -> CGRect {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let f = screen.frame
        return CGRect(x: f.minX, y: primaryTop - f.maxY, width: f.width, height: f.height)
    }

    /// macOS 26 and earlier, as MacSpaceLabeler has it: the frame is a real
    /// top-left frame and the caption sits just below it. Untested here.
    private func dockCaptions(in bar: AXUIElement) -> [Caption] {
        let found = buttons(in: bar)
        let centres = found.map { CGPoint(x: $0.frame.midX, y: $0.frame.maxY + LabelWindow.height / 2) }
        return match(found, centres: centres, fallbackWidth: found.first?.frame.width ?? 0)
    }

    /// Pairs each button with a space UUID, and keeps the named ones. A
    /// label's widest is the distance to its nearest neighbour, less the gap.
    private func match(_ found: [(frame: CGRect, title: String)], centres: [CGPoint],
                       fallbackWidth: CGFloat) -> [Caption] {
        guard let first = centres.first else { return [] }
        let uuids = orderedSpaceUUIDs(onScreenContaining: appKitRect(fromAX: CGRect(origin: first, size: .zero)))
        guard uuids.count == found.count else {
            // Never guess a match: a label on the wrong desktop is worse than
            // none. A space being dragged, a plist not yet written, or a new AX
            // shape all land here.
            let message = "\(found.count) thumbnails but \(uuids.count) spaces, not labelling this bar"
            if message != lastMismatch { aslog("MissionControlLabels: \(message)") }
            lastMismatch = message
            return []
        }

        let names = SpaceNames.shared
        return centres.indices.compactMap { i in
            guard let name = names.name(for: uuids[i]) else { return nil }
            let neighbours = [i - 1, i + 1].filter(centres.indices.contains).map { abs(centres[$0].x - centres[i].x) }
            let width = (neighbours.min() ?? fallbackWidth) - Self.labelGap
            return Caption(centre: centres[i], maxWidth: width, covers: found[i].title, name: name)
        }
    }

    // MARK: - Spaces, in the order Mission Control shows them

    /// Every space on the display that contains `rect`, full-screen ones
    /// included (they have thumbnails too), in visual order.
    private func orderedSpaceUUIDs(onScreenContaining rect: CGRect) -> [String] {
        let conn = CGSMainConnectionID()
        guard let displays = CGSCopyManagedDisplaySpaces(conn) as? [[String: Any]] else { return [] }

        let midpoint = CGPoint(x: rect.midX, y: rect.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(midpoint) }
        let screenUUID = screen.flatMap(Self.displayUUID(of:))

        // One entry means "Displays have separate Spaces" is off, or there is
        // one display: CGS then reports a single "Main" display.
        let display = displays.count == 1
            ? displays.first
            : displays.first { ($0["Display Identifier"] as? String) == screenUUID }
        guard let display, let spaces = display["Spaces"] as? [[String: Any]] else { return [] }

        let cgsOrder = spaces.compactMap { $0["uuid"] as? String }
        return Self.visualOrder(of: cgsOrder)
    }

    private static func displayUUID(of screen: NSScreen) -> String? {
        guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(n.uint32Value))?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    /// CGS can list spaces in creation order; the spaces plist has the order on
    /// screen. Same approach as SpaceObserver.readVisualOrder, but keeping every
    /// type, because Mission Control shows a thumbnail for full-screen spaces.
    private static func visualOrder(of uuids: [String]) -> [String] {
        let path = ("~/Library/Preferences/com.apple.spaces.plist" as NSString).expandingTildeInPath
        guard let plist = NSDictionary(contentsOfFile: path) as? [String: Any],
              let config = plist["SpacesDisplayConfiguration"] as? [String: Any],
              let mgmt = config["Management Data"] as? [String: Any],
              let monitors = mgmt["Monitors"] as? [[String: Any]] else { return uuids }

        let wanted = Set(uuids)
        var best: [String] = []
        for monitor in monitors {
            let order = (monitor["Spaces"] as? [[String: Any]] ?? []).compactMap { $0["uuid"] as? String }
            if Set(order).intersection(wanted).count > Set(best).intersection(wanted).count {
                best = order
            }
        }
        // The plist lags CGS by a moment after a change. Only trust it when it
        // holds exactly the same spaces.
        return Set(best) == wanted && best.count == uuids.count ? best : uuids
    }

    // MARK: - Label windows

    private func show(_ captions: [Caption]) {
        while windows.count < captions.count { windows.append(LabelWindow()) }
        for (i, window) in windows.enumerated() {
            if i < captions.count {
                let c = captions[i]
                window.place(name: c.name, covering: c.covers, centredOn: appKitPoint(fromAX: c.centre),
                             maxWidth: c.maxWidth)
            } else if window.isVisible {
                window.orderOut(nil)
            }
        }
    }

    /// Only windows still on screen. This runs on every poll while Mission
    /// Control is closed, and ordering out a window that is already hidden
    /// still costs a window-server round trip: six of them per poll were 42 of
    /// 55 samples in a 20 s sample with Mission Control closed.
    private func hideAll() {
        for window in windows where window.isVisible { window.orderOut(nil) }
    }

    /// AX coordinates are global with the origin at the TOP left of the primary
    /// display (the one with the menu bar, `NSScreen.screens[0]`). AppKit's
    /// origin is at its BOTTOM left.
    private func appKitPoint(fromAX p: CGPoint) -> CGPoint {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: p.x, y: primaryTop - p.y)
    }

    private func appKitRect(fromAX r: CGRect) -> CGRect {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: r.minX, y: primaryTop - r.maxY, width: r.width, height: r.height)
    }

    // MARK: - AX helpers

    private func children(of el: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &value) == .success
        else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func title(of el: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private func identifier(of el: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXIdentifierAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    /// Nil unless both position and size come back, and the size is non-zero:
    /// AX reports phantom elements at 0x0 rather than failing.
    private func frame(of el: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        guard size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: pos, size: size)
    }
}

/// One name, drawn over one Mission Control caption. Click-through, on every
/// space, above Mission Control.
private final class LabelWindow: NSWindow {

    private let field = NSTextField(labelWithString: "")

    /// Space between the text and the edge of its dark backing. The horizontal
    /// part is added to the box's width; see `place` for why the field fills it.
    private static let padding = NSSize(width: 6, height: 2)

    /// The standard system size, which is larger than either caption size
    /// Mission Control uses (its "Desktop 1" measured 60 pt wide collapsed and
    /// 53 pt expanded), so a label sized to cover that text in this font covers
    /// it in both states.
    private static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)

    static var height: CGFloat {
        ceil(font.ascender - font.descender + font.leading) + padding.height * 2
    }

    init() {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        // Mission Control draws above normal and floating windows. One level
        // above the screensaver is where MacSpaceLabeler's labels showed.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let backing = NSView()
        backing.wantsLayer = true
        // Opaque. MacSpaceLabeler's 85% black let the caption underneath show
        // through: its dark glyphs read clearly against the box in a capture
        // on 2026-09-28, "D" and "2" either side of "Docker".
        backing.layer?.backgroundColor = NSColor.black.cgColor
        backing.layer?.cornerRadius = 4
        contentView = backing

        field.font = Self.font
        field.textColor = .white
        field.alignment = .center
        field.lineBreakMode = .byTruncatingTail
        backing.addSubview(field)
    }

    /// Sizes the label to its name, but never narrower than `covers`, the
    /// caption it has to hide, nor wider than `maxWidth`, and centres it on
    /// `centre` (AppKit coordinates).
    func place(name: String, covering covers: String, centredOn centre: CGPoint, maxWidth: CGFloat) {
        field.stringValue = name
        // The field's own width, not the bare string's: a text field pads its
        // text by a few points, and sizing from the string alone truncated
        // "Workspace" with 188 pt to spare. The caption is measured the same
        // way by adding that padding to its string width.
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font]
        let nameWidth = field.intrinsicContentSize.width
        let fieldPadding = nameWidth - (name as NSString).size(withAttributes: attrs).width
        let coversWidth = (covers as NSString).size(withAttributes: attrs).width + fieldPadding
        let width = min(ceil(max(nameWidth, coversWidth)) + Self.padding.width * 2, maxWidth)
        let height = Self.height
        let frame = CGRect(x: centre.x - width / 2, y: centre.y - height / 2, width: width, height: height)
        guard frame != self.frame || !isVisible else {
            orderFrontRegardless()
            return
        }
        // The field spans the whole box, so the side padding is slack inside
        // it rather than a margin outside. A field exactly as wide as its own
        // intrinsicContentSize still truncates when drawn: "Workspace",
        // intrinsic 71 pt in a 71 pt field, drew as "Workspa…" with 188 pt
        // free, measured 2026-09-28. Centred alignment keeps the text in the
        // middle either way.
        field.frame = CGRect(x: 0, y: Self.padding.height,
                             width: width, height: height - Self.padding.height * 2)
        setFrame(frame, display: true)
        orderFrontRegardless()
    }
}
