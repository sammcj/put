import CoreGraphics
import Foundation
@testable import PutCore
@testable import PutDisplay
import PutTestSupport
import Testing

@Suite("StoredDisplayLayouts")
struct StoredDisplayLayoutsTests {
    private typealias Plist = StoredDisplayLayouts.Plist

    private static let left = UUID()
    private static let laptop = UUID()
    private static let right = UUID()
    private static let elsewhere = UUID()

    private func live(
        _ uuid: UUID,
        x: CGFloat,
        y: CGFloat = 0,
        size: CGSize,
        isPrimary: Bool = false) throws -> StoredDisplayLayouts.LiveDisplay
    {
        try #require(StoredDisplayLayouts.LiveDisplay(makeDisplayFingerprint(
            uuid: uuid,
            pointSize: size,
            globalOrigin: CGPoint(x: x, y: y),
            isPrimary: isPrimary)))
    }

    /// Left and right monitors at 3360x1890 either side of a primary laptop.
    private func threeDisplays() throws -> [StoredDisplayLayouts.LiveDisplay] {
        try [
            live(Self.left, x: -3360, size: CGSize(width: 3360, height: 1890)),
            live(Self.laptop, x: 0, size: CGSize(width: 1728, height: 1117), isPrimary: true),
            live(Self.right, x: 1728, size: CGSize(width: 3360, height: 1890))
        ]
    }

    private func info(wide: Double, high: Double, x: Double = 0, hz: Double = 60, scale: Double = 2) -> Plist {
        ["Wide": wide, "High": high, "Hz": hz, "Scale": scale, "Depth": 8, "OriginX": x, "OriginY": 0.0]
    }

    private func entry(_ uuid: UUID, _ current: Plist, unmirror: Plist? = nil) -> Plist {
        ["UUID": uuid.uuidString, "Rotation": 0, "CurrentInfo": current, "UnmirrorInfo": unmirror ?? current]
    }

    private func config(_ entries: Plist...) -> Plist {
        ["ConfigVersion": 1, "DisplayConfig": entries]
    }

    private func currentLayout() -> Plist {
        config(
            entry(Self.left, info(wide: 3360, high: 1890, x: -3360, hz: 165)),
            entry(Self.laptop, info(wide: 1728, high: 1117, hz: 120)),
            entry(Self.right, info(wide: 3360, high: 1890, x: 1728, hz: 165)))
    }

    private func update(
        _ configs: [Plist],
        pinning: Set<UUID>) throws -> StoredDisplayLayouts.Update
    {
        let displays = try threeDisplays()
        let pinned = Set(pinning.map(\.uuidString))
        let current = try StoredDisplayLayouts.currentEntries(in: configs, displays: displays, pinning: pinned)
        return try StoredDisplayLayouts.updating(configs, with: current, displays: displays, pinning: pinned)
    }

    private func layout(of displays: Set<UUID>, in configs: [Plist]) throws -> [String: Plist] {
        let wanted = Set(displays.map(\.uuidString))
        let found = configs.first { config in
            let entries = config["DisplayConfig"] as? [Plist] ?? []
            return Set(entries.compactMap { $0["UUID"] as? String }) == wanted
        }
        let entries = try #require(found?["DisplayConfig"] as? [Plist])
        return Dictionary(uniqueKeysWithValues: entries.map { ($0["UUID"] as? String ?? "", $0) })
    }

    private func current(_ uuid: UUID, in entries: [String: Plist], _ key: String = "CurrentInfo") throws -> Plist {
        try #require(entries[uuid.uuidString]?[key] as? Plist)
    }

    @Test
    func staleSingleDisplayLayoutTakesCurrentMode() throws {
        let stale = config(entry(Self.right, info(wide: 1920, high: 1080, scale: 1)))
        let all = Set([Self.left, Self.laptop, Self.right])

        let result = try update([currentLayout(), stale], pinning: all)

        let entries = try layout(of: [Self.right], in: result.configs)
        for key in ["CurrentInfo", "UnmirrorInfo"] {
            let mode = try current(Self.right, in: entries, key)
            #expect(mode["Wide"] as? Double == 3360)
            #expect(mode["High"] as? Double == 1890)
            #expect(mode["Hz"] as? Double == 165)
            #expect(mode["Scale"] as? Double == 2)
        }
    }

    @Test
    func missingCombinationsAreAdded() throws {
        let result = try update([currentLayout()], pinning: [Self.left, Self.laptop, Self.right])

        #expect(result.configs.count == 7)
        #expect(result.changed == 6)
    }

    @Test
    func currentLayoutIsAlreadyCorrect() throws {
        let result = try update([currentLayout()], pinning: [Self.right])

        let entries = try layout(of: [Self.left, Self.laptop, Self.right], in: result.configs)
        #expect(try current(Self.left, in: entries)["OriginX"] as? Double == -3360)
        #expect(try current(Self.right, in: entries)["OriginX"] as? Double == 1728)
    }

    @Test
    func secondRunChangesNothing() throws {
        let all = Set([Self.left, Self.laptop, Self.right])
        let first = try update([currentLayout()], pinning: all)

        #expect(try update(first.configs, pinning: all).changed == 0)
    }

    @Test
    func layoutsWithOtherDisplaysAreLeftAlone() throws {
        let office = config(
            entry(Self.right, info(wide: 1920, high: 1080)),
            entry(Self.elsewhere, info(wide: 2560, high: 1440, x: 1920)))

        let result = try update([currentLayout(), office], pinning: [Self.left, Self.laptop, Self.right])

        let entries = try layout(of: [Self.right, Self.elsewhere], in: result.configs)
        #expect(try current(Self.right, in: entries)["Wide"] as? Double == 1920)
    }

    @Test
    func perDisplayPinLeavesOtherDisplayModes() throws {
        let stale = config(
            entry(Self.laptop, info(wide: 2056, high: 1329)),
            entry(Self.right, info(wide: 1920, high: 1080, x: 2056, scale: 1)))

        let result = try update([currentLayout(), stale], pinning: [Self.right])

        let entries = try layout(of: [Self.laptop, Self.right], in: result.configs)
        #expect(try current(Self.laptop, in: entries)["Wide"] as? Double == 2056)
        #expect(try current(Self.right, in: entries)["Wide"] as? Double == 3360)
        #expect(try current(Self.right, in: entries)["OriginX"] as? Double == 2056)
    }

    @Test
    func missingMiddleDisplayClosesTheGap() throws {
        let result = try update([currentLayout()], pinning: [Self.left, Self.right])

        let entries = try layout(of: [Self.left, Self.right], in: result.configs)
        let leftX = try #require(try current(Self.left, in: entries)["OriginX"] as? Double)
        let rightX = try #require(try current(Self.right, in: entries)["OriginX"] as? Double)
        #expect(rightX - leftX == 3360)
        #expect(leftX == 0 || rightX == 0)
    }

    @Test
    func storedMainDisplayStaysAtOriginWithoutThePrimary() throws {
        let stored = config(
            entry(Self.left, info(wide: 3360, high: 1890, x: -3360)),
            entry(Self.right, info(wide: 3360, high: 1890)))

        let result = try update([currentLayout(), stored], pinning: [Self.left, Self.right])

        let entries = try layout(of: [Self.left, Self.right], in: result.configs)
        #expect(try current(Self.right, in: entries)["OriginX"] as? Double == 0)
        #expect(try current(Self.left, in: entries)["OriginX"] as? Double == -3360)
    }

    @Test
    func mirroredLayoutsAreSkipped() throws {
        var mirrored = entry(Self.right, info(wide: 1920, high: 1080))
        mirrored["MasterUUID"] = Self.laptop.uuidString
        let stored = config(entry(Self.laptop, info(wide: 1920, high: 1080)), mirrored)

        let result = try update([currentLayout(), stored], pinning: [Self.laptop, Self.right])

        let entries = try layout(of: [Self.laptop, Self.right], in: result.configs)
        #expect(try current(Self.right, in: entries)["Wide"] as? Double == 1920)
    }

    @Test
    func placeholderUnmirrorInfoIsNotMirroring() throws {
        let stale = config(
            entry(Self.left, info(wide: 3840, high: 2160, x: -3840), unmirror: info(wide: 1, high: 1)),
            entry(Self.laptop, info(wide: 1728, high: 1117)))

        let result = try update([currentLayout(), stale], pinning: [Self.left])

        let entries = try layout(of: [Self.left, Self.laptop], in: result.configs)
        #expect(try current(Self.left, in: entries)["Wide"] as? Double == 3360)
        #expect(try current(Self.left, in: entries)["OriginX"] as? Double == -3360)
    }

    @Test
    func perDisplayPinLeavesCombinationsWithoutThatDisplay() throws {
        let stale = config(entry(Self.left, info(wide: 1920, high: 1080)))

        let result = try update([currentLayout(), stale], pinning: [Self.right])

        let entries = try layout(of: [Self.left], in: result.configs)
        #expect(try current(Self.left, in: entries)["Wide"] as? Double == 1920)
    }

    @Test
    func secondRunAfterPerDisplayPinOverStaleLayoutsChangesNothing() throws {
        let stale = config(
            entry(Self.laptop, info(wide: 2056, high: 1329)),
            entry(Self.right, info(wide: 1920, high: 1080, x: 2056, scale: 1)))
        let first = try update([currentLayout(), stale], pinning: [Self.right])

        #expect(first.changed > 0)
        #expect(try update(first.configs, pinning: [Self.right]).changed == 0)
    }

    @Test
    func stackedDisplayKeepsItsVerticalPosition() throws {
        let displays = try [
            live(Self.laptop, x: 0, size: CGSize(width: 1728, height: 1117), isPrimary: true),
            live(Self.right, x: -800, y: -1890, size: CGSize(width: 3360, height: 1890))
        ]
        let pinned: Set = [Self.right.uuidString]
        let stored = config(
            entry(Self.laptop, info(wide: 1728, high: 1117)),
            entry(Self.right, ["Wide": 3360.0, "High": 1890.0, "OriginX": -800.0, "OriginY": -1890.0]))
        let current = try StoredDisplayLayouts.currentEntries(in: [stored], displays: displays, pinning: pinned)

        let result = try StoredDisplayLayouts.updating([stored], with: current, displays: displays, pinning: pinned)

        let entries = try layout(of: [Self.laptop, Self.right], in: result.configs)
        #expect(try self.current(Self.right, in: entries)["OriginX"] as? Double == -800)
        #expect(try self.current(Self.right, in: entries)["OriginY"] as? Double == -1890)
    }

    @Test
    func newLayoutWithoutThePrimaryCentresOnTheClosestDisplay() throws {
        let displays = try [
            live(Self.left, x: -1000, size: CGSize(width: 1000, height: 800)),
            live(Self.laptop, x: 0, size: CGSize(width: 1728, height: 1117), isPrimary: true),
            live(Self.right, x: 1728, size: CGSize(width: 3360, height: 1890))
        ]
        let pinned = Set(displays.map(\.uuid))
        let stored = config(
            entry(Self.left, info(wide: 1000, high: 800, x: -1000)),
            entry(Self.laptop, info(wide: 1728, high: 1117)),
            entry(Self.right, info(wide: 3360, high: 1890, x: 1728)))
        let current = try StoredDisplayLayouts.currentEntries(in: [stored], displays: displays, pinning: pinned)

        let result = try StoredDisplayLayouts.updating([stored], with: current, displays: displays, pinning: pinned)

        let entries = try layout(of: [Self.left, Self.right], in: result.configs)
        #expect(try self.current(Self.left, in: entries)["OriginX"] as? Double == 0)
        #expect(try self.current(Self.right, in: entries)["OriginX"] as? Double == 1000)
    }

    @Test
    func unknownLayoutFormatWritesNothing() throws {
        let broken: Plist = ["DisplayConfig": [["UUID": Self.right.uuidString]]]

        #expect(throws: StoredLayoutError.unexpectedFormat) {
            try update([currentLayout(), broken], pinning: [Self.right])
        }
    }

    @Test
    func noStoredCurrentLayoutThrows() {
        let onlyOne = config(entry(Self.right, info(wide: 3360, high: 1890)))

        #expect(throws: StoredLayoutError.noStoredLayoutForCurrentDisplays) {
            try update([onlyOne], pinning: [Self.right])
        }
    }

    @Test
    func storedModeBehindLiveModeThrows() {
        let behind = config(
            entry(Self.left, info(wide: 3360, high: 1890, x: -3360)),
            entry(Self.laptop, info(wide: 1728, high: 1117)),
            entry(Self.right, info(wide: 1920, high: 1080, x: 1728)))

        #expect(throws: StoredLayoutError.storedModeOutOfDate) {
            try update([behind], pinning: [Self.right])
        }
    }

    @Test
    func packingKeepsOffsetsOfOverlappingDisplays() {
        let packed = StoredDisplayLayouts.packed(
            starts: [0, 100],
            liveLengths: [1000, 1000],
            lengths: [1000, 1000])

        #expect(packed == [0, 100])
    }

    @Test
    func packingPushesNeighboursOutWhenADisplayGrows() {
        let packed = StoredDisplayLayouts.packed(
            starts: [0, 1000],
            liveLengths: [1000, 1000],
            lengths: [1500, 1000])

        #expect(packed == [0, 1500])
    }

    @Test
    func packingWorksLeftOfTheOrigin() {
        let packed = StoredDisplayLayouts.packed(
            starts: [-6000, -3360],
            liveLengths: [2640, 3360],
            lengths: [1000, 3360])

        #expect(packed == [-6000, -5000])
    }
}
