import CoreGraphics
import Foundation
@testable import PutCore
import PutTestSupport
import Testing

private func makeFingerprint(
    uuid: UUID? = UUID(),
    vendor: UInt32? = 0x0610,
    product: UInt32? = 0xA123,
    serial: UInt32? = 42,
    pointSize: CGSize = CGSize(width: 1920, height: 1200),
    origin: CGPoint = .zero,
    isPrimary: Bool = true,
    name: String? = "Test Display") -> DisplayFingerprint
{
    makeDisplayFingerprint(
        uuid: uuid,
        vendorID: vendor,
        productID: product,
        serialNumber: serial,
        pointSize: pointSize,
        pixelSize: CGSize(width: pointSize.width * 2, height: pointSize.height * 2),
        scaleFactor: 2.0,
        globalOrigin: origin,
        isPrimary: isPrimary,
        localizedName: name)
}

@Suite("ScreenConfigTrigger")
struct ScreenConfigTriggerTests {
    @Test
    func defaultsAreStrictAndAuto() {
        let trigger = ScreenConfigTrigger(displays: [makeFingerprint()])
        #expect(trigger.arrangementStrict == true)
        #expect(trigger.autoActivate == true)
    }

    @Test
    func codableRoundtrip() throws {
        // Fixed integer-second timestamp avoids ISO8601's loss of sub-second
        // precision making round-trip equality flaky.
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let trigger = ScreenConfigTrigger(
            displays: [makeFingerprint(), makeFingerprint(uuid: UUID(), name: "Second")],
            arrangementStrict: false,
            autoActivate: false,
            capturedAt: stamp)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(trigger)
        let decoded = try decoder.decode(ScreenConfigTrigger.self, from: data)
        #expect(decoded == trigger)
    }

    @Test
    func decodesWithoutOptionalFlags() throws {
        // Configs written before a future field is added must still decode.
        // CGSize/CGPoint encode as `[width, height]` / `[x, y]` arrays under
        // the default Codable conformance, which is what we mirror here.
        let id = UUID().uuidString
        let json = """
        {
            "displays": [{
                "uuid": "\(id)",
                "pointSize": [1920, 1200],
                "pixelSize": [3840, 2400],
                "scaleFactor": 2.0,
                "globalOrigin": [0, 0],
                "isPrimary": true
            }]
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ScreenConfigTrigger.self, from: Data(json.utf8))
        #expect(decoded.arrangementStrict == true)
        #expect(decoded.autoActivate == true)
        #expect(decoded.displays.count == 1)
    }
}

@Suite("Layout screenConfigs")
struct LayoutScreenConfigTests {
    @Test
    func legacyLayoutWithoutScreenConfigDecodes() throws {
        // JSON predating any trigger — the field must default to an empty
        // array. This protects existing on-disk configs from breaking when a
        // user upgrades to a Put build that introduces triggers.
        let id = UUID().uuidString
        let json = """
        {
            "id": "\(id)",
            "name": "Office",
            "rules": [],
            "activationShortcutID": null
        }
        """
        let decoded = try JSONDecoder().decode(Layout.self, from: Data(json.utf8))
        #expect(decoded.screenConfigs.isEmpty)
        #expect(decoded.name == "Office")
    }

    @Test
    func legacySingleScreenConfigFoldsIntoArray() throws {
        // Schema <= 2 wrote a single `screenConfig`. The decoder must lift it
        // into the first element of `screenConfigs`.
        let id = UUID().uuidString
        let displayID = UUID().uuidString
        let json = """
        {
            "id": "\(id)",
            "name": "Office",
            "rules": [],
            "screenConfig": {
                "displays": [{
                    "uuid": "\(displayID)",
                    "pointSize": [1920, 1200],
                    "pixelSize": [3840, 2400],
                    "scaleFactor": 2.0,
                    "globalOrigin": [0, 0],
                    "isPrimary": true
                }],
                "arrangementStrict": false,
                "autoActivate": false
            }
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Layout.self, from: Data(json.utf8))
        #expect(decoded.screenConfigs.count == 1)
        #expect(decoded.screenConfigs.first?.arrangementStrict == false)
        #expect(decoded.screenConfigs.first?.autoActivate == false)
    }

    @Test
    func layoutCodableRoundtripWithTriggers() throws {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let triggerA = ScreenConfigTrigger(displays: [makeFingerprint()], capturedAt: stamp)
        let triggerB = ScreenConfigTrigger(
            displays: [makeFingerprint(uuid: UUID(), name: "Second")],
            arrangementStrict: false,
            capturedAt: stamp)
        let layout = Layout(name: "Office", screenConfigs: [triggerA, triggerB])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(layout)
        let decoded = try decoder.decode(Layout.self, from: data)
        #expect(decoded == layout)
    }

    @Test
    func layoutWithoutScreenConfigsCoversEveryDisplay() {
        // Hotkey-only layout declares no scope, so it never blocks a save.
        let layout = Layout(name: "Anywhere")
        #expect(layout.expectedDisplayIDs.isEmpty)
        #expect(layout.coversDisplay(makeFingerprint().id))
        #expect(layout.coversDisplay("geo:0:0:1920x1080"))
    }

    @Test
    func layoutCoversOnlyDisplaysInItsScreenConfigs() {
        let builtIn = makeFingerprint(uuid: UUID(), name: "Built-in")
        let external = makeFingerprint(uuid: UUID(), name: "External")
        let layout = Layout(name: "Laptop only", screenConfigs: [ScreenConfigTrigger(displays: [builtIn])])
        #expect(layout.expectedDisplayIDs == [builtIn.id])
        #expect(layout.coversDisplay(builtIn.id))
        #expect(!layout.coversDisplay(external.id))
    }

