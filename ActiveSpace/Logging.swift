import Foundation

/// Diagnostic logging is gated behind the `ActiveSpace.debugLogging` UserDefault.
/// **Default is ON** — the log is small, the file is overwritten on every launch,
/// and having logs already in place when a drift event happens means we don't
/// have to ask the user to reproduce. Explicitly opt out with:
///
///   defaults write cc.jorviksoftware.ActiveSpace ActiveSpace.debugLogging -bool NO
///
/// Then relaunch. The flag is read once at launch for speed; toggling at
/// runtime has no effect until the next process start.
private let debugLoggingEnabled: Bool = {
    // `object(forKey:)` distinguishes "unset" from "explicitly false". Unset
    // → on; explicit YES/NO → honour the user's choice.
    if let v = UserDefaults.standard.object(forKey: "ActiveSpace.debugLogging") as? Bool {
        return v
    }
    return true
}()

private let logFile: FileHandle? = {
    guard debugLoggingEnabled else { return nil }
    let path = "/tmp/activespace.log"
    FileManager.default.createFile(atPath: path, contents: nil)
    return FileHandle(forWritingAtPath: path)
}()

private let timestampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
}()

func aslog(_ msg: String) {
    guard debugLoggingEnabled, let logFile else { return }
    let line = "\(timestampFormatter.string(from: Date()))  \(msg)\n"
    logFile.seekToEndOfFile()
    if let data = line.data(using: .utf8) {
        logFile.write(data)
    }
}

/// C-callable bridge so VirtualDisplayHelper.m can write to the same file.
@_cdecl("ActiveSpaceLogC")
public func ActiveSpaceLogC(_ cstr: UnsafePointer<CChar>) {
    aslog(String(cString: cstr))
}
