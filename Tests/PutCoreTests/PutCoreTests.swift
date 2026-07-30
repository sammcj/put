import CoreGraphics
import Foundation
@testable import PutCore
import Testing

@Suite("Schema version")
struct SchemaVersionTests {
    @Test
    func schemaVersionIsAtLeastOne() {
        #expect(putSchemaVersion >= 1)
    }
}

@Suite("UnitRect")
struct UnitRectTests {
    @Test
    func zeroAndFullConstants() {
        #expect(UnitRect.zero.isNormalised)
        #expect(UnitRect.full.isNormalised)
    }

    @Test
    func clampingShrinksRectLargerThanDisplayAndSlidesToFit() {
        // height 2.0 exceeds the display, so it clamps to the full extent (1);
        // filling the display vertically forces the origin to 0. width 0.5 fits,
        // and the already-negative x slides to 0.
        let clamped = UnitRect(x: -0.1, y: 1.2, width: 0.5, height: 2.0).clamped()
        #expect(clamped.x == 0)
        #expect(clamped.y == 0)
        #expect(clamped.width == 0.5)
        #expect(clamped.height == 1)
        #expect(clamped.isNormalised)
    }

    @Test
    func clampingSlidesOverhangingRectWithoutShrinkingIt() {
        // An origin near the far edge slides back so x + width <= 1 (and
        // y + height <= 1) while preserving the window's size, rather than
        // shrinking the extent and distorting the proportional fallback.
        let clamped = UnitRect(x: 0.95, y: 0.9, width: 0.3, height: 0.25).clamped()
        #expect(abs(clamped.x - 0.7) < 1e-9)
        #expect(abs(clamped.y - 0.75) < 1e-9)
        #expect(clamped.width == 0.3)
        #expect(clamped.height == 0.25)
        #expect(clamped.isNormalised)
    }

    @Test
    func codableRoundtrip() throws {
        let original = UnitRect(x: 0.25, y: 0.5, width: 0.3, height: 0.2)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(UnitRect.self, from: data)
        #expect(decoded == original)
    }
}

@Suite("DisplayFingerprint")
struct DisplayFingerprintTests {
    private func sampleFingerprint(
        uuid: UUID? = UUID(),
        pointSize: CGSize = CGSize(width: 1920, height: 1200),
        pixelSize: CGSize = CGSize(width: 3840, height: 2400),
        scale: Double = 2.0,
        origin: CGPoint = .zero,
        isPrimary: Bool = true) -> DisplayFingerprint
    {
        DisplayFingerprint(
            uuid: uuid,
            vendorID: 0x0610,
            productID: 0xA123,
            serialNumber: 42,
            pointSize: pointSize,
            pixelSize: pixelSize,
            scaleFactor: scale,
            globalOrigin: origin,
            isPrimary: isPrimary,
            localizedName: "Test Display")
    }

    @Test
    func identityPrefersUUID() {
        let fp = sampleFingerprint()
        #expect(fp.id.hasPrefix("uuid:"))
    }

    @Test
    func identityFallsBackToVendorTupleWhenNoUUID() {
        let fp = sampleFingerprint(uuid: nil)
        #expect(fp.id.hasPrefix("vps:"))
    }

    @Test
    func identityFallsBackToGeometryWhenNoVendor() {
        let fp = DisplayFingerprint(
            uuid: nil,
            vendorID: nil,
            productID: nil,
            serialNumber: nil,
            pointSize: CGSize(width: 1024, height: 768),
            pixelSize: CGSize(width: 1024, height: 768),
            scaleFactor: 1,
            globalOrigin: CGPoint(x: 100, y: 200),
            isPrimary: false)
        #expect(fp.id.hasPrefix("geo:"))
    }

    @Test
    func sameGeometryMatchesOnResolutionScale() {
        let original = sampleFingerprint()
        let replacement = sampleFingerprint(uuid: UUID())
        #expect(original.sameGeometry(as: replacement))
    }

