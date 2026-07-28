import PutCore

/// Decides when a rule edit in `RulesTab` is written to disk. Every edit to the
/// currently-selected rule schedules a write; the write is debounced by
/// `ConfigPersister` (400ms), so a burst of keystrokes collapses into a single
/// write while an uncommitted edit still can't be lost to a crash with Settings
/// left open. A change of selection (a different rule `id`) is navigation, not
/// an edit, and never writes.
///
/// A plain type so both call paths are unit-testable with a counting `persist`
/// closure, without driving the SwiftUI view.
@MainActor
struct RuleEditPersistence {
    let persist: () -> Void

    /// Continuous-change hook, called from `.onChange(of:)`. Persists any edit
    /// to the same rule (debounced by the persister); skips a selection change.
    /// Returns whether it wrote, for tests.
    @discardableResult
    func fieldChanged(from old: Rule?, to new: Rule?) -> Bool {
        guard let old, let new, old.id == new.id, old != new else { return false }
        persist()
        return true
    }

    /// Commit hook, called from `.onSubmit` when a text field commits (Return).
    /// Always persists the current in-memory rule. On clean quit the persister
    /// flush is the backstop for any edit not yet written.
    func committed() {
        persist()
    }
}
