import Foundation
@testable import PutCore
@testable import PutStorage
import PutTestSupport
import Testing

@Suite("ConfigStore")
struct ConfigStoreTests {
    /// Fresh temp-directory-backed `ConfigStore` plus cleanup handle.
    struct StoreFixture {
        let store: ConfigStore
        let url: URL
        let cleanup: () -> Void
    }

    /// Builds a `ConfigStore` rooted in a fresh temp directory and returns
    /// both the store and a cleanup closure.
    private func makeStore() throws -> StoreFixture {
        let temp = try makeTempStore()
        return StoreFixture(store: temp.store, url: temp.url, cleanup: temp.cleanup)
    }

    @Test
    func firstLoadBootstrapsAndPersists() async throws {
        let fixture = try makeStore()
        defer { fixture.cleanup() }

        let config = try await fixture.store.load()
        #expect(config.layouts.count == 1)
        #expect(FileManager.default.fileExists(atPath: fixture.url.path))
    }

    @Test
    func saveThenLoadRoundtripsExact() async throws {
        let fixture = try makeStore()
        defer { fixture.cleanup() }

        var config = Config.bootstrap()
        config.launchAtLogin = true
        config.autoTriggers = AutoTriggerSettings(
            onDisplayChange: true,
            onAppLaunch: false,
            onWake: true)

        try await fixture.store.save(config)
        let loaded = try await fixture.store.load()
        #expect(loaded == config)
    }

