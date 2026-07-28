import Foundation
import PutCore
import PutDisplay

/// Pure evaluator that picks which layout (if any) should fire on the
/// current screen configuration. Lives apart from `AutoTriggerController` so
/// the decision logic is unit-testable without standing up the full
/// observer/debouncer scaffolding.
public enum LayoutTriggerEvaluator {
    public struct Match: Equatable, Sendable {
        public let layoutID: UUID
        public let autoActivate: Bool

        public init(layoutID: UUID, autoActivate: Bool) {
            self.layoutID = layoutID
            self.autoActivate = autoActivate
        }
    }

    /// Returns the first layout with a `screenConfigs` entry that matches the
    /// current display set, or nil. Save-time conflict detection guarantees at
    /// most one layout per identity set, so iteration order is deterministic.
    /// `autoActivate` is taken from the specific trigger that matched, so a
    /// layout can mix auto and manual triggers across different arrangements.
    public static func evaluate(
        layouts: [Layout],
        currentDisplays: [DisplayFingerprint]) -> Match?
    {
        for layout in layouts {
            if let trigger = layout.screenConfigs.first(where: {
                ScreenConfigMatcher.evaluate(trigger: $0, against: currentDisplays) == .matched
            }) {
                return Match(layoutID: layout.id, autoActivate: trigger.autoActivate)
            }
        }
        return nil
    }
}
