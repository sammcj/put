import CoreGraphics
import Foundation
import PutCore
import PutTestSupport
@testable import PutUI
import Testing

@MainActor
@Suite("RuleEditPersistence")
struct RuleEditPersistenceTests {
    @Test
    func editingATextFieldSchedulesAWrite() {
        // A text edit schedules a write (the persister debounces at 400ms, so a
        // keystroke burst still collapses to one write). Regression guard: pre-
        // fix these waited for Return and were lost on a crash with Settings open.
        var writes = 0
        let persistence = RuleEditPersistence(persist: { writes += 1 })
        let base = makeRule(titlePattern: "Sa")
        var typed = base
        typed.matchCriteria.titlePattern = "Saf"

        let wrote = persistence.fieldChanged(from: base, to: typed)

        #expect(wrote)
        #expect(writes == 1)
    }

    @Test
    func editingAFrameFieldSchedulesAWrite() {
        // Coordinate edits (X/Y/W/H) are free-text too; they must persist rather
        // than wait for a commit that a coordinate field never emits.
        var writes = 0
        let persistence = RuleEditPersistence(persist: { writes += 1 })
        let base = makeRule()
        var moved = base
        moved.frame.absolute = CGRect(x: 10, y: 20, width: 800, height: 600)

        #expect(persistence.fieldChanged(from: base, to: moved))
        #expect(writes == 1)
    }

    @Test
    func committingWritesOnce() {
        var writes = 0
        let persistence = RuleEditPersistence(persist: { writes += 1 })

        persistence.committed()

        #expect(writes == 1)
    }

    @Test
    func editingADiscreteFieldSchedulesAWrite() {
        var writes = 0
        let persistence = RuleEditPersistence(persist: { writes += 1 })
        let base = makeRule(isEnabled: true)
        var toggled = base
        toggled.isEnabled = false

        let wrote = persistence.fieldChanged(from: base, to: toggled)

        #expect(wrote)
        #expect(writes == 1)
    }

    @Test
    func selectingADifferentRuleDoesNotWrite() {
        var writes = 0
        let persistence = RuleEditPersistence(persist: { writes += 1 })
        let ruleA = makeRule(isEnabled: true)
        let ruleB = makeRule(isEnabled: false)

        #expect(persistence.fieldChanged(from: ruleA, to: ruleB) == false)
        #expect(writes == 0)
    }

    @Test
    func nilTransitionsDoNotWrite() {
        var writes = 0
        let persistence = RuleEditPersistence(persist: { writes += 1 })
        let rule = makeRule()

        #expect(persistence.fieldChanged(from: nil, to: rule) == false)
        #expect(persistence.fieldChanged(from: rule, to: nil) == false)
        #expect(writes == 0)
    }

    @Test
    func noEditToTheSameRuleDoesNotWrite() {
        // An `.onChange` that fires with an unchanged rule (same id, equal value)
        // must not schedule a redundant write.
        var writes = 0
        let persistence = RuleEditPersistence(persist: { writes += 1 })
        let rule = makeRule()

        #expect(persistence.fieldChanged(from: rule, to: rule) == false)
        #expect(writes == 0)
    }
}