    @Test
    func filePermissionsAre0600() async throws {
        let fixture = try makeStore()
        defer { fixture.cleanup() }

        try await fixture.store.save(Config.bootstrap())
        let attrs = try FileManager.default.attributesOfItem(atPath: fixture.url.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(perms == 0o600)
    }

    @Test
    func directoryPermissionsAre0700() async throws {
        let fixture = try makeStore()
        defer { fixture.cleanup() }

        try await fixture.store.save(Config.bootstrap())
        let dir = fixture.url.deletingLastPathComponent()
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(perms == 0o700)
    }

    @Test
    func olderSchemaVersionGetsStampedForward() async throws {
        let fixture = try makeStore()
        defer { fixture.cleanup() }

        // Write a config with schemaVersion = 0 directly to disk.
        var config = Config.bootstrap()
        config.schemaVersion = 0
        let data = try JSONEncoder().encode(config)
        try FileManager.default.createDirectory(
            at: fixture.url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try data.write(to: fixture.url)

        let loaded = try await fixture.store.load()
        #expect(loaded.schemaVersion == putSchemaVersion)
    }

    @Test
    func futureSchemaVersionQuarantinesAndBootstraps() async throws {
        // A config written by a newer Put (higher schema version) must not be
        // clobbered on downgrade. `load()` quarantines it alongside a fresh
        // bootstrap rather than throwing — throwing would route through the
        // app's bootstrap fallback and the next save would overwrite the
        // newer file with an empty default, destroying it with no copy.
        let fixture = try makeStore()
        defer { fixture.cleanup() }

        var config = Config.bootstrap()
        config.schemaVersion = putSchemaVersion + 100
        let data = try JSONEncoder().encode(config)
        try FileManager.default.createDirectory(
            at: fixture.url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try data.write(to: fixture.url)

        let loaded = try await fixture.store.load()
        #expect(loaded.schemaVersion == putSchemaVersion, "Expected a fresh bootstrap after a future-schema file")
        let contents = try FileManager.default.contentsOfDirectory(
            atPath: fixture.url.deletingLastPathComponent().path)
        let quarantined = contents.first(where: { $0.contains("corrupt") })
        #expect(quarantined != nil, "Future-schema config should be preserved alongside the fresh one")
    }

    @Test
    func atomicSaveLeavesNoTempFileBehind() async throws {
        let fixture = try makeStore()
        defer { fixture.cleanup() }

        try await fixture.store.save(Config.bootstrap())
        let tempURL = fixture.url.appendingPathExtension("tmp")
        #expect(!FileManager.default.fileExists(atPath: tempURL.path))
    }

    @Test
    func corruptConfigQuarantinesAndBootstraps() async throws {
        let fixture = try makeStore()
        defer { fixture.cleanup() }

        try FileManager.default.createDirectory(
            at: fixture.url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        // Write deliberately malformed JSON.
        try Data("{ this is not valid json".utf8).write(to: fixture.url)

        let loaded = try await fixture.store.load()
        #expect(loaded.layouts.count == 1, "Expected fresh bootstrap after corrupt file")
        let contents = try FileManager.default.contentsOfDirectory(
            atPath: fixture.url.deletingLastPathComponent().path)
        let quarantined = contents.first(where: { $0.contains("corrupt") })
        #expect(quarantined != nil, "Corrupt config should be preserved alongside the fresh one")
    }

    @Test
    func firstRunCompletedAtRoundtripsThroughDisk() async throws {
        // Regression test: ensure the encoder/decoder agree on `Date`
        // strategy. Without `.iso8601` on the decoder the file would be
        // quarantined on the next launch after the wizard stamps a date.
        let fixture = try makeStore()
        defer { fixture.cleanup() }

        var config = Config.bootstrap()
        // Truncate to whole seconds so JSON ISO 8601 round-trips exactly;
        // sub-second precision is lost in the textual encoding.
        let stamp = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        config.firstRunCompletedAt = stamp
        config.launchAtLogin = true

        try await fixture.store.save(config)
        let loaded = try await fixture.store.load()
        #expect(loaded.firstRunCompletedAt == stamp)
        #expect(loaded == config)
    }

    @Test
    func successfulSaveLeavesNoBackupBehind() async throws {
        // Combination D (success): the normal replace path lands the new config
        // and cleans up its snapshot.
        let fixture = try makeStore()
        defer { fixture.cleanup() }

        try await fixture.store.save(Config.bootstrap())
        try await fixture.store.save(Config.bootstrap())
        let backup = fixture.url.appendingPathExtension("backup")
        #expect(
            !FileManager.default.fileExists(atPath: backup.path),
            "Backup should be removed after a successful save")
    }

    // MARK: - Config-loss failure matrix (C1)

    //
    // Every branch of `save` must leave at least one intact copy. The seam
    // injects filesystem failures a normal disk won't produce. `old` carries
    // launchAtLogin == false, `new` carries true, so on-disk assertions tell
    // which config survived.

    private func decodeConfig(at url: URL) throws -> Config {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Config.self, from: Data(contentsOf: url))
    }

    private func oldConfig() -> Config {
        var config = Config.bootstrap()
        config.launchAtLogin = false
        return config
    }

    private func newConfig() -> Config {
        var config = Config.bootstrap()
        config.launchAtLogin = true
        return config
    }

    @Test
    func replaceFailureFallsBackToMoveAndLandsNewConfig() async throws {
        // Combination A: replace fails, backup taken, move succeeds -> the new
        // config lands via the fallback move.
        let fixture = try makeStore()
        defer { fixture.cleanup() }
        try await fixture.store.save(oldConfig())

        let faulty = ConfigStore(
            fileURL: fixture.url,
            fileOps: FaultyFileOps(failReplace: true))
        try await faulty.save(newConfig())

        #expect(try decodeConfig(at: fixture.url).launchAtLogin == true)
        let backup = fixture.url.appendingPathExtension("backup")
        #expect(!FileManager.default.fileExists(atPath: backup.path))
    }

    @Test
    func replaceAndMoveFailureRestoresBackup() async throws {
        // Combination B: replace fails, backup taken, move fails -> the backup
        // is restored, leaving the old config intact.
        let fixture = try makeStore()
        defer { fixture.cleanup() }
        try await fixture.store.save(oldConfig())

        let faulty = ConfigStore(
            fileURL: fixture.url,
            fileOps: FaultyFileOps(failReplace: true, failMove: true))
        await #expect(throws: ConfigStoreError.self) {
            try await faulty.save(self.newConfig())
        }

        #expect(FileManager.default.fileExists(atPath: fixture.url.path))
        #expect(try decodeConfig(at: fixture.url).launchAtLogin == false)
    }

    @Test
    func saveAbortsRatherThanLoseEverythingWhenBackupCannotBeTaken() async throws {
        // Combination C (catastrophic): replace fails, the backup copy fails,
        // and the fallback move fails. The old code removed the live file and
        // then the temp, leaving zero copies. The restructured save must abort
        // before touching the live file, so the old config survives untouched.
        let fixture = try makeStore()
        defer { fixture.cleanup() }
        try await fixture.store.save(oldConfig())

        let faulty = ConfigStore(
            fileURL: fixture.url,
            fileOps: FaultyFileOps(failReplace: true, failMove: true, failCopy: true))
        await #expect(throws: ConfigStoreError.self) {
            try await faulty.save(self.newConfig())
        }

        #expect(
            FileManager.default.fileExists(atPath: fixture.url.path),
            "Old config must survive when no backup could be taken")
        #expect(try decodeConfig(at: fixture.url).launchAtLogin == false)
        let temp = fixture.url.appendingPathExtension("tmp")
        #expect(
            !FileManager.default.fileExists(atPath: temp.path),
            "Temp is cleaned up because the old config is the surviving copy")
    }

    @Test
    func tempSurvivesAsOnlyCopyWhenFirstSaveCannotLand() async throws {
        // Combination E: no live file exists (first save), replace fails and the
        // fallback move fails. The temp is the only copy of the new config, so
        // the worst-case branch must not delete it.
        let fixture = try makeStore()
        defer { fixture.cleanup() }

        let faulty = ConfigStore(
            fileURL: fixture.url,
            fileOps: FaultyFileOps(failReplace: true, failMove: true))
        await #expect(throws: ConfigStoreError.self) {
            try await faulty.save(self.newConfig())
        }

        #expect(
            !FileManager.default.fileExists(atPath: fixture.url.path),
            "No primary was written")
        let temp = fixture.url.appendingPathExtension("tmp")
        #expect(
            FileManager.default.fileExists(atPath: temp.path),
            "Temp preserved as the only surviving copy")
        #expect(try decodeConfig(at: temp).launchAtLogin == true)

        // The surviving temp must actually be recoverable, not just present: a
        // fresh load (healthy ops) recovers it into the primary rather than
        // bootstrapping an empty config over it.
        let recovered = try await ConfigStore(fileURL: fixture.url).load()
        #expect(recovered.launchAtLogin == true, "next launch recovers the temp")
        #expect(
            FileManager.default.fileExists(atPath: fixture.url.path),
            "primary restored from the temp after recovery")
    }

    @Test
    func loadRecoversFromBackupWhenPrimaryMissing() async throws {
        // An interrupted write can leave a `.backup` snapshot with no primary.
        // `load` must recover it before bootstrapping a fresh (empty) config.
        let fixture = try makeStore()
        defer { fixture.cleanup() }
        try await fixture.store.save(newConfig())

        let backup = fixture.url.appendingPathExtension("backup")
        try FileManager.default.copyItem(at: fixture.url, to: backup)
        try FileManager.default.removeItem(at: fixture.url)

        let loaded = try await fixture.store.load()
        #expect(loaded.launchAtLogin == true, "load should recover the config from the backup")
        #expect(
            FileManager.default.fileExists(atPath: fixture.url.path),
            "primary should be restored after recovery")
    }

    @Test
    func loadRecoversFromBackupWhenPrimaryCorrupt() async throws {
        // A decodable backup beats quarantining and bootstrapping an empty
        // config when the primary is unreadable.
        let fixture = try makeStore()
        defer { fixture.cleanup() }
        try await fixture.store.save(newConfig())

        let backup = fixture.url.appendingPathExtension("backup")
        try FileManager.default.copyItem(at: fixture.url, to: backup)
        try Data("{ not valid json".utf8).write(to: fixture.url)

        let loaded = try await fixture.store.load()
        #expect(loaded.launchAtLogin == true, "load should prefer the decodable backup")
        let contents = try FileManager.default.contentsOfDirectory(
            atPath: fixture.url.deletingLastPathComponent().path)
        #expect(
            contents.contains(where: { $0.contains("corrupt") }),
            "the unreadable primary should still be quarantined for forensics")
    }
}

