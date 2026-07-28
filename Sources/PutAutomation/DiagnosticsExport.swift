import Foundation
import OSLog
import PutCore
import PutStorage

public enum DiagnosticsExportError: Error, Equatable {
    case destinationExists(URL)
    case writeFailed(String)
}

/// Gathers a sanitised diagnostic bundle: the current config with sensitive
/// fields scrubbed, the rolling file log, and a snapshot of versions. Output
/// is a zip placed alongside the `destination` directory for the user to
/// attach to a bug report.
public enum DiagnosticsExport {
    private static let log: Logger = PutLog.logger(category: "diagnostics")

    public static func build(
        config: Config,
        destinationDirectory: URL,
        bundleVersion: String,
        includeFullLogs: Bool = false) async throws -> URL
    {
        let fileManager = FileManager.default
        // Millisecond-precision suffix so two exports in the same second
        // produce distinct directories rather than clashing on the old
        // second-resolution stamp.
        let now = Date()
        let isoStamp = ISO8601DateFormatter().string(from: now)
            .replacingOccurrences(of: ":", with: "-")
        let millis = Int(now.timeIntervalSince1970 * 1000) % 1000
        let stamp = "\(isoStamp)-\(String(format: "%03d", millis))"
        let workdir = destinationDirectory.appendingPathComponent("put-diagnostics-\(stamp)", isDirectory: true)
        if fileManager.fileExists(atPath: workdir.path) {
            throw DiagnosticsExportError.destinationExists(workdir)
        }
        try fileManager.createDirectory(at: workdir, withIntermediateDirectories: true)

        // Sanitised config.
        let sanitised = sanitise(config)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Match `ConfigStore`'s ISO 8601 date encoding so diagnostics show
        // dates in the same human-readable form a user would see on disk.
        encoder.dateEncodingStrategy = .iso8601
        let configData = try encoder.encode(sanitised)
        try configData.write(to: workdir.appendingPathComponent("config.json"))

        // Environment summary.
        let envSummary = """
        Put version: \(bundleVersion)
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Generated: \(Date())
        Logs: \(includeFullLogs ? "full (user opted in)" : "redacted")
        """
        try envSummary.data(using: .utf8)?.write(to: workdir.appendingPathComponent("environment.txt"))

        // Copy the rolling log if present. When the user hasn't opted in to
        // raw logs, run each line through a redactor that scrubs window
        // titles and filesystem paths so the export stays sharable.
        let sidecar = PutLog.sidecarURL
        if fileManager.fileExists(atPath: sidecar.path) {
            let destination = workdir.appendingPathComponent("put.log")
            if includeFullLogs {
                try fileManager.copyItem(at: sidecar, to: destination)
            } else {
                try redactLog(at: sidecar, to: destination)
            }
        }

        // Zip the directory.
        let zipURL = destinationDirectory.appendingPathComponent("put-diagnostics-\(stamp).zip")
        try zip(directory: workdir, to: zipURL)
        try? fileManager.removeItem(at: workdir)
        log.info("Diagnostics written to \(zipURL.path, privacy: .public)")
        return zipURL
    }

    // MARK: - Private

    /// Strip or redact fields that might identify the user's files, windows,
    /// or rule names. The intent is to keep the shape of the config while
    /// removing anything personally identifying. Internal (not private) so the
    /// redaction can be asserted directly in tests.
    static func sanitise(_ config: Config) -> Config {
        var sanitised = config
        sanitised.layouts = sanitised.layouts.map { layout in
            var copy = layout
            copy.name = "layout-\(copy.id.uuidString.prefix(8))"
            copy.rules = copy.rules.map { rule in
                var sanitisedRule = rule
                sanitisedRule.descriptiveLabel = "rule-\(sanitisedRule.id.uuidString.prefix(8))"
                sanitisedRule.matchCriteria.titlePattern = "<redacted>"
                // `NSScreen.localizedName` for Sidecar/AirPlay targets often
                // embeds the owner's name (for example "Sam's iPad"), so drop
                // it from the exported config.
                sanitisedRule.targetDisplay.localizedName = nil
                return sanitisedRule
            }
            copy.screenConfigs = copy.screenConfigs.map { screenConfig in
                var sanitisedConfig = screenConfig
                sanitisedConfig.displays = sanitisedConfig.displays.map { display in
                    var sanitisedDisplay = display
                    sanitisedDisplay.localizedName = nil
                    return sanitisedDisplay
                }
                return sanitisedConfig
            }
            return copy
        }
        return sanitised
    }

    /// Copy the log file line-by-line, replacing the values of any JSON
    /// `"title"` keys and filesystem-looking paths with `<redacted>`. Leaves
    /// structured fields like bundle IDs and metrics intact so the log is
    /// still useful for diagnosing placement issues.
    private static func redactLog(at source: URL, to destination: URL) throws {
        let raw = try String(contentsOf: source, encoding: .utf8)
        var redactedLines: [String] = []
        redactedLines.reserveCapacity(raw.split(separator: "\n").count)
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            redactedLines.append(redact(String(line)))
        }
        let joined = redactedLines.joined(separator: "\n")
        try joined.data(using: .utf8)?.write(to: destination)
    }

    private static let titleValueRegex: NSRegularExpression = {
        // Match "title":"...anything non-escaped quote..." with lazy inner.
        let pattern = #""title"\s*:\s*"(?:[^"\\]|\\.)*""#
        do {
            return try NSRegularExpression(pattern: pattern, options: [])
        } catch {
            // Pattern is a source literal, so a compile failure is a
            // programmer error caught on first launch in development.
            preconditionFailure("Invalid titleValueRegex pattern: \(error)")
        }
    }()

    private static let pathRegex: NSRegularExpression = {
        // Unix-style paths: /Users/..., /Applications/..., /Library/..., /Volumes/...
        let pattern = #"/(Users|Applications|Library|Volumes|private)/[^\s"']*"#
        do {
            return try NSRegularExpression(pattern: pattern, options: [])
        } catch {
            // Pattern is a source literal, so a compile failure is a
            // programmer error caught on first launch in development.
            preconditionFailure("Invalid pathRegex pattern: \(error)")
        }
    }()

    private static func redact(_ line: String) -> String {
        var result = line
        let range = NSRange(result.startIndex..<result.endIndex, in: result)
        result = titleValueRegex.stringByReplacingMatches(
            in: result,
            options: [],
            range: range,
            withTemplate: #""title":"<redacted>""#)
        let range2 = NSRange(result.startIndex..<result.endIndex, in: result)
        result = pathRegex.stringByReplacingMatches(
            in: result,
            options: [],
            range: range2,
            withTemplate: "<redacted-path>")
        return result
    }

    private static func zip(directory: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", directory.path, destination.path]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderr = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw DiagnosticsExportError.writeFailed("ditto exited \(process.terminationStatus): \(stderr)")
        }
    }
}