    @Test
    func sameGeometryRejectsResolutionChange() {
        let original = sampleFingerprint()
        let different = sampleFingerprint(pointSize: CGSize(width: 1440, height: 900))
        #expect(!original.sameGeometry(as: different))
    }

    @Test
    func sameGeometryRejectsScaleChange() {
        let original = sampleFingerprint(scale: 2.0)
        let different = sampleFingerprint(scale: 1.5)
        #expect(!original.sameGeometry(as: different))
    }

    @Test
    func codableRoundtrip() throws {
        let fp = sampleFingerprint()
        let data = try JSONEncoder().encode(fp)
        let decoded = try JSONDecoder().decode(DisplayFingerprint.self, from: data)
        #expect(decoded == fp)
    }
}

@Suite("MatchCriteria")
struct MatchCriteriaTests {
    @Test
    func defaultsAreConservative() {
        let criteria = MatchCriteria(bundleID: "com.apple.Calendar")
        #expect(criteria.titlePattern.isEmpty)
        #expect(criteria.titleMatchMode == .literal)
        #expect(!criteria.useTitlePatternExclusively)
        #expect(criteria.axRole == nil)
        #expect(!criteria.applyToAllWindows)
    }

    @Test
    func codableRoundtrip() throws {
        let criteria = MatchCriteria(
            bundleID: "com.apple.Safari",
            titlePattern: "^GitHub",
            titleMatchMode: .regex,
            useTitlePatternExclusively: true,
            axRole: "AXStandardWindow",
            applyToAllWindows: false)
        let data = try JSONEncoder().encode(criteria)
        let decoded = try JSONDecoder().decode(MatchCriteria.self, from: data)
        #expect(decoded == criteria)
    }

    @Test
    func identityKeyIgnoresMatchModeAndExclusivity() {
        // Match mode and exclusivity describe how the title is matched, not
        // which window is targeted. With no role set (role unevaluated either
        // way), toggling them must not split the dedupe key.
        let literal = MatchCriteria(
            bundleID: "com.apple.Safari",
            titlePattern: "GitHub",
            titleMatchMode: .literal,
            useTitlePatternExclusively: false)
        let regex = MatchCriteria(
            bundleID: "com.apple.Safari",
            titlePattern: "GitHub",
            titleMatchMode: .regex,
            useTitlePatternExclusively: true)
        #expect(literal.identityKey == regex.identityKey)
    }

    @Test
    func identityKeyIgnoresTitlePatternWhenApplyToAll() {
        let withFoo = MatchCriteria(bundleID: "com.apple.Safari", titlePattern: "foo", applyToAllWindows: true)
        let withBar = MatchCriteria(bundleID: "com.apple.Safari", titlePattern: "bar", applyToAllWindows: true)
        #expect(withFoo.identityKey == withBar.identityKey)
    }

    @Test
    func identityKeyIgnoresRoleWhenApplyToAll() {
        // RuleMatcher returns on bundleID alone under applyToAllWindows, so role
        // is not evaluated and must not split the dedupe key.
        let withRole = MatchCriteria(
            bundleID: "com.apple.Safari",
            axRole: "AXStandardWindow",
            applyToAllWindows: true)
        let withoutRole = MatchCriteria(bundleID: "com.apple.Safari", applyToAllWindows: true)
        #expect(withRole.identityKey == withoutRole.identityKey)
    }

    @Test
    func identityKeyIgnoresRoleWhenTitlePatternExclusive() {
        // RuleMatcher skips the role check under useTitlePatternExclusively, so
        // role must not split the dedupe key in that branch either.
        let withRole = MatchCriteria(
            bundleID: "com.apple.Safari",
            titlePattern: "GitHub",
            useTitlePatternExclusively: true,
            axRole: "AXStandardWindow")
        let withoutRole = MatchCriteria(
            bundleID: "com.apple.Safari",
            titlePattern: "GitHub",
            useTitlePatternExclusively: true)
        #expect(withRole.identityKey == withoutRole.identityKey)
    }