/// Injected filesystem failures for the config-loss matrix. Delegates to a real
/// FileManager-backed store, throwing on the operations a test flags.
private enum InjectedFailure: Error { case replace, move, copy }

private struct FaultyFileOps: ConfigFileStore {
    let base: ConfigFileStore = FileManagerConfigFileStore()
    var failReplace = false
    var failMove = false
    var failCopy = false

    func fileExists(atPath path: String) -> Bool {
        base.fileExists(atPath: path)
    }

    func readData(from url: URL) throws -> Data {
        try base.readData(from: url)
    }

    func writeData(_ data: Data, to url: URL) throws {
        try base.writeData(data, to: url)
    }

    func removeItem(at url: URL) throws {
        try base.removeItem(at: url)
    }

    func moveItem(at src: URL, to dst: URL) throws {
        // Model a cross-device temp: the commit move (temp -> live) fails, but a
        // restore move from the same-directory `.backup` snapshot still works.
        if failMove, src.pathExtension == "tmp" { throw InjectedFailure.move }
        try base.moveItem(at: src, to: dst)
    }

    func copyItem(at src: URL, to dst: URL) throws {
        if failCopy { throw InjectedFailure.copy }
        try base.copyItem(at: src, to: dst)
    }

    @discardableResult
    func replaceItem(at dst: URL, withItemAt src: URL) throws -> URL? {
        if failReplace { throw InjectedFailure.replace }
        return try base.replaceItem(at: dst, withItemAt: src)
    }

    func createDirectory(at url: URL, permissions: Int) throws {
        try base.createDirectory(at: url, permissions: permissions)
    }

    func setPermissions(_ permissions: Int, ofItemAtPath path: String) throws {
        try base.setPermissions(permissions, ofItemAtPath: path)
    }
}

