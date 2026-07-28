import AppKit
import PutCore
import PutWindows

/// Pure helpers for translating a live window into the fields of a new `Rule`.
/// Split out of `ActionCoordinator` so the class file stays under the lint
/// size limit; also trivially unit-testable without mocking the coordinator.
enum RuleFactory {
    static func criteria(for descriptor: WindowDescriptor, applyToAll: Bool) -> MatchCriteria {
        MatchCriteria(
            bundleID: descriptor.bundleID,
            titlePattern: applyToAll ? "" : descriptor.title,
            titleMatchMode: .literal,
            useTitlePatternExclusively: false,
            axRole: descriptor.role,
            applyToAllWindows: applyToAll)
    }

    static func defaultLabel(for descriptor: WindowDescriptor, applyToAll: Bool) -> String {
        if applyToAll || descriptor.title.isEmpty {
            return NSRunningApplication(processIdentifier: descriptor.processID)?.localizedName
                ?? descriptor.bundleID
        }
        return descriptor.title
    }
}
