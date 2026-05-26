import Foundation

/// Diagnostic logging is gated behind the `ActiveSpace.debugLogging` UserDefault.
/// **Default is OFF** — the drift / virtual-display path has been stable since
/// 2026-05-21 and the running log is no longer earning its keep. Explicitly
/// opt in with:
///
///   defaults write cc.jorviksoftware.ActiveSpace ActiveSpace.debugLogging -bool YES
///
/// Then relaunch. The flag is read once at launch for speed; toggling at
/// runtime has no effect until the next process start.
private let debugLoggingEnabled: Bool =
    UserDefaults.standard.bool(forKey: "ActiveSpace.debugLogging")

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
