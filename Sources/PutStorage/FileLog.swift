import Foundation
import OSLog
import PutCore

public enum FileLogLevel: String, Codable, Sendable {
    case debug
    case info
    case warn
    case error
}

/// Newline-delimited JSON log file. Rotated to `put.log.1` when the active
/// file exceeds `maxBytes`. Up to `generations` rotated files are kept
/// (`put.log.1`, `put.log.2`, ...); anything older is dropped. A chatty
/// display-storm evicts logs fast with a single generation, so we keep three
/// by default.
///
/// This is explicitly separate from `os.Logger`. Unified logging is the primary
/// diagnostic stream (visible in Console.app and via `log stream`); the file
/// sidecar exists so Help > Export Diagnostics can capture milestones such
/// as config migrations, Accessibility state changes, and hotkey-conflict
/// surfaces without requiring the user to mess with Console.
public actor FileLog {
    private let fileURL: URL
    private let maxBytes: Int
    private let generations: Int
    private let revalidateEvery: Int
    private let fileManager: FileManager
    private let oslog: Logger
    private let encoder: JSONEncoder
    private var handle: FileHandle?
    /// Live size of the active file, seeded from the handle at open so rotation
    /// costs O(1) per append instead of an `attributesOfItem` stat (C23).
    private var byteCount = 0
    /// Appends since the last path-existence check; drives the coarse
    /// revalidation cadence that recovers from an external delete (C24).
    private var appendsSinceRevalidation = 0

    public init(
        fileURL: URL = PutLog.sidecarURL,
        maxBytes: Int = 1_000_000,
        generations: Int = 3,
        revalidateEvery: Int = 256,
        fileManager: FileManager = .default)
    {
        self.fileURL = fileURL
        self.maxBytes = maxBytes
        self.generations = max(1, generations)
        self.revalidateEvery = max(1, revalidateEvery)
        self.fileManager = fileManager
        oslog = PutLog.logger(category: "filelog")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    public var url: URL {
        fileURL
    }

    public func append(
        level: FileLogLevel,
        category: String,
        message: String,
        metadata: [String: String] = [:])
    {
        do {
            try ensureDirectory()
            let entry = Entry(
                timestamp: Date(),
                level: level,
                category: category,
                message: message,
                metadata: metadata)
            let data = try encoder.encode(entry) + Data([0x0A])
            try rotateIfNeeded()
            try appendData(data)
        } catch {
            // Fall back to unified logging only; never throw from a log call.
            oslog.error("File sink failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    deinit {
        try? handle?.close()
    }

    // MARK: - Private

    private struct Entry: Codable {
        let timestamp: Date
        let level: FileLogLevel
        let category: String
        let message: String
        let metadata: [String: String]
    }

    private func ensureDirectory() throws {
        let dir = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
    }

    private func appendData(_ data: Data) throws {
        let handle = try ensureHandle()
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        byteCount += data.count
    }

    private func ensureHandle() throws -> FileHandle {
        if let handle { return handle }
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        } else {
            // Pre-existing file: make sure perms are still 0600.
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
        let opened = try FileHandle(forWritingTo: fileURL)
        // Seed the counter from the real size so rotation stays accurate across
        // process restarts without a per-append stat.
        byteCount = Int((try? opened.seekToEnd()) ?? 0)
        handle = opened
        return opened
    }

    private func closeHandle() {
        try? handle?.close()
        handle = nil
    }

    private func rotateIfNeeded() throws {
        revalidateOnCadence()
        // Open (and seed the counter) if needed before consulting it.
        _ = try ensureHandle()
        guard byteCount >= maxBytes else { return }
        // At the threshold, confirm the file still exists before rotating. An
        // external delete leaves a stale counter; recreate and skip this cycle.
        revalidateFileExistence()
        _ = try ensureHandle()
        guard byteCount >= maxBytes else { return }
        try rotate()
    }

    /// Check the path on a coarse cadence so per-append cost stays O(1) while
    /// still recovering from an external delete within `revalidateEvery` writes.
    private func revalidateOnCadence() {
        appendsSinceRevalidation += 1
        guard appendsSinceRevalidation >= revalidateEvery else { return }
        appendsSinceRevalidation = 0
        revalidateFileExistence()
    }

    /// If the active file was removed out from under us (external `rm`), drop
    /// the stale handle and reset the counter so the next `ensureHandle`
    /// recreates the file and writes land on a live inode again (C24). Without
    /// this the actor writes to an unlinked inode forever and rotation is
    /// permanently disabled.
    private func revalidateFileExistence() {
        guard handle != nil else { return }
        if !fileManager.fileExists(atPath: fileURL.path) {
            closeHandle()
            byteCount = 0
        }
    }

    private func rotate() throws {
        // Drop the handle before renaming so the next write reopens on the
        // fresh file rather than appending to the moved-aside log.
        closeHandle()

        // Shift generations: .<generations> is dropped, each .N moves to .N+1,
        // active becomes .1.
        let oldestPath = fileURL.appendingPathExtension("\(generations)").path
        if fileManager.fileExists(atPath: oldestPath) {
            try fileManager.removeItem(atPath: oldestPath)
        }
        for generation in stride(from: generations - 1, through: 1, by: -1) {
            let src = fileURL.appendingPathExtension("\(generation)")
            let dst = fileURL.appendingPathExtension("\(generation + 1)")
            if fileManager.fileExists(atPath: src.path) {
                try fileManager.moveItem(at: src, to: dst)
            }
        }
        let firstGeneration = fileURL.appendingPathExtension("1")
        try fileManager.moveItem(at: fileURL, to: firstGeneration)
        byteCount = 0
    }
}