@Suite("FileLog")
struct FileLogTests {
    @Test
    func appendWritesAndRotates() async {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("put-log-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let file = tmp.appendingPathComponent("put.log")
        let log = FileLog(fileURL: file, maxBytes: 200)

        // Fill past the rotation threshold.
        for index in 0..<10 {
            await log.append(level: .info, category: "test", message: "line \(index)")
        }

        #expect(FileManager.default.fileExists(atPath: file.path))
        let rotated = file.appendingPathExtension("1")
        #expect(FileManager.default.fileExists(atPath: rotated.path))
    }

    @Test
    func rotationKeepsThreeGenerations() async {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("put-log-gen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let file = tmp.appendingPathComponent("put.log")
        let log = FileLog(fileURL: file, maxBytes: 200, generations: 3)

        // Enough entries to trigger multiple rotation cycles.
        for index in 0..<120 {
            await log.append(
                level: .info,
                category: "test",
                message: "a reasonably long line \(index) with padding \(String(repeating: "x", count: 30))")
        }

        #expect(FileManager.default.fileExists(atPath: file.path))
        for generation in 1...3 {
            let rotated = file.appendingPathExtension("\(generation)")
            #expect(
                FileManager.default.fileExists(atPath: rotated.path),
                "Expected generation put.log.\(generation) to exist")
        }
        let tooOld = file.appendingPathExtension("4")
        #expect(
            !FileManager.default.fileExists(atPath: tooOld.path),
            "Should not retain a fourth generation")
    }

    @Test
    func byteCounterTriggersRotationAtThreshold() async {
        // Rotation is driven purely by the in-actor byte counter (C23), not a
        // per-append stat. Keep the revalidation cadence high so only the
        // counter can cause the rotation here.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("put-log-counter-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let file = tmp.appendingPathComponent("put.log")
        let log = FileLog(fileURL: file, maxBytes: 200, revalidateEvery: 10000)

        for index in 0..<20 {
            await log.append(level: .info, category: "test", message: "line \(index)")
        }

        #expect(FileManager.default.fileExists(atPath: file.path))
        let rotated = file.appendingPathExtension("1")
        #expect(
            FileManager.default.fileExists(atPath: rotated.path),
            "byte counter alone should have triggered rotation")
    }

    @Test
    func externalDeletionRecreatesFileAndKeepsWriting() async throws {
        // After an external `rm put.log`, the actor must notice on its coarse
        // cadence, drop the stale handle, recreate the file, and resume writing
        // (C24) rather than write to an unlinked inode forever.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("put-log-delete-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let file = tmp.appendingPathComponent("put.log")
        let log = FileLog(fileURL: file, maxBytes: 1_000_000, revalidateEvery: 4)

        await log.append(level: .info, category: "test", message: "before")
        #expect(FileManager.default.fileExists(atPath: file.path))

        try FileManager.default.removeItem(at: file)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        // Append past the revalidation cadence so the deletion is detected.
        for index in 0..<6 {
            await log.append(level: .info, category: "test", message: "after \(index)")
        }

        #expect(
            FileManager.default.fileExists(atPath: file.path),
            "log should be recreated after external deletion")
        let contents = try String(contentsOfFile: file.path, encoding: .utf8)
        #expect(contents.contains("after"), "fresh file should receive writes")
    }

    @Test
    func rotatedLinesAreValidNdjson() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("put-log-ndjson-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let file = tmp.appendingPathComponent("put.log")
        let log = FileLog(fileURL: file, maxBytes: 300, generations: 2)

        for index in 0..<20 {
            await log.append(level: .info, category: "ndjson", message: "entry \(index)")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for name in [file.path, file.appendingPathExtension("1").path] {
            guard FileManager.default.fileExists(atPath: name) else { continue }
            let contents = try String(contentsOfFile: name, encoding: .utf8)
            for line in contents.split(separator: "\n") where !line.isEmpty {
                let parsed: [String: AnyDecodable]? = try? decoder.decode(
                    [String: AnyDecodable].self,
                    from: Data(line.utf8))
                #expect(parsed != nil, "Every line should parse as a JSON object")
            }
        }
    }
}

/// Minimal type-erasing decoder used to assert log lines parse as JSON
/// objects without caring about every field shape.
private struct AnyDecodable: Decodable {
    let raw: Any?
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            raw = nil
        } else if let value = try? container.decode(Bool.self) {
            raw = value
        } else if let value = try? container.decode(Double.self) {
            raw = value
        } else if let value = try? container.decode(String.self) {
            raw = value
        } else if let value = try? container.decode([AnyDecodable].self) {
            raw = value
        } else if let value = try? container.decode([String: AnyDecodable].self) {
            raw = value
        } else {
            raw = nil
        }
    }
}