    @Test
    func identityKeyPreservesRoleWhenRoleIsEvaluated() {
        // Default mode evaluates role, so two rules differing only by role
        // target different windows and must keep distinct dedupe keys.
        let standard = MatchCriteria(bundleID: "com.apple.Safari", titlePattern: "GitHub", axRole: "AXStandardWindow")
        let dialog = MatchCriteria(bundleID: "com.apple.Safari", titlePattern: "GitHub", axRole: "AXDialog")
        #expect(standard.identityKey != dialog.identityKey)
    }

    @Test
    func identityKeyTreatsApplyToAllAsDistinct() {
        let specific = MatchCriteria(bundleID: "com.apple.Safari", titlePattern: "X")
        let broad = MatchCriteria(
            bundleID: "com.apple.Safari",
            titlePattern: "X",
            applyToAllWindows: true)
        #expect(specific.identityKey != broad.identityKey)
    }
}

@Suite("Rule and Layout")
struct RuleLayoutTests {
    @Test
    func ruleCodableRoundtrip() throws {
        let fp = DisplayFingerprint(
            uuid: UUID(),
            vendorID: nil,
            productID: nil,
            serialNumber: nil,
            pointSize: CGSize(width: 1920, height: 1080),
            pixelSize: CGSize(width: 1920, height: 1080),
            scaleFactor: 1,
            globalOrigin: .zero,
            isPrimary: true)
        let frame = WindowFrame(
            absolute: CGRect(x: 100, y: 120, width: 800, height: 600),
            normalised: UnitRect(x: 0.05, y: 0.1, width: 0.4, height: 0.5))
        let rule = Rule(
            descriptiveLabel: "Main Safari window",
            matchCriteria: MatchCriteria(bundleID: "com.apple.Safari"),
            targetDisplay: fp,
            frame: frame)
        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(Rule.self, from: data)
        #expect(decoded == rule)
    }

    @Test
    func ruleRestoreScopeDefaultsToSizeAndPosition() throws {
        // Rule's default initializer and the JSON decoder must both yield
        // .sizeAndPosition so existing on-disk configs keep their current
        // behaviour after the schema gains the new field.
        let fp = DisplayFingerprint(
            uuid: UUID(),
            vendorID: nil,
            productID: nil,
            serialNumber: nil,
            pointSize: CGSize(width: 1920, height: 1080),
            pixelSize: CGSize(width: 1920, height: 1080),
            scaleFactor: 1,
            globalOrigin: .zero,
            isPrimary: true)
        let frame = WindowFrame(
            absolute: CGRect(x: 100, y: 100, width: 800, height: 600),
            normalised: UnitRect(x: 0.05, y: 0.1, width: 0.4, height: 0.5))
        let rule = Rule(
            matchCriteria: MatchCriteria(bundleID: "com.apple.Safari"),
            targetDisplay: fp,
            frame: frame)
        #expect(rule.restoreScope == .sizeAndPosition)

        // Legacy JSON predating both fields round-trips as .sizeAndPosition.
        let frameJSON = try String(data: JSONEncoder().encode(frame), encoding: .utf8) ?? "{}"
        let fpJSON = try String(data: JSONEncoder().encode(fp), encoding: .utf8) ?? "{}"
        let criteriaJSON = try String(
            data: JSONEncoder().encode(MatchCriteria(bundleID: "com.apple.Safari")),
            encoding: .utf8) ?? "{}"
        let json = """
        {
            "id": "\(rule.id.uuidString)",
            "descriptiveLabel": "",
            "matchCriteria": \(criteriaJSON),
            "targetDisplay": \(fpJSON),
            "frame": \(frameJSON),
            "missingDisplayPolicy": "primaryProportional",
            "isEnabled": true
        }
        """
        let decoded = try JSONDecoder().decode(Rule.self, from: Data(json.utf8))
        #expect(decoded.restoreScope == .sizeAndPosition)
    }

