import CoreGraphics
import Foundation
@testable import PutCore
@testable import PutPlacement
@testable import PutWindows
import Testing

@Suite("RuleMatcher")
struct RuleMatcherTests {
    private func window(bundleID: String, title: String, role: String? = "AXWindow") -> WindowDescriptor {
        WindowDescriptor(
            bundleID: bundleID,
            processID: 42,
            title: title,
            role: role,
            subrole: nil,
            frame: .zero,
            isMinimised: false)
    }

    private func rule(
        bundleID: String,
        titlePattern: String = "",
        mode: TitleMatchMode = .literal,
        exclusive: Bool = false,
        role: String? = nil,
        all: Bool = false) -> Rule
    {
        let display = DisplayFingerprint(
            uuid: UUID(),
            vendorID: nil,
            productID: nil,
            serialNumber: nil,
            pointSize: CGSize(width: 1920, height: 1080),
            pixelSize: CGSize(width: 1920, height: 1080),
            scaleFactor: 1,
            globalOrigin: .zero,
            isPrimary: true)
        return Rule(
            matchCriteria: MatchCriteria(
                bundleID: bundleID,
                titlePattern: titlePattern,
                titleMatchMode: mode,
                useTitlePatternExclusively: exclusive,
                axRole: role,
                applyToAllWindows: all),
            targetDisplay: display,
            frame: WindowFrame(absolute: .zero, normalised: .zero))
    }

    @Test
    func bundleMismatchRejects() {
        let w = window(bundleID: "com.apple.Safari", title: "Hi")
        let testRule = rule(bundleID: "com.apple.Mail")
        #expect(!RuleMatcher.matches(testRule, against: w))
    }

    @Test
    func applyToAllWindowsBypassesTitleAndRole() {
        let w = window(bundleID: "com.apple.Safari", title: "Untitled", role: "AXUnknown")
        let testRule = rule(bundleID: "com.apple.Safari", titlePattern: "Mismatch", role: "AXDialog", all: true)
        #expect(RuleMatcher.matches(testRule, against: w))
    }

    @Test
    func emptyTitlePatternMatchesAny() {
        let w = window(bundleID: "com.apple.Safari", title: "anything")
        let testRule = rule(bundleID: "com.apple.Safari")
        #expect(RuleMatcher.matches(testRule, against: w))
    }

    @Test
    func literalTitleMatchIsExact() {
        let w = window(bundleID: "com.apple.Calendar", title: "Calendar")
        #expect(RuleMatcher.matches(
            rule(bundleID: "com.apple.Calendar", titlePattern: "Calendar"),
            against: w))
        #expect(!RuleMatcher.matches(
            rule(bundleID: "com.apple.Calendar", titlePattern: "calendar"),
            against: w))
    }

    @Test
    func regexTitleMatchHandlesDynamicSuffixes() {
        let w = window(bundleID: "com.github.Desktop", title: "GitHub Desktop - main")
        let testRule = rule(bundleID: "com.github.Desktop", titlePattern: "^GitHub", mode: .regex)
        #expect(RuleMatcher.matches(testRule, against: w))
    }

    @Test
    func regexWithUnicodeSucceeds() {
        let w = window(bundleID: "com.apple.Safari", title: "Gïtä - tab")
        let testRule = rule(bundleID: "com.apple.Safari", titlePattern: "^Gïtä", mode: .regex)
        #expect(RuleMatcher.matches(testRule, against: w))
    }

    @Test
    func invalidRegexFailsClosed() {
        let w = window(bundleID: "com.apple.Safari", title: "anything")
        let testRule = rule(bundleID: "com.apple.Safari", titlePattern: "(unclosed", mode: .regex)
        #expect(!RuleMatcher.matches(testRule, against: w))
    }

    @Test
    func roleMismatchRejectsUnlessExclusive() {
        let w = window(bundleID: "com.apple.Safari", title: "Any", role: "AXWindow")
        let testRule = rule(bundleID: "com.apple.Safari", role: "AXDialog")
        #expect(!RuleMatcher.matches(testRule, against: w))
    }

    @Test
    func useTitlePatternExclusivelyIgnoresRole() {
        let w = window(bundleID: "com.apple.Safari", title: "Any", role: "AXWindow")
        let testRule = rule(bundleID: "com.apple.Safari", titlePattern: "Any", exclusive: true, role: "AXDialog")
        #expect(RuleMatcher.matches(testRule, against: w))
    }

    @Test
    func emptyWindowTitleMatchesEmptyPattern() {
        let w = window(bundleID: "com.apple.Safari", title: "")
        let testRule = rule(bundleID: "com.apple.Safari")
        #expect(RuleMatcher.matches(testRule, against: w))
    }
}
