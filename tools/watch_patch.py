"""A continuous menu-bar watcher, independent of who switches the space.

The app's own watcher only runs after a switch ActiveSpace performed, so it
cannot see a disappearance during a switch the user made by hand — which is
exactly what happened at 09:33. This samples regardless, records every
transition with the space it happened on, and therefore can answer the question
that matters: does the bar go missing when ActiveSpace is not involved at all,
or even not running?
"""
import pathlib

p = pathlib.Path("tools/spaceprobe/main.swift")
t = p.read_text()

old = 'case "bar":'
new = '''case "watch":
    // Sample continuously and report every transition. Posts nothing and
    // switches nothing: whatever happens is the machine's own doing.
    let seconds = args.count > 1 ? (Double(args[1]) ?? 300) : 300
    say("Watching the menu bar for \\(Int(seconds))s. Nothing is being posted or switched.")
    say("Switch spaces however you normally would, including by hand.")
    var wasVisible = menuBarIsVisible()
    var lastSpace = readSpaces()?.currentIndex ?? -1
    say("  start: bar \\(wasVisible ? "visible" : "GONE"), space \\(lastSpace)")
    var elapsed = 0.0
    var events = 0
    var goneSince: Double? = nil
    while elapsed < seconds {
        settle(0.1)
        elapsed += 0.1
        let nowVisible = menuBarIsVisible()
        let nowSpace = readSpaces()?.currentIndex ?? -1

        if nowSpace != lastSpace {
            say(String(format: "  %6.1fs  space %d -> %d%@", elapsed, lastSpace, nowSpace,
                       nowVisible ? "" : "   (bar is GONE at this moment)"))
            lastSpace = nowSpace
        }
        if nowVisible != wasVisible {
            events += 1
            if nowVisible, let since = goneSince {
                say(String(format: "  %6.1fs  bar BACK after %.1fs, on space %d", elapsed, elapsed - since, nowSpace))
                goneSince = nil
            } else {
                say(String(format: "  %6.1fs  bar GONE, on space %d", elapsed, nowSpace))
                goneSince = elapsed
            }
            wasVisible = nowVisible
        }
    }
    say("")
    say("\\(events) visibility change(s) in \\(Int(seconds))s.")
    say(events == 0 ? "The bar never moved. Either it did not happen, or the detector missed it."
                    : "Compare the timestamps against ActiveSpace's log: if the bar went while that log shows no switchTo line, the app did not do it.")

case "bar":'''
assert old in t
t = t.replace(old, new, 1)
p.write_text(t)
print("continuous watch mode added")