    @Test
    func ruleRestoreScopeDecodesLegacyRestoresPositionFlag() throws {
        // Configs written between the size-only feature and the display-only
        // scope carry `restoresPosition` and no `restoreScope`; false must map
        // to .sizeOnly, not silently widen back to a full restore.
        let fp = DisplayFingerprint(
            uuid: UUID(),
            vendorID: nil,
            productID: nil,
            serialNumber: nil,
            pointSize: CGSize(width: 1920, height: 1080),
            pixelSize: CGSize(width: 1920, height: 1080),
            scaleFactor: 1,
            globalOrigin: .zero,
            isPrimary: true)
        let frame = WindowFrame(
            absolute: CGRect(x: 100, y: 100, width: 800, height: 600),
            normalised: UnitRect(x: 0.05, y: 0.1, width: 0.4, height: 0.5))
        let frameJSON = try String(data: JSONEncoder().encode(frame), encoding: .utf8) ?? "{}"
        let fpJSON = try String(data: JSONEncoder().encode(fp), encoding: .utf8) ?? "{}"
        let criteriaJSON = try String(
            data: JSONEncoder().encode(MatchCriteria(bundleID: "com.apple.Safari")),
            encoding: .utf8) ?? "{}"
        let json = """
        {
            "id": "\(UUID().uuidString)",
            "descriptiveLabel": "",
            "matchCriteria": \(criteriaJSON),
            "targetDisplay": \(fpJSON),
            "frame": \(frameJSON),
            "missingDisplayPolicy": "primaryProportional",
            "isEnabled": true,
            "restoresPosition": false
        }
        """
        let decoded = try JSONDecoder().decode(Rule.self, from: Data(json.utf8))
        #expect(decoded.restoreScope == .sizeOnly)
    }

    @Test
    func ruleEncodesLegacyRestoresPositionAlongsideScope() throws {
        // The legacy key is still written so a config round-tripping through an
        // older build degrades to size-only rather than re-asserting a position
        // the user deliberately gave up.
        let fp = DisplayFingerprint(
            uuid: UUID(),
            vendorID: nil,
            productID: nil,
            serialNumber: nil,
            pointSize: CGSize(width: 1920, height: 1080),
            pixelSize: CGSize(width: 1920, height: 1080),
            scaleFactor: 1,
            globalOrigin: .zero,
            isPrimary: true)
        let rule = Rule(
            matchCriteria: MatchCriteria(bundleID: "com.apple.Safari"),
            targetDisplay: fp,
            frame: WindowFrame(
                absolute: CGRect(x: 100, y: 100, width: 800, height: 600),
                normalised: UnitRect(x: 0.05, y: 0.1, width: 0.4, height: 0.5)),
            restoreScope: .displayOnly)
        let object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(rule)) as? [String: Any]
        #expect(object?["restoreScope"] as? String == "displayOnly")
        #expect(object?["restoresPosition"] as? Bool == false)
    }

    @Test
    func ruleRestoreScopeRoundtrips() throws {
        let fp = DisplayFingerprint(
            uuid: UUID(),
            vendorID: nil,
            productID: nil,
            serialNumber: nil,
            pointSize: CGSize(width: 1920, height: 1080),
            pixelSize: CGSize(width: 1920, height: 1080),
            scaleFactor: 1,
            globalOrigin: .zero,
            isPrimary: true)
        let frame = WindowFrame(
            absolute: CGRect(x: 100, y: 100, width: 800, height: 600),
            normalised: UnitRect(x: 0.05, y: 0.1, width: 0.4, height: 0.5))
        let rule = Rule(
            matchCriteria: MatchCriteria(bundleID: "com.apple.Safari"),
            targetDisplay: fp,
            frame: frame,
            restoreScope: .displayOnly)
        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(Rule.self, from: data)
        #expect(decoded.restoreScope == .displayOnly)
        #expect(decoded == rule)
    }

    @Test
    func layoutDefaultsAreReasonable() {
        let layout = Layout.defaultLayout()
        #expect(layout.name == "Default")
        #expect(layout.rules.isEmpty)
        #expect(layout.activationShortcutID == nil)
    }

    @Test
    func duplicatedLayoutHasFreshIdentityAndDropsTriggers() {
        let fp = DisplayFingerprint(
            uuid: UUID(),
            vendorID: nil,
            productID: nil,
            serialNumber: nil,
            pointSize: CGSize(width: 1920, height: 1080),
            pixelSize: CGSize(width: 1920, height: 1080),
            scaleFactor: 1,
            globalOrigin: .zero,
            isPrimary: true)
        let frame = WindowFrame(
            absolute: CGRect(x: 0, y: 0, width: 800, height: 600),
            normalised: UnitRect(x: 0, y: 0, width: 0.5, height: 0.5))
        let ruleA = Rule(
            descriptiveLabel: "A",
            matchCriteria: MatchCriteria(bundleID: "com.apple.Safari"),
            targetDisplay: fp,
            frame: frame)
        let ruleB = Rule(
            descriptiveLabel: "B",
            matchCriteria: MatchCriteria(bundleID: "com.apple.mail"),
            targetDisplay: fp,
            frame: frame)
        let original = Layout(
            name: "Work",
            rules: [ruleA, ruleB],
            activationShortcutID: "layout.work",
            screenConfigs: [])

        let copy = original.duplicated(name: "COPY OF Work")

        #expect(copy.name == "COPY OF Work")
        #expect(copy.id != original.id)
        #expect(copy.activationShortcutID == nil)
        #expect(copy.screenConfigs.isEmpty)
        #expect(copy.rules.count == original.rules.count)
        #expect(copy.rules[0].id != original.rules[0].id)
        #expect(copy.rules[1].id != original.rules[1].id)
        // Non-identity rule fields must be preserved verbatim.
        #expect(copy.rules[0].descriptiveLabel == "A")
        #expect(copy.rules[0].matchCriteria == original.rules[0].matchCriteria)
        #expect(copy.rules[0].frame == original.rules[0].frame)
        #expect(copy.rules[1].descriptiveLabel == "B")
    }
}

