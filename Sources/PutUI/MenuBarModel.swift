import Foundation
import PutCore

/// Pure derivations behind the menu bar's dynamic items. Extracted from
/// `MenuBarController` so the label and active-layout logic can be unit-tested
/// without standing up an `NSStatusItem`.
enum MenuBarModel {
    /// A layout entry in the "Layout" submenu, carrying whether it should show
    /// the active checkmark.
    struct LayoutItem: Equatable {
        let id: UUID
        let title: String
        let isActive: Bool
    }

    /// Maps layouts to menu entries, marking the one whose id matches
    /// `activeLayoutID` as active (the checkmark in the menu).
    static func layoutItems(layouts: [PutCore.Layout], activeLayoutID: UUID) -> [LayoutItem] {
        layouts.map { LayoutItem(id: $0.id, title: $0.name, isActive: $0.id == activeLayoutID) }
    }

    /// Human label for a "Jump to Window" entry: the user's descriptive label if
    /// set, otherwise the bundle ID, optionally suffixed with the title pattern
    /// so two rules for the same app stay distinguishable.
    static func jumpTitle(for rule: Rule) -> String {
        let base = rule.descriptiveLabel.isEmpty ? rule.matchCriteria.bundleID : rule.descriptiveLabel
        let pattern = rule.matchCriteria.titlePattern
        if rule.descriptiveLabel.isEmpty, !rule.matchCriteria.applyToAllWindows, !pattern.isEmpty {
            return "\(base) — \(pattern)"
        }
        return base
    }
}
