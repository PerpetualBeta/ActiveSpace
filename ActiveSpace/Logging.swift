import Foundation

/// Diagnostic logging is gated behind the `ActiveSpace.debugLogging` UserDefault.
/// **Default is OFF** — the drift path has been stable since 2026-05-21 and the
/// running log is no longer earning its keep. Explicitly opt in with:
///
///   defaults write cc.jorviksoftware.ActiveSpace ActiveSpace.debugLogging -bool YES
///
/// Writes to ~/Library/Logs/ActiveSpace/debug.log.
///
/// Then relaunch. The flag is read once at launch for speed; toggling at
/// runtime has no effect until the next process start.
private let debugLoggingEnabled: Bool =
    UserDefaults.standard.bool(forKey: "ActiveSpace.debugLogging")

private let logDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/ActiveSpace", isDirectory: true)
private let logURL = logDirectory.appendingPathComponent("debug.log")
private let previousLogURL = logDirectory.appendingPathComponent("debug.log.1")

/// Rotate once the live log passes this many bytes, keeping one previous
/// generation, so the most it can occupy is twice this figure. 4 MB by
/// default, the estate convention; a long debugging session may want more:
///
///   defaults write cc.jorviksoftware.ActiveSpace debugLogMaxBytes -int 20971520
private var logMaximumBytes: Int {
    let stored = UserDefaults.standard.integer(forKey: "debugLogMaxBytes")
    return stored > 0 ? stored : 4 * 1024 * 1024
}

/// The log is kept across launches. It used to be truncated at every launch
/// (`O_TRUNC`), which wiped the evidence whenever the app relaunched, and an
/// update install relaunches it: exactly when the Sparkle session it was
/// recording had just ended. Rotation bounds the size instead.
///
/// Opened `O_APPEND`, so every write lands at the end whoever else may hold
/// the file. When this app spawned a helper that wrote here too, two
/// descriptors with their own offsets clobbered each other without it. That
/// helper went with the virtual display in the macOS 27 rework and this app
/// is the only writer now; the flag stays because it is the correct way to
/// open a log and costs nothing.
///
/// ~/Library/Logs/ActiveSpace/, not /tmp: a world-writable directory is the
/// wrong home for anything, and parallel agent jobs share /tmp and clobber
/// each other's files. Moved 2026-09-15.
private func openLog() -> FileHandle? {
    try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
    let fd = open(logURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    guard fd >= 0 else { return nil }
    return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
}

/// Guarded by `logLock`; rotation replaces it.
nonisolated(unsafe) private var logFile: FileHandle? = debugLoggingEnabled ? openLog() : nil
private let logLock = NSLock()

private let timestampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
}()

/// Whether diagnostic logging is on, for callers that want to skip expensive
/// work rather than just skip the write.
var debugLoggingIsOn: Bool { debugLoggingEnabled }

func aslog(_ msg: String) {
    guard debugLoggingEnabled else { return }
    let line = "\(timestampFormatter.string(from: Date()))  \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }
    logLock.lock()
    defer { logLock.unlock() }
    guard let handle = logFile else { return }
    handle.write(data)
    rotateIfTooBig(handle)
}

/// Called with `logLock` held.
private func rotateIfTooBig(_ handle: FileHandle) {
    var info = stat()
    guard fstat(handle.fileDescriptor, &info) == 0, info.st_size >= logMaximumBytes else { return }
    logFile = nil
    try? FileManager.default.removeItem(at: previousLogURL)
    try? FileManager.default.moveItem(at: logURL, to: previousLogURL)
    logFile = openLog()
    let note = "\(timestampFormatter.string(from: Date()))  log rotated at \(info.st_size) bytes; the run before this is in debug.log.1\n"
    if let data = note.data(using: .utf8) { logFile?.write(data) }
}
