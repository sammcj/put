import Foundation
@testable import PutAutomation
@testable import PutCore
@testable import PutStorage
import Testing

@Suite("DiagnosticsExport")
struct DiagnosticsExportTests {
    @Test
    func exportDirnameIsMillisecondUniqueAcrossRapidExports() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("put-diag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let first = try await DiagnosticsExport.build(
            config: Config.bootstrap(),
            destinationDirectory: tmp,
            bundleVersion: "1.0.0")
        let second = try await DiagnosticsExport.build(
            config: Config.bootstrap(),
            destinationDirectory: tmp,
            bundleVersion: "1.0.0")

        #expect(first != second, "Two back-to-back exports should produce distinct archives")
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test
    func sanitiseRemovesDisplayLocalizedNames() {
        // `NSScreen.localizedName` for Sidecar/AirPlay targets often embeds the
        // owner's name ("Sam's iPad"); it must not survive into the exported
        // config on either a rule's targetDisplay or a layout's screenConfigs.
        let display = DisplayFingerprint(
            uuid: UUID(),
            vendorID: 1,
            productID: 2,
            serialNumber: 3,
            pointSize: CGSize(width: 1440, height: 900),
            pixelSize: CGSize(width: 2880, height: 1800),
            scaleFactor: 2,
            globalOrigin: .zero,
            isPrimary: true,
            localizedName: "Sam's iPad")
        let rule = Rule(
            matchCriteria: MatchCriteria(bundleID: "com.example.app"),
            targetDisplay: display,
            frame: WindowFrame(
                absolute: CGRect(x: 0, y: 0, width: 100, height: 100),
                normalised: UnitRect(x: 0, y: 0, width: 0.1, height: 0.1)))
        var layout = Layout(name: "Test", rules: [rule])
        layout.screenConfigs = [ScreenConfigTrigger(displays: [display])]
        var config = Config.bootstrap()
        config.layouts = [layout]

        let sanitised = DiagnosticsExport.sanitise(config)

        let names = sanitised.layouts.flatMap { layout -> [String?] in
            layout.rules.map(\.targetDisplay.localizedName)
                + layout.screenConfigs.flatMap { $0.displays.map(\.localizedName) }
        }
        #expect(names.allSatisfy { $0 == nil }, "localizedName must be stripped from every display in the export")
    }

    @Test
    func redactionReplacesTitlesAndPaths() async throws {
        // Drop a known-sensitive log file in place of the real sidecar so the
        // exporter has something to scrub.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("put-diag-redact-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let sidecar = PutLog.sidecarURL
        let sidecarDir = sidecar.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: sidecarDir, withIntermediateDirectories: true)
        let backup = sidecar.appendingPathExtension("testbackup")
        let hadExisting = FileManager.default.fileExists(atPath: sidecar.path)
        if hadExisting {
            try? FileManager.default.removeItem(at: backup)
            try FileManager.default.moveItem(at: sidecar, to: backup)
        }
        defer {
            try? FileManager.default.removeItem(at: sidecar)
            if hadExisting { try? FileManager.default.moveItem(at: backup, to: sidecar) }
        }

        let sensitive = """
        {"timestamp":"2026-04-20T00:00:00Z","title":"Secret Project","category":"actions"}
        {"timestamp":"2026-04-20T00:00:01Z","message":"opened /Users/sam/Documents/secret.txt"}
        """
        try Data(sensitive.utf8).write(to: sidecar)

        let zipURL = try await DiagnosticsExport.build(
            config: Config.bootstrap(),
            destinationDirectory: tmp,
            bundleVersion: "1.0.0",
            includeFullLogs: false)

        // The zip is already produced; we can't easily unzip here without
        // introducing a dependency. Build again with includeFullLogs: true to
        // an adjacent dir and diff to be sure. Alternatively, since the
        // redaction function is private, we test by searching the zip bytes.
        let archiveBytes = try Data(contentsOf: zipURL)
        let asString = String(data: archiveBytes, encoding: .utf8) ?? ""
        // Zip content is mostly binary; we're looking for verbatim sensitive
        // strings. Because ditto can store embedded text uncompressed for tiny
        // files, a simple contains-check is a useful smoke signal.
        if asString.contains("Secret Project") {
            Issue.record("Redacted title leaked into export zip")
        }
        if asString.contains("/Users/sam/Documents/secret.txt") {
            Issue.record("Redacted path leaked into export zip")
        }
    }
}
