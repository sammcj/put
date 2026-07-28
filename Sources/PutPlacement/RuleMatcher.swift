import Foundation
import PutCore
import PutWindows

public enum RuleMatcher {
    /// Evaluate a rule against a live window descriptor.
    ///
    /// Matching rules:
    ///
    /// 1. `bundleID` must match (always).
    /// 2. If `applyToAllWindows` is true, match succeeds.
    /// 3. Otherwise the title pattern is evaluated. An empty pattern is
    ///    treated as "any title".
    /// 4. If `useTitlePatternExclusively` is false, the `axRole` (when set)
    ///    must also match.
    public static func matches(_ rule: Rule, against window: WindowDescriptor) -> Bool {
        guard rule.matchCriteria.bundleID == window.bundleID else { return false }
        let criteria = rule.matchCriteria

        if criteria.applyToAllWindows {
            return true
        }

        if !titleMatches(pattern: criteria.titlePattern, mode: criteria.titleMatchMode, title: window.title) {
            return false
        }

        if !criteria.useTitlePatternExclusively,
           let expected = criteria.axRole, !expected.isEmpty,
           window.role != expected
        {
            return false
        }

        return true
    }

    private static func titleMatches(pattern: String, mode: TitleMatchMode, title: String) -> Bool {
        if pattern.isEmpty { return true }
        switch mode {
        case .literal:
            return title == pattern
        case .regex:
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                return false
            }
            let range = NSRange(title.startIndex..<title.endIndex, in: title)
            return regex.firstMatch(in: title, options: [], range: range) != nil
        }
    }
}
