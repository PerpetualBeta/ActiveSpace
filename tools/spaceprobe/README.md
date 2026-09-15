# spaceprobe

Answers one question: **which space-switching mechanism actually works on this
version of macOS?**

It exists because macOS 27 silently stopped acting on the synthetic dock-swipe
ActiveSpace posts. Nothing errored. `CGEventPost` returns no status, so the app
logged a successful-looking switch every time while the desktop did not move.

## Build

```
swiftc -O -framework AppKit -framework ApplicationServices main.swift -o spaceprobe
codesign --force --options runtime --timestamp \
         --identifier cc.jorviksoftware.spaceprobe \
         --sign "Developer ID Application: Jonthan Hollin (EG86BCGUE7)" spaceprobe
```

Sign it. A Developer ID signature with a fixed identifier is what lets an
Accessibility grant stick to the binary across rebuilds.

## Use

```
./spaceprobe report        # read-only: OS, trust, screen count, space list
./spaceprobe windows       # what is on the CURRENT space right now
./spaceprobe legacy        # began+ended with no gap (what shipped before)
./spaceprobe paced [ms] [changedPhase]   # began, changed, ended, paced
./spaceprobe direct        # CGS call only
./spaceprobe direct-full   # CGS call plus both SkyLight calls
./spaceprobe all           # legacy then paced, then walks back
```

## Two things it gets right, and both matter

**It scores by the on-screen window set, not the space number.** The failing
case moves the number. `CGWindowListCopyWindowInfo` with `optionOnScreenOnly`
reports the current space only, so if the desk really moved the set must change
too. Reading the counter alone records a pass where there was none.

**It refuses to run the gesture modes without Accessibility.** A permission
refusal and a dead mechanism look identical from outside. Recording the first as
the second would be a false negative, and the whole point of the probe is to
stop guessing.

## Do not run `direct` on a multi-display setup

Measured 2026-09-15: the counter moves and the windows do not follow. macOS then
gives focus to an app whose windows are on the other space, and there is nothing
on screen to click. It strands the session. `killall Dock` recovers it. The
`all` mode deliberately excludes the direct path for this reason.

## Results, macOS 27.0 (26A428)

| mechanism | one display | two displays |
| --- | --- | --- |
| legacy gesture | dead | dead |
| direct | works | counter moves, windows do not |
| direct plus SkyLight | works | same, both calls return 0 |
| paced gesture | not yet tested, needs the grant | not yet tested |

The two-display column was measured with the built-in display plus ActiveSpace's
own virtual display. Whether two **real** displays behave the same is untested,
and no command can fake a second monitor. It needs the cable.
