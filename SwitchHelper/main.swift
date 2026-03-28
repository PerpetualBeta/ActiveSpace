// Standalone helper: called with a 1-based space index, switches to that space.
// Runs as a plain Unix process (no NSApplication), same context as the test
// scripts that confirmed CGSManagedDisplaySetCurrentSpace works.
import Foundation
import CoreGraphics

typealias CGSConnectionID = UInt32

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ conn: CGSConnectionID) -> CFArray

typealias SetSpaceFn = @convention(c) (CGSConnectionID, CFString, Int) -> OSStatus

guard CommandLine.arguments.count > 1,
      let targetIndex = Int(CommandLine.arguments[1]),
      targetIndex >= 1 else {
    fputs("Usage: switch_helper <1-based-space-index>\n", stderr)
    exit(1)
}

let conn = CGSMainConnectionID()
guard let displays = CGSCopyManagedDisplaySpaces(conn) as? [[String: Any]] else {
    fputs("CGSCopyManagedDisplaySpaces failed\n", stderr)
    exit(2)
}

// Collect all spaces in order across displays, filtering to type=0 (regular desktops only).
struct SpaceEntry { let displayID: String; let managedSpaceID: Int }
var spaces: [SpaceEntry] = []
for display in displays {
    guard let displayID = display["Display Identifier"] as? String,
          let rawSpaces = display["Spaces"] as? [[String: Any]] else { continue }
    for s in rawSpaces {
        guard let id = s["ManagedSpaceID"] as? Int else { continue }
        spaces.append(SpaceEntry(displayID: displayID, managedSpaceID: id))
    }
}

guard targetIndex <= spaces.count else {
    fputs("Index \(targetIndex) out of range (have \(spaces.count) spaces)\n", stderr)
    exit(3)
}

let target = spaces[targetIndex - 1]
if let sym = dlsym(dlopen(nil, RTLD_LAZY), "CGSManagedDisplaySetCurrentSpace") {
    let fn = unsafeBitCast(sym, to: SetSpaceFn.self)
    let r = fn(conn, target.displayID as CFString, target.managedSpaceID)
    exit(r == 0 ? 0 : 4)
}
exit(5)
