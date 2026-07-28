import Foundation
import OSLog
import PutCore

public enum ConfigStoreError: Error, Equatable {
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case directoryCreationFailed(String)
    case atomicWriteFailed(String)
    case permissionAdjustmentFailed(String)
}

/// The filesystem operations `ConfigStore` performs, behind a seam so tests can
/// inject failures on the config-loss path without a real failing disk. Kept
/// internal so the public actor API is unchanged; the default implementation
/// wraps `FileManager`.
protocol ConfigFileStore: Sendable {
    func fileExists(atPath path: String) -> Bool
    func readData(from url: URL) throws -> Data
    func writeData(_ data: Data, to url: URL) throws
    func removeItem(at url: URL) throws
    func moveItem(at src: URL, to dst: URL) throws
    func copyItem(at src: URL, to dst: URL) throws
    @discardableResult
    func replaceItem(at dst: URL, withItemAt src: URL) throws -> URL?
    func createDirectory(at url: URL, permissions: Int) throws
    func setPermissions(_ permissions: Int, ofItemAtPath path: String) throws
}

/// FileManager-backed `ConfigFileStore`. `@unchecked Sendable`: it holds only a
/// FileManager, whose file operations used here are thread-safe.
final class FileManagerConfigFileStore: ConfigFileStore, @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func fileExists(atPath path: String) -> Bool {
        fileManager.fileExists(atPath: path)
    }

    func readData(from url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func writeData(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
    }

    func removeItem(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }

    func moveItem(at src: URL, to dst: URL) throws {
        try fileManager.moveItem(at: src, to: dst)
    }

    func copyItem(at src: URL, to dst: URL) throws {
        try fileManager.copyItem(at: src, to: dst)
    }

    @discardableResult
    func replaceItem(at dst: URL, withItemAt src: URL) throws -> URL? {
        try fileManager.replaceItemAt(dst, withItemAt: src)
    }

    func createDirectory(at url: URL, permissions: Int) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: permissions])
    }

    func setPermissions(_ permissions: Int, ofItemAtPath path: String) throws {
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
    }
}