@Suite("Config")
struct ConfigTests {
    @Test
    func bootstrapHasOneActiveLayout() {
        let config = Config.bootstrap()
        #expect(config.layouts.count == 1)
        #expect(config.activeLayoutID == config.layouts[0].id)
        #expect(config.schemaVersion == putSchemaVersion)
        #expect(config.defaultMissingDisplayPolicy == .primaryProportional)
    }

    @Test
    func resolvedActiveLayoutFallsBackWhenIDIsStale() {
        let bogusID = UUID()
        let layout = Layout.defaultLayout()
        let config = Config(
            layouts: [layout],
            activeLayoutID: bogusID)
        #expect(config.resolvedActiveLayout()?.id == layout.id)
    }

    @Test
    func configCodableRoundtrip() throws {
        let config = Config.bootstrap()
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(Config.self, from: data)
        #expect(decoded == config)
    }

    @Test
    func bootstrapLeavesFirstRunCompletedAtNil() {
        #expect(Config.bootstrap().firstRunCompletedAt == nil)
    }

    @Test
    func firstRunCompletedAtRoundtripsWhenSet() throws {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let layout = Layout.defaultLayout()
        let config = Config(
            layouts: [layout],
            activeLayoutID: layout.id,
            firstRunCompletedAt: stamp)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            Config.self,
            from: encoder.encode(config))
        #expect(decoded.firstRunCompletedAt == stamp)
        #expect(decoded == config)
    }

    @Test
    func legacyConfigWithoutFirstRunDecodesToNil() throws {
        // JSON predating the field — decoder must accept it and leave the
        // new optional `nil`. Guards against breaking existing on-disk
        // configs when the schema gains optional fields.
        let layout = Layout.defaultLayout()
        let json = try """
        {
            "schemaVersion": \(putSchemaVersion),
            "layouts": [\(String(data: JSONEncoder().encode(layout), encoding: .utf8) ?? "{}")],
            "activeLayoutID": "\(layout.id.uuidString)"
        }
        """
        let decoded = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(decoded.firstRunCompletedAt == nil)
    }
}
