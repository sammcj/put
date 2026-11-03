import Foundation
import PutCore

public enum DisplayDefaultsError: Error, Equatable, LocalizedError {
    case stored(StoredLayoutError)
    case commandFailed(String)
    /// The write finished but a re-read still shows pending changes.
    case notPersisted

    public var errorDescription: String? {
        switch self {
        case .stored(.unexpectedFormat):
            "macOS stores display settings in a format Put doesn't recognise. Nothing was changed."
        case .stored(.noStoredLayoutForCurrentDisplays):
            "macOS hasn't saved settings for the connected displays yet. Nothing was changed."
        case .stored(.mirroring):
            "Turn off display mirroring first. Nothing was changed."
        case .stored(.storedModeOutOfDate):
            "macOS hasn't saved the current resolution yet. Wait a moment and try again."
        case let .commandFailed(detail):
            "Couldn't set the default resolution: \(detail)"
        case .notPersisted:
            "macOS didn't keep the new default resolution."
        }
    }
}

/// Reads and writes the current user's stored display layouts. Blocks on
/// subprocesses, so call it off the main actor. `defaults` goes through
/// cfprefsd, which a direct edit of the plist file would bypass.
public enum DisplayDefaultsWriter {
    private static let log = PutLog.logger(category: "display.defaults")
    private static let defaultsTool = "/usr/bin/defaults"
    private static let domain = "com.apple.windowserver.displays"
    private static let setsKey = "DisplaySets"

    private struct Plan {
        let raw: Data
        let updatedPrefs: Data?
        let changed: Int
    }

    /// Counts the stored layouts `apply` would change, without writing.
    public static func preview(displays: [DisplayFingerprint], pinning: Set<UUID>) throws -> Int {
        try plan(displays: displays, pinning: pinning).changed
    }

    /// Writes the displays' current modes into every combination of the
    /// connected displays that includes them, backing up the store first.
    /// Returns how many stored layouts changed.
    @discardableResult
    public static func apply(displays: [DisplayFingerprint], pinning: Set<UUID>) throws -> Int {
        let plan = try plan(displays: displays, pinning: pinning)
        guard let prefs = plan.updatedPrefs else { return 0 }

        let folder = try backupFolder()
        try writePrivate(plan.raw, to: folder.appendingPathComponent("user-\(backupStamp()).plist"))
        try importPrefs(prefs, folder: folder)

        guard (try? self.plan(displays: displays, pinning: pinning).changed) == 0 else {
            throw DisplayDefaultsError.notPersisted
        }
        log.notice("Display defaults updated: \(plan.changed, privacy: .public) layouts")
        return plan.changed
    }

    // MARK: - Private

    private static func plan(displays: [DisplayFingerprint], pinning: Set<UUID>) throws -> Plan {
        let live = displays.compactMap(StoredDisplayLayouts.LiveDisplay.init)
        let pinned = Set(pinning.map(\.uuidString))
        do {
            let raw = try exportPrefs()
            let prefs = try parsed(raw)
            let configs = try configs(in: prefs)
            let current = try StoredDisplayLayouts.currentEntries(in: configs, displays: live, pinning: pinned)
            let update = try StoredDisplayLayouts.updating(configs, with: current, displays: live, pinning: pinned)
            let updated = update.changed > 0 ? try replacing(update.configs, in: prefs) : nil
            return Plan(raw: raw, updatedPrefs: updated, changed: update.changed)
        } catch let error as StoredLayoutError {
            throw DisplayDefaultsError.stored(error)
        }
    }

    private static func exportPrefs() throws -> Data {
        let result = try run(defaultsTool, ["-currentHost", "export", domain, "-"])
        guard result.status == 0 else { throw DisplayDefaultsError.commandFailed(result.stderr) }
        return result.stdout
    }

    private static func parsed(_ raw: Data) throws -> StoredDisplayLayouts.Plist {
        let plist = try? PropertyListSerialization.propertyList(from: raw, format: nil)
        guard let prefs = plist as? StoredDisplayLayouts.Plist else { throw StoredLayoutError.unexpectedFormat }
        return prefs
    }

    private static func configs(in prefs: StoredDisplayLayouts.Plist) throws -> [StoredDisplayLayouts.Plist] {
        let sets = prefs[setsKey] as? StoredDisplayLayouts.Plist
        guard let configs = sets?["Configs"] as? [StoredDisplayLayouts.Plist] else {
            throw StoredLayoutError.unexpectedFormat
        }
        return configs
    }

    private static func replacing(
        _ configs: [StoredDisplayLayouts.Plist],
        in prefs: StoredDisplayLayouts.Plist) throws -> Data
    {
        var updated = prefs
        var sets = prefs[setsKey] as? StoredDisplayLayouts.Plist ?? [:]
        sets["Configs"] = configs
        updated[setsKey] = sets
        return try PropertyListSerialization.data(fromPropertyList: updated, format: .binary, options: 0)
    }

    private static func importPrefs(_ prefs: Data, folder: URL) throws {
        let pending = folder.appendingPathComponent("user-pending.plist")
        try writePrivate(prefs, to: pending)
        defer { try? FileManager.default.removeItem(at: pending) }
        let result = try run(defaultsTool, ["-currentHost", "import", domain, pending.path])
        guard result.status == 0 else { throw DisplayDefaultsError.commandFailed(result.stderr) }
    }

    private static func backupFolder() throws -> URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Put", isDirectory: true)
            .appendingPathComponent("display-backups", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return folder
    }

    private static func backupStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private struct CommandResult {
        let status: Int32
        let stdout: Data
        let stderr: String
    }

    private static func run(_ tool: String, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        // Drain before waiting: an export can exceed the pipe buffer.
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(
            status: process.terminationStatus,
            stdout: stdout,
            stderr: String(bytes: stderr, encoding: .utf8) ?? "")
    }
}
