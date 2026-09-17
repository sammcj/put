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
        /// False when the display set matched but its captured arrangement
        /// differs from the live one. Informational; the controller logs it.
        public let arrangementAligned: Bool

        public init(layoutID: UUID, autoActivate: Bool, arrangementAligned: Bool = true) {
            self.layoutID = layoutID
            self.autoActivate = autoActivate
            self.arrangementAligned = arrangementAligned
        }
    }

    /// Returns the first layout with a `screenConfigs` entry that matches the
    /// current display set, or nil. The settings UI dedupes triggers on
    /// identity set and evicts cross-layout clashes, so UI-authored configs
    /// hold at most one claimant per display set. Imported or hand-edited
    /// configs are not validated; first match wins. `autoActivate` is taken
    /// from the specific trigger that matched, so a layout can mix auto and
    /// manual triggers across different display sets.
    public static func evaluate(
        layouts: [Layout],
        currentDisplays: [DisplayFingerprint]) -> Match?
    {
        for layout in layouts {
            for trigger in layout.screenConfigs {
                if case let .matched(aligned) = ScreenConfigMatcher.evaluate(
                    trigger: trigger, against: currentDisplays)
                {
                    return Match(
                        layoutID: layout.id,
                        autoActivate: trigger.autoActivate,
                        arrangementAligned: aligned)
                }
            }
        }
        return nil
    }
}
