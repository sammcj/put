import Foundation
import OSLog
import PutCore

public enum SettingsBackupError: Error, Equatable {
    case unreadable(String)
    case malformed(String)
    case unsupportedFormatVersion(found: Int, supported: Int)
    case unsupportedConfigSchema(found: Int, supported: Int)
    case writeFailed(String)
}

/// Portable, restorable backup of every Put setting.
///
/// The whole `Config` is embedded verbatim rather than a hand-picked subset of
/// fields, so any setting added to `Config` in future is captured by the backup
/// automatically with no change here. The only settings that live outside
/// `Config` are the `KeyboardShortcuts` key bindings (the package stores them in
/// `UserDefaults`); those are carried in `shortcuts`, keyed by the shortcut
/// `Name`'s raw value. They're captured/applied at the app layer because
/// `PutAutomation` doesn't depend on the `KeyboardShortcuts` package — see
/// `ShortcutsBackup` in `PutHotkeys`.
public struct SettingsBackup: Codable, Sendable {
    /// Envelope version, independent of `Config.schemaVersion`. Bump only when
    /// the backup wrapper shape changes incompatibly.
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var appVersion: String
    public var exportedAt: Date
    public var config: Config
    public var shortcuts: [String: String]

    public init(
        formatVersion: Int = SettingsBackup.currentFormatVersion,
        appVersion: String,
        exportedAt: Date,
        config: Config,
        shortcuts: [String: String])
    {
        self.formatVersion = formatVersion
        self.appVersion = appVersion
        self.exportedAt = exportedAt
        self.config = config
        self.shortcuts = shortcuts
    }
}

/// Encode/decode and read/write a `SettingsBackup` as a single JSON file.
/// Uses the same JSON strategy as `ConfigStore` so the embedded config matches
/// the on-disk form a user would recognise.
public enum SettingsBackupArchive {
    private static let log: Logger = PutLog.logger(category: "backup")

    /// Default save-panel filename for an export, e.g.
    /// `put-settings-2026-05-27T01-02-03Z.json`.
    public static func suggestedFilename(now: Date = Date()) -> String {
        let stamp = ISO8601DateFormatter().string(from: now)
            .replacingOccurrences(of: ":", with: "-")
        return "put-settings-\(stamp).json"
    }

    public static func encode(_ backup: SettingsBackup) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(backup)
    }

    public static func decode(from data: Data) throws -> SettingsBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup: SettingsBackup
        do {
            backup = try decoder.decode(SettingsBackup.self, from: data)
        } catch {
            throw SettingsBackupError.malformed(error.localizedDescription)
        }
        guard backup.formatVersion <= SettingsBackup.currentFormatVersion else {
            throw SettingsBackupError.unsupportedFormatVersion(
                found: backup.formatVersion,
                supported: SettingsBackup.currentFormatVersion)
        }
        guard backup.config.schemaVersion <= putSchemaVersion else {
            throw SettingsBackupError.unsupportedConfigSchema(
                found: backup.config.schemaVersion,
                supported: putSchemaVersion)
        }
        return backup
    }

    public static func write(_ backup: SettingsBackup, to url: URL) throws {
        let data = try encode(backup)
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw SettingsBackupError.writeFailed(error.localizedDescription)
        }
        log.info("Settings backup written to \(url.path, privacy: .public)")
    }

    public static func read(from url: URL) throws -> SettingsBackup {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SettingsBackupError.unreadable(error.localizedDescription)
        }
        return try decode(from: data)
    }
}
