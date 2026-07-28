import Foundation
@testable import PutAutomation
@testable import PutCore
import Testing

@Suite("SettingsBackup")
struct SettingsBackupTests {
    private func sampleBackup() -> SettingsBackup {
        SettingsBackup(
            appVersion: "1.2.3",
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            config: Config.bootstrap(),
            shortcuts: ["restoreAllWindows": #"{"carbonKeyCode":97,"carbonModifiers":0}"#])
    }

    @Test
    func encodeDecodeRoundTripsConfigAndShortcuts() throws {
        let original = sampleBackup()
        let data = try SettingsBackupArchive.encode(original)
        let decoded = try SettingsBackupArchive.decode(from: data)

        #expect(decoded.appVersion == original.appVersion)
        #expect(decoded.exportedAt == original.exportedAt)
        #expect(decoded.config == original.config)
        #expect(decoded.shortcuts == original.shortcuts)
        #expect(decoded.formatVersion == SettingsBackup.currentFormatVersion)
    }

    @Test
    func writeThenReadFromDiskRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("put-backup-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let original = sampleBackup()
        try SettingsBackupArchive.write(original, to: url)
        let decoded = try SettingsBackupArchive.read(from: url)

        #expect(decoded.config == original.config)
        #expect(decoded.shortcuts == original.shortcuts)
    }

    @Test
    func decodeRejectsNewerFormatVersion() throws {
        var future = sampleBackup()
        future.formatVersion = SettingsBackup.currentFormatVersion + 1
        let data = try SettingsBackupArchive.encode(future)

        #expect(throws: SettingsBackupError.self) {
            _ = try SettingsBackupArchive.decode(from: data)
        }
    }

    @Test
    func decodeRejectsNewerConfigSchema() throws {
        var backup = sampleBackup()
        backup.config.schemaVersion = putSchemaVersion + 1
        let data = try SettingsBackupArchive.encode(backup)

        #expect(throws: SettingsBackupError.self) {
            _ = try SettingsBackupArchive.decode(from: data)
        }
    }

    @Test
    func decodeRejectsMalformedJSON() {
        let garbage = Data("not a backup".utf8)
        #expect(throws: SettingsBackupError.self) {
            _ = try SettingsBackupArchive.decode(from: garbage)
        }
    }

    @Test
    func suggestedFilenameIsFilesystemSafe() {
        let name = SettingsBackupArchive.suggestedFilename(now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(name.hasPrefix("put-settings-"))
        #expect(name.hasSuffix(".json"))
        #expect(!name.contains(":"))
    }
}
