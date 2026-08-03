import CoreGraphics
import Foundation
@testable import PutAutomation
@testable import PutCore
import PutTestSupport
@testable import PutWindows
import Testing

/// Per-rule trigger gating: `autoPlace` and `includeInRestoreAll` decide which
/// restore sources apply a rule, while the sources naming a specific window or
/// layout always do. `ActionCoordinator.restore(windows:source:)` has the one
/// call site of `RuleSelection.resolve`.
@Suite("Restore trigger gating")
struct RestoreTriggerGatingTests {
    // MARK: - Which source consults which flag

    @Test
    func autoPlaceGatesOnlyAutomaticSources() {
        let rule = makeRule(autoPlace: false)
        #expect(!rule.applies(to: .auto))
        #expect(rule.applies(to: .explicitAll))
        #expect(rule.applies(to: .explicit))
    }

    @Test
    func includeInRestoreAllGatesOnlyTheRestoreAllSource() {
        let rule = makeRule(includeInRestoreAll: false)
        #expect(rule.applies(to: .auto))
        #expect(!rule.applies(to: .explicitAll))
        #expect(rule.applies(to: .explicit))
    }

    @Test
    func bothFlagsOffStillLeavesTheExplicitSource() {
        // The point of the pair: keep the saved placement, apply it only when
        // the user names this window.
        let rule = makeRule(autoPlace: false, includeInRestoreAll: false)
        #expect(!rule.applies(to: .auto))
        #expect(!rule.applies(to: .explicitAll))
        #expect(rule.applies(to: .explicit))
    }

    @Test
    func defaultRuleAppliesToEverySource() {
        let rule = makeRule()
        #expect(rule.applies(to: .auto))
        #expect(rule.applies(to: .explicitAll))
        #expect(rule.applies(to: .explicit))
    }

    // MARK: - Selecting the rule that owns a window

    @Test
    func anOptedOutRuleStillOwnsItsWindow() {
        // Matching runs before gating. Were it the other way round, opting the
        // specific rule out of automatic placement would let the bundle-wide
        // rule it was written to override move the window anyway.
        let specific = makeRule(titlePattern: "Doc.txt", applyToAllWindows: false, autoPlace: false)
        let broad = makeRule(applyToAllWindows: true)

        let selection = RuleSelection.resolve(
            for: descriptor(),
            in: [specific, broad],
            source: .auto)

        #expect(selection == .optedOut(specific))
    }

    @Test
    func theSameRuleAppliesWhenItsTriggerIsOn() {
        let specific = makeRule(titlePattern: "Doc.txt", applyToAllWindows: false, autoPlace: false)
        let broad = makeRule(applyToAllWindows: true)

        let selection = RuleSelection.resolve(
            for: descriptor(),
            in: [specific, broad],
            source: .explicit)

        #expect(selection == .apply(specific))
    }

    @Test
    func aDisabledRuleIsSkippedBeforeItsTriggersAreConsulted() {
        // `isEnabled` is the older, blunter opt-out and still wins outright: a
        // disabled rule doesn't own its window, so a later rule can match.
        var disabled = makeRule(titlePattern: "Doc.txt", applyToAllWindows: false)
        disabled.isEnabled = false
        let broad = makeRule(applyToAllWindows: true)

        let selection = RuleSelection.resolve(
            for: descriptor(),
            in: [disabled, broad],
            source: .auto)

        #expect(selection == .apply(broad))
    }

    @Test
    func noMatchingRuleIsUnmatched() {
        let other = makeRule(bundleID: "com.other.app")

        let selection = RuleSelection.resolve(
            for: descriptor(),
            in: [other],
            source: .auto)

        #expect(selection == .unmatched)
    }

    // MARK: - Fixtures

    private func descriptor(
        bundleID: String = "com.example.one",
        title: String = "Doc.txt") -> WindowDescriptor
    {
        makeWindowHandle(
            bundleID: bundleID,
            title: title,
            frame: CGRect(x: 100, y: 100, width: 600, height: 400)).descriptor
    }

    private func makeRule(
        bundleID: String = "com.example.one",
        titlePattern: String = "",
        applyToAllWindows: Bool = true,
        autoPlace: Bool = true,
        includeInRestoreAll: Bool = true) -> Rule
    {
        Rule(
            matchCriteria: MatchCriteria(
                bundleID: bundleID,
                titlePattern: titlePattern,
                applyToAllWindows: applyToAllWindows),
            targetDisplay: DisplayFingerprint(
                uuid: UUID(),
                vendorID: 1,
                productID: 2,
                serialNumber: 3,
                pointSize: CGSize(width: 1920, height: 1080),
                pixelSize: CGSize(width: 1920, height: 1080),
                scaleFactor: 1,
                globalOrigin: .zero,
                isPrimary: true),
            frame: WindowFrame(
                absolute: CGRect(x: 0, y: 0, width: 400, height: 300),
                normalised: UnitRect(x: 0, y: 0, width: 0.2, height: 0.3)),
            autoPlace: autoPlace,
            includeInRestoreAll: includeInRestoreAll)
    }
}
