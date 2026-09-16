"""Only create the event tap when something actually needs it.

Jonathan: "No point asking for it if it is not needed."

The tap is the only reason ActiveSpace wants Input Monitoring. It was created
unconditionally at launch, so a user who just wants the menu-bar indicator and
the popover was asked for a permission nothing would use. Since this morning it
serves less than it did: Previous and Next Space are gone, leaving Space Up and
Space Down in grid mode, Follow App Across Spaces, and the space-aware
Command-Tab.

So create it when one of those is actually configured, tear it down when the
last one is switched off, and re-evaluate whenever the settings change.
"""
import pathlib

p = pathlib.Path("ActiveSpace/AppDelegate.swift")
t = p.read_text()

# 1. A predicate, a teardown, and a single entry point that decides.
old = """    private func setupEventTap() {
        guard _eventTap == nil else { return }
"""
new = """    /// Does anything still need the keyboard tap?
    ///
    /// The tap is the only reason this app asks for Input Monitoring, so the
    /// honest thing is to want it only when a feature uses it. Since the macOS
    /// 27 rework that means: the space-aware Command-Tab, the grid's Space Up
    /// and Space Down, or Follow App Across Spaces. Previous and Next Space used
    /// to be here too; they are macOS's own shortcuts now.
    private var needsEventTap: Bool {
        if switcherEnabled { return true }
        if followKeyCode != 0 { return true }
        if rowWidth >= 2 && (upKeyCode != 0 || downKeyCode != 0) { return true }
        return false
    }

    /// Create or destroy the tap to match what is configured. Safe to call as
    /// often as you like; it only acts on a change.
    func updateEventTap() {
        if needsEventTap {
            setupEventTap()
        } else if _eventTap != nil {
            teardownEventTap()
        }
    }

    private func teardownEventTap() {
        guard let tap = _eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        _eventTap = nil
        aslog("event tap torn down — nothing configured needs it, so Input Monitoring is not required")
    }

    private func setupEventTap() {
        guard _eventTap == nil else { return }
"""
assert old in t
t = t.replace(old, new, 1)

# 2. Launch goes through the decision rather than creating unconditionally.
old = "        setupEventTap()\n"
new = "        updateEventTap()\n"
assert old in t
t = t.replace(old, new, 1)

# 3. Re-evaluate when the settings that matter change.
old = "    func saveShortcuts() {"
new = """    /// Called after any shortcut changes: a binding cleared may have been the
    /// last thing keeping the tap alive.
    func saveShortcuts() {
        defer { updateEventTap() }"""
assert old in t
t = t.replace(old, new, 1)

old = "    func saveSwitcherEnabled() {"
new = """    func saveSwitcherEnabled() {
        defer { updateEventTap() }"""
assert old in t
t = t.replace(old, new, 1)

# 4. rowWidth gates the up/down hotkeys, so it changes the answer too.
old = "    var rowWidth: Int = 0 { didSet { _rowWidth = rowWidth } }"
new = "    var rowWidth: Int = 0 { didSet { _rowWidth = rowWidth; updateEventTap() } }"
assert old in t
t = t.replace(old, new, 1)

p.write_text(t)
print("event tap is now created only when something needs it")
