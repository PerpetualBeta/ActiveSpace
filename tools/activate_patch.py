"""Test whether activating an accessory app is what loses the menu bar.

Jonathan confirms the bar goes when he clicks a space in the popover, and both
logs agree. The popover path does something the bare keystroke does not:
`NSApp.activate(ignoringOtherApps: true)` on an app that owns no menu bar.

This probe is also an accessory app (LSUIElement), so it can reproduce those
conditions with ActiveSpace uninvolved. A/B in one run, same target both times:

  A. post the key with no activation   — the control, known good from ten runs
  B. activate first, then post the key — the popover's sequence

If B loses the bar and A does not, the activation is the cause and the fix
belongs in how the popover hands over, not in the switching.
"""
import pathlib

p = pathlib.Path("tools/spaceprobe/main.swift")
t = p.read_text()

old = 'case "watch":'
new = '''case "activation":
    guard let s0 = readSpaces() else { exit(1) }
    say("Does activating an accessory app lose the menu bar when a space changes?")
    say("This app is LSUIElement, same as ActiveSpace, so it owns no menu bar either.")
    say("")

    func watchBar(_ label: String, seconds: Double = 5.0, action: () -> Void) {
        let before = menuBarIsVisible()
        say("  \\(label):")
        say("     bar before: \\(before ? "visible" : "GONE")")
        action()
        var elapsed = 0.0
        var goneAt: Double? = nil
        var backAt: Double? = nil
        while elapsed < seconds {
            settle(0.1)
            elapsed += 0.1
            let v = menuBarIsVisible()
            if !v && goneAt == nil { goneAt = elapsed }
            if v, goneAt != nil, backAt == nil { backAt = elapsed }
        }
        if let g = goneAt {
            let b = backAt.map { String(format: "back after %.1fs", $0 - g) } ?? "STILL GONE"
            say(String(format: "     bar GONE at %.1fs, %@", g, b))
        } else {
            say("     bar stayed up")
        }
        say("     now on space \\(readSpaces()?.currentIndex ?? -1)")
    }

    // A. the control: just the keystroke.
    if let s = readSpaces() {
        let target = (s.currentIndex % s.total) + 1
        if let b = readBinding(id: 118 + target - 1), b.enabled {
            watchBar("A. keystroke only, no activation") { postBinding(b) }
        }
    }
    say("")

    // B. the popover's sequence: activate, pause as a human would, then switch.
    if let s = readSpaces() {
        let target = (s.currentIndex % s.total) + 1
        if let b = readBinding(id: 118 + target - 1), b.enabled {
            watchBar("B. activate this accessory app, then the same keystroke") {
                NSApp.activate(ignoringOtherApps: true)
                usleep(800_000)
                postBinding(b)
            }
        }
    }
    say("")
    say("If B lost the bar and A did not, activation is the cause.")
    say("Started on space \\(s0.currentIndex), finished on \\(readSpaces()?.currentIndex ?? -1).")

case "watch":'''
assert old in t
t = t.replace(old, new, 1)
t = t.replace('mode == "defer" || mode == "menubar"', 'mode == "defer" || mode == "menubar" || mode == "activation"')
p.write_text(t)
print("activation A/B added")
