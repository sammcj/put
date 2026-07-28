import Foundation

public enum TitleMatchMode: String, Codable, Hashable, Sendable, CaseIterable {
    case literal
    case regex
}

/// Describes how a rule matches against a live window. Three flags influence
/// specificity:
///
/// - `applyToAllWindows` is the broadest; only `bundleID` is checked.
/// - `useTitlePatternExclusively` narrows to `bundleID` plus the title
///   pattern, ignoring role.
/// - Default mode requires `bundleID`, title pattern, and role all to match.
public struct MatchCriteria: Codable, Hashable, Sendable {
    public var bundleID: String
    public var titlePattern: String
    public var titleMatchMode: TitleMatchMode
    public var useTitlePatternExclusively: Bool
    public var axRole: String?
    public var applyToAllWindows: Bool

    public init(
        bundleID: String,
        titlePattern: String = "",
        titleMatchMode: TitleMatchMode = .literal,
        useTitlePatternExclusively: Bool = false,
        axRole: String? = nil,
        applyToAllWindows: Bool = false)
    {
        self.bundleID = bundleID
        self.titlePattern = titlePattern
        self.titleMatchMode = titleMatchMode
        self.useTitlePatternExclusively = useTitlePatternExclusively
        self.axRole = axRole
        self.applyToAllWindows = applyToAllWindows
    }

    /// The fields that determine which window a rule targets, independent of
    /// how the title is matched (literal vs regex) or exclusivity. Used for
    /// rule deduplication on save so editing a rule's match mode doesn't
    /// spawn a duplicate on the next save.
    public struct IdentityKey: Hashable, Sendable {
        public let bundleID: String
        public let effectiveTitlePattern: String
        public let axRole: String?
        public let applyToAllWindows: Bool
    }

    public var identityKey: IdentityKey {
        // Blank the fields RuleMatcher does not evaluate so two rules targeting
        // the same windows dedupe: the title pattern under applyToAllWindows,
        // and the role under either applyToAllWindows or useTitlePatternExclusively.
        IdentityKey(
            bundleID: bundleID,
            effectiveTitlePattern: applyToAllWindows ? "" : titlePattern,
            axRole: (applyToAllWindows || useTitlePatternExclusively) ? nil : axRole,
            applyToAllWindows: applyToAllWindows)
    }
}
