import Foundation

/// Appends timestamped lines to ~/Library/Logs/ActiveSpace.log so reconfiguration
/// events and self-restart decisions can be reviewed after the fact, independently
/// of any in-app UI.
enum ActiveSpaceLogger {

    private static let logURL: URL = {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("ActiveSpace.log")
    }()

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func log(_ line: String) {
        let stamped = "\(timestampFormatter.string(from: Date()))  \(line)\n"
        guard let data = stamped.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }

    static var logPath: String { logURL.path }
}
