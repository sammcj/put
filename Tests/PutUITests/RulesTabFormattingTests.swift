import PutCore
import PutTestSupport
@testable import PutUI
import Testing

@MainActor
@Suite("RulesTab.subtitle")
struct RulesTabFormattingTests {
    @Test
    func applyToAllWindowsTakesPrecedence() {
        let rule = makeRule(titlePattern: "ignored", applyToAllWindows: true)
        #expect(RulesTab.subtitle(for: rule) == "All windows")
    }

    @Test
    func emptyTitleReadsAsAnyTitle() {
        let rule = makeRule(titlePattern: "")
        #expect(RulesTab.subtitle(for: rule) == "Any title")
    }

    @Test
    func literalTitleIsPrefixedWithEquals() {
        let rule = makeRule(titlePattern: "Inbox", titleMatchMode: .literal)
        #expect(RulesTab.subtitle(for: rule) == "= Inbox")
    }

    @Test
    func regexTitleIsPrefixedWithRe() {
        let rule = makeRule(titlePattern: "^Inbox", titleMatchMode: .regex)
        #expect(RulesTab.subtitle(for: rule) == "re ^Inbox")
    }
}