    @Test
    func layoutScopeIsUnionAcrossScreenConfigs() {
        let laptop = makeFingerprint(uuid: UUID(), name: "Built-in")
        let dock = makeFingerprint(uuid: UUID(), name: "Dock 4K")
        let layout = Layout(
            name: "Home",
            screenConfigs: [
                ScreenConfigTrigger(displays: [laptop]),
                ScreenConfigTrigger(displays: [laptop, dock])
            ])
        #expect(layout.expectedDisplayIDs == [laptop.id, dock.id])
        #expect(layout.coversDisplay(dock.id))
    }
}

@Suite("DisplaySetFormatter")
struct DisplaySetFormatterTests {
    @Test
    func labelListsPrimaryFirst() {
        let primary = makeFingerprint(uuid: UUID(), origin: .zero, isPrimary: true, name: "MacBook Pro built-in")
        let secondary = makeFingerprint(
            uuid: UUID(),
            origin: CGPoint(x: 1920, y: 0),
            isPrimary: false,
            name: "LG UltraFine 27")
        let label = DisplaySetFormatter.label(for: [secondary, primary])
        #expect(label == "MacBook Pro built-in + LG UltraFine 27")
    }

    @Test
    func labelFallsBackToResolution() {
        let unnamed = makeFingerprint(pointSize: CGSize(width: 1024, height: 768), name: nil)
        let label = DisplaySetFormatter.label(for: [unnamed])
        #expect(label == "1024x768 display")
    }

    @Test
    func labelHandlesEmptySet() {
        #expect(DisplaySetFormatter.label(for: []) == "No displays")
    }

    @Test
    func hashIsStableAcrossReorderings() {
        let first = makeFingerprint(uuid: UUID())
        let second = makeFingerprint(uuid: UUID())
        let forwards = DisplaySetFormatter.shortHash(for: [first, second])
        let reversed = DisplaySetFormatter.shortHash(for: [second, first])
        #expect(forwards == reversed)
    }

    @Test
    func hashChangesWhenIdentitySetDiffers() {
        let shared = makeFingerprint(uuid: UUID())
        let firstExtra = makeFingerprint(uuid: UUID())
        let secondExtra = makeFingerprint(uuid: UUID())
        let withFirst = DisplaySetFormatter.shortHash(for: [shared, firstExtra])
        let withSecond = DisplaySetFormatter.shortHash(for: [shared, secondExtra])
        #expect(withFirst != withSecond)
    }

    @Test
    func hashIsConfiguredLength() {
        let hash = DisplaySetFormatter.shortHash(for: [makeFingerprint()])
        #expect(hash.count == DisplaySetFormatter.hashLength)
    }

    @Test
    func labelWithHashCombinesBoth() {
        let display = makeFingerprint(name: "Studio Display")
        let combined = DisplaySetFormatter.labelWithHash(for: [display])
        #expect(combined.hasPrefix("Studio Display ["))
        #expect(combined.hasSuffix("]"))
    }
}

@Suite("Config screen-config conflict")
struct ConfigScreenConfigConflictTests {
    @Test
    func findsLayoutClaimingSameIdentitySet() {
        let display = makeFingerprint()
        let trigger = ScreenConfigTrigger(displays: [display])
        let claimed = Layout(name: "Office", screenConfigs: [trigger])
        let unclaimed = Layout(name: "Home")
        let config = Config(
            layouts: [claimed, unclaimed],
            activeLayoutID: claimed.id)

        let candidate = ScreenConfigTrigger(displays: [display], arrangementStrict: false)
        let found = config.layoutClaimingScreenConfig(identicalTo: candidate, excluding: unclaimed.id)
        #expect(found?.id == claimed.id)
    }

    @Test
    func excludesSelf() {
        let display = makeFingerprint()
        let trigger = ScreenConfigTrigger(displays: [display])
        let layout = Layout(name: "Office", screenConfigs: [trigger])
        let config = Config(layouts: [layout], activeLayoutID: layout.id)

        let found = config.layoutClaimingScreenConfig(identicalTo: trigger, excluding: layout.id)
        #expect(found == nil)
    }

    @Test
    func findsClaimAmongSecondaryTriggers() {
        // A layout's claim must be detected on any of its triggers, not just
        // the first.
        let displayA = makeFingerprint(uuid: UUID())
        let displayB = makeFingerprint(uuid: UUID())
        let claimed = Layout(
            name: "Office",
            screenConfigs: [
                ScreenConfigTrigger(displays: [displayA]),
                ScreenConfigTrigger(displays: [displayB])
            ])
        let config = Config(layouts: [claimed], activeLayoutID: claimed.id)

        let candidate = ScreenConfigTrigger(displays: [displayB])
        #expect(config.layoutClaimingScreenConfig(identicalTo: candidate)?.id == claimed.id)
    }

    @Test
    func returnsNilWhenNoOtherLayoutMatches() {
        let displayA = makeFingerprint(uuid: UUID())
        let displayB = makeFingerprint(uuid: UUID())
        let layout = Layout(name: "Office", screenConfigs: [ScreenConfigTrigger(displays: [displayA])])
        let config = Config(layouts: [layout], activeLayoutID: layout.id)

        let candidate = ScreenConfigTrigger(displays: [displayB])
        #expect(config.layoutClaimingScreenConfig(identicalTo: candidate) == nil)
    }
}
