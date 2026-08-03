import PutCore
import PutPlacement
import PutWindows

/// What kicked off a restore.
///
/// Two things are decided from this. Auto callers honour the moved-by-user
/// suppression (when `respectManualMoves` is on) so a window the user has moved
/// or resized won't get snapped back, where both explicit sources always
/// re-apply because the user asked for it. And each source consults a different
/// per-rule trigger flag - see `Rule.applies(to:)`.
public enum RestoreSource: Sendable {
    /// Display reconfiguration, wake, app launch, Put's own launch, or a layout
    /// activated by a screen-configuration match. Gated per rule by
    /// `Rule.autoPlace`.
    case auto

    /// The restore-all hotkey or menu item. Gated per rule by
    /// `Rule.includeInRestoreAll`.
    case explicitAll

    /// The user named what to place: the active-window hotkey, the per-app menu
    /// action, a layout activated by its own hotkey, or the recover action for
    /// an unreachable window. Ungated.
    case explicit
}

extension Rule {
    /// Whether this rule takes part in a restore kicked off by `source`.
    func applies(to source: RestoreSource) -> Bool {
        switch source {
        case .auto:
            autoPlace
        case .explicitAll:
            includeInRestoreAll
        case .explicit:
            true
        }
    }
}

/// Which rule owns a window on one restore pass.
enum RuleSelection: Equatable {
    /// Apply this rule.
    case apply(Rule)
    /// This rule owns the window but opted out of the trigger that fired.
    case optedOut(Rule)
    /// No enabled rule matches the window.
    case unmatched

    /// Pick the enabled rule that matches `descriptor`, then decide whether
    /// this source may apply it.
    ///
    /// The order matters. Gating inside the match would let a rule that opted
    /// out of automatic placement fall through to a broader rule - typically
    /// the bundle-wide one it was written to override - which would then move
    /// the window on exactly the trigger the user turned off.
    static func resolve(
        for descriptor: WindowDescriptor,
        in rules: [Rule],
        source: RestoreSource) -> RuleSelection
    {
        guard let rule = rules.first(where: {
            $0.isEnabled && RuleMatcher.matches($0, against: descriptor)
        }) else {
            return .unmatched
        }
        return rule.applies(to: source) ? .apply(rule) : .optedOut(rule)
    }
}