/// Actor-isolated persistent config store.
///
/// - Reads and writes `~/Library/Application Support/Put/config.json` by
///   default, overridable for tests.
/// - Writes go to a sibling `.tmp` and are rename-replaced onto the live file,
///   giving an atomic swap even if the process is killed mid-write.
/// - A sibling `.backup` copy is snapshotted before the swap so `save` can roll
///   back and `load` can recover if the primary is lost.
/// - The config file is created with permissions `0600` and the containing
///   directory with `0700`.
/// - Decoding runs through `migrate(_:)` so future schema bumps can rewrite
///   older documents on load.
public actor ConfigStore {
    private let fileURL: URL
    private let log: Logger
    private let fileOps: ConfigFileStore

    public init(fileURL: URL = PutStorage.defaultConfigURL, fileManager: FileManager = .default) {
        self.init(fileURL: fileURL, fileOps: FileManagerConfigFileStore(fileManager: fileManager))
    }

    /// Internal seam-injecting initialiser used by tests to drive filesystem
    /// failures. Not public: the supported construction path is the public init.
    init(fileURL: URL, fileOps: ConfigFileStore) {
        self.fileURL = fileURL
        log = PutLog.logger(category: "storage")
        self.fileOps = fileOps
    }

    public var url: URL {
        fileURL
    }

    private var backupURL: URL {
        fileURL.appendingPathExtension("backup")
    }

    private var tempURL: URL {
        fileURL.appendingPathExtension("tmp")
    }

    // MARK: - Load

    /// Load the config from disk. If no file exists, or the file is corrupt
    /// (bad JSON, truncated, decode error), persist and return a freshly
    /// bootstrapped config. Corrupt files are moved aside for forensics
    /// rather than deleted.
    public func load() throws -> Config {
        if !fileOps.fileExists(atPath: fileURL.path) {
            // Primary is gone. A lingering `.backup` means a save was
            // interrupted after the snapshot but before the swap completed;
            // recover it before bootstrapping so an interrupted write does not
            // silently lose the user's config.
            if let recovered = try? decodeConfig(from: backupURL) {
                log.warning("Primary config missing; recovered from backup")
                try recoverFromBackup(recovered)
                return recovered
            }
            // A lingering `.tmp` is the completed-but-unswapped output of an
            // interrupted first save: a successful replace/move consumes it, and
            // the atomic write means a present temp is whole. Recover it before
            // bootstrapping so a first-run save that failed at the swap is not
            // silently discarded next launch.
            if let recovered = try? decodeConfig(from: tempURL) {
                log.warning("Primary config missing; recovered from interrupted save temp")
                try recoverFromTemp(recovered)
                return recovered
            }
            log.info("No config on disk; bootstrapping a Default layout")
            let config = Config.bootstrap()
            try save(config)
            return config
        }

        do {
            return try decodeConfig(from: fileURL)
        } catch {
            // Any failure to decode or migrate must not silently clobber the
            // file. This covers corrupt JSON (`DecodingError`) and a config
            // written by a newer Put whose schema we can't read
            // (`unsupportedSchemaVersion`). Prefer a decodable backup over
            // discarding the user's config; only quarantine and bootstrap when
            // neither the primary nor the backup is usable. On downgrade the
            // latter would otherwise propagate to the bootstrap fallback and the
            // next save would overwrite the newer config with an empty default,
            // with no copy preserved.
            if let recovered = try? decodeConfig(from: backupURL) {
                log.warning("Config unreadable; recovered from backup")
                try quarantineCorruptFile()
                try recoverFromBackup(recovered)
                return recovered
            }
            try quarantineCorruptFile()
            log.warning("Config could not be loaded; moved aside and bootstrapped a fresh config")
            let config = Config.bootstrap()
            try save(config)
            return config
        }
    }

    /// Reads and decodes a config from `url`, applying `migrate`. Throws if the
    /// file is missing, malformed, or written by a newer schema.
    private func decodeConfig(from url: URL) throws -> Config {
        let data = try fileOps.readData(from: url)
        let decoder = JSONDecoder()
        // Must match the encoder in `save(_:)`. Without this, any `Date` field
        // written as ISO 8601 fails to decode and the file is quarantined as
        // "corrupt", which would silently wipe the user's config the next
        // launch after `firstRunCompletedAt` is first stamped.
        decoder.dateDecodingStrategy = .iso8601
        let raw = try decoder.decode(Config.self, from: data)
        return try migrate(raw)
    }

    /// Writes a config recovered from the backup back to the primary path and
    /// consumes the backup. `save` snapshots no new backup here because the
    /// primary is absent (or just quarantined), so the recovery source is not
    /// clobbered before it is removed.
    private func recoverFromBackup(_ config: Config) throws {
        try save(config)
        try? fileOps.removeItem(at: backupURL)
    }

    /// Writes a config recovered from a lingering save temp back to the primary
    /// and consumes the temp. Like `recoverFromBackup`, `save` snapshots no new
    /// backup because the primary is absent, so the recovery source survives
    /// until the swap consumes it (or the `removeItem` below clears any residue).
    private func recoverFromTemp(_ config: Config) throws {
        try save(config)
        try? fileOps.removeItem(at: tempURL)
    }

    private func quarantineCorruptFile() throws {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let quarantined = fileURL
            .deletingPathExtension()
            .appendingPathExtension("corrupt-\(timestamp).json")
        try? fileOps.removeItem(at: quarantined)
        try fileOps.moveItem(at: fileURL, to: quarantined)
    }

    // MARK: - Save

    public func save(_ config: Config) throws {
        try ensureDirectory()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)

        do {
            try fileOps.writeData(data, to: tempURL)
        } catch {
            throw ConfigStoreError.atomicWriteFailed(error.localizedDescription)
        }
        try setRestrictivePermissions(on: tempURL)

        let liveExists = fileOps.fileExists(atPath: fileURL.path)

        // Snapshot the live file so we can roll back if the swap fails. Only
        // meaningful when there is a live file to lose.
        var backupTaken = false
        if liveExists {
            try? fileOps.removeItem(at: backupURL)
            do {
                try fileOps.copyItem(at: fileURL, to: backupURL)
                backupTaken = true
            } catch {
                backupTaken = false
            }
        }

        do {
            // Try the atomic swap first, with no pre-remove, so a failure here
            // leaves the live file intact.
            _ = try fileOps.replaceItem(at: fileURL, withItemAt: tempURL)
        } catch {
            // `replaceItemAt` can fail when the destination doesn't exist (the
            // first save) or lives on a mount that rejects the swap. The
            // destructive remove + move fallback must never risk zero copies:
            // only take it when we hold a backup, or when there was no live
            // file to lose. Otherwise abort and leave the existing config
            // untouched, discarding only the temp.
            guard backupTaken || !liveExists else {
                try? fileOps.removeItem(at: tempURL)
                throw ConfigStoreError.atomicWriteFailed(error.localizedDescription)
            }
            if liveExists {
                try? fileOps.removeItem(at: fileURL)
            }
            do {
                try fileOps.moveItem(at: tempURL, to: fileURL)
            } catch {
                if backupTaken {
                    // Restore the old config from the backup; the new data in
                    // temp is discarded because the old config is now safe.
                    try? fileOps.removeItem(at: fileURL)
                    try? fileOps.moveItem(at: backupURL, to: fileURL)
                    try? fileOps.removeItem(at: tempURL)
                }
                // Without a backup (the no-live-file case) the temp is the only
                // surviving copy of the new config, so it is deliberately left
                // in place; `load()` recovers it on the next launch.
                throw ConfigStoreError.atomicWriteFailed(error.localizedDescription)
            }
        }

        try setRestrictivePermissions(on: fileURL)
        if backupTaken {
            try? fileOps.removeItem(at: backupURL)
        }
    }

    // MARK: - Migration

    private func migrate(_ config: Config) throws -> Config {
        if config.schemaVersion == putSchemaVersion {
            return config
        }
        if config.schemaVersion > putSchemaVersion {
            throw ConfigStoreError.unsupportedSchemaVersion(
                found: config.schemaVersion,
                supported: putSchemaVersion)
        }
        // Older versions. Shape changes so far are handled at decode time
        // (the Layout decoder folds the legacy single `screenConfig` into the
        // `screenConfigs` array), so migration only stamps the current version
        // so subsequent writes are current. Add real migration steps here as
        // the schema evolves.
        var upgraded = config
        upgraded.schemaVersion = putSchemaVersion
        return upgraded
    }

    // MARK: - Filesystem helpers

    private func ensureDirectory() throws {
        let dir = fileURL.deletingLastPathComponent()
        if !fileOps.fileExists(atPath: dir.path) {
            do {
                try fileOps.createDirectory(at: dir, permissions: 0o700)
            } catch {
                throw ConfigStoreError.directoryCreationFailed(error.localizedDescription)
            }
        } else {
            // Tighten perms in case the directory pre-exists with looser ones.
            try? fileOps.setPermissions(0o700, ofItemAtPath: dir.path)
        }
    }

    private func setRestrictivePermissions(on url: URL) throws {
        do {
            try fileOps.setPermissions(0o600, ofItemAtPath: url.path)
        } catch {
            throw ConfigStoreError.permissionAdjustmentFailed(error.localizedDescription)
        }
    }
}
