import Foundation
import OSLog

/// Logging facade. Wraps Apple unified logging with an optional rolling file
/// sidecar at `~/Library/Logs/Put/put.log`.
///
/// Usage:
///
///     let log = PutLog.logger(category: "display")
///     log.info("Enumerated \(count, privacy: .public) displays")
public enum PutLog {
    public static let subsystem = "net.smcleod.put"

    /// Returns a `Logger` for the given category. Logger values are cheap; no
    /// need to cache them.
    public static func logger(category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }

    /// Path to the rolling file sidecar. Directory is created on demand by
    /// `FileSink.start`.
    public static var sidecarURL: URL {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Put", isDirectory: true)
        return logs.appendingPathComponent("put.log", isDirectory: false)
    }
}
