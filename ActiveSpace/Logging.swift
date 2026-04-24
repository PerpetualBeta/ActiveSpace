import Foundation

/// Diagnostic logging is gated behind the `ActiveSpace.debugLogging` UserDefault.
/// Release builds ship with the flag unset (default false) so nothing is written
/// to disk. Users can enable it for support/debugging with:
///
///   defaults write cc.jorviksoftware.ActiveSpace ActiveSpace.debugLogging -bool YES
///
/// Then relaunch ActiveSpace. Disable again with `-bool NO` (or `defaults delete`)
/// plus another relaunch. The flag is read once at launch for speed; toggling at
/// runtime has no effect until the next process start.
private let debugLoggingEnabled: Bool = {
    UserDefaults.standard.bool(forKey: "ActiveSpace.debugLogging")
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
