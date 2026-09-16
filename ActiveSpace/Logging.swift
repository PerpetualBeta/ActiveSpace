import Foundation

/// Diagnostic logging is gated behind the `ActiveSpace.debugLogging` UserDefault.
/// **Default is OFF** — the drift / virtual-display path has been stable since
/// 2026-05-21 and the running log is no longer earning its keep. Explicitly
/// opt in with:
///
///   defaults write cc.jorviksoftware.ActiveSpace ActiveSpace.debugLogging -bool YES
///
/// Writes to ~/Library/Logs/ActiveSpace/debug.log.
///
/// Then relaunch. The flag is read once at launch for speed; toggling at
/// runtime has no effect until the next process start.
private let debugLoggingEnabled: Bool =
    UserDefaults.standard.bool(forKey: "ActiveSpace.debugLogging")

private let logFile: FileHandle? = {
    guard debugLoggingEnabled else { return nil }
    // O_APPEND so every write atomically seeks to EOF. Required because
    // VirtualDisplayHost (our child process) inherits this file as its
    // stderr via process.standardError and writes through a different
    // FD; without O_APPEND on both sides the two processes' writes race
    // and clobber each other during the helper's startup burst.
    // O_TRUNC starts each app launch with an empty log.
    //
    // ~/Library/Logs/ActiveSpace/, not /tmp: a world-writable directory is the
    // wrong home for anything, and parallel agent jobs share /tmp and clobber
    // each other's files. Moved 2026-09-15.
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ActiveSpace", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("debug.log").path
    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0o644)
    guard fd >= 0 else { return nil }
    return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
}()

private let timestampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
}()

/// Whether diagnostic logging is on, for callers that want to skip expensive
/// work rather than just skip the write.
var debugLoggingIsOn: Bool { debugLoggingEnabled }

func aslog(_ msg: String) {
    guard debugLoggingEnabled, let logFile else { return }
    let line = "\(timestampFormatter.string(from: Date()))  \(msg)\n"
    if let data = line.data(using: .utf8) {
        logFile.write(data)
    }
}
