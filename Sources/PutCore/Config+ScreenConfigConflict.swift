import Foundation

public extension Config {
    /// Returns the layout (other than `excludedLayoutID`) that already claims
    /// a screen configuration with the same display identity set as
    /// `trigger`. Conflicts are detected on identity alone, ignoring
    /// arrangement-strict differences, so the user is always prompted when
    /// two layouts would visibly share the "MacBook + LG UltraFine" config in
    /// the UI - even if their arrangement preferences differ.
    func layoutClaimingScreenConfig(
        identicalTo trigger: ScreenConfigTrigger,
        excluding excludedLayoutID: UUID? = nil) -> Layout?
    {
        let candidateIDs = trigger.identityKey
        return layouts.first { layout in
            guard layout.id != excludedLayoutID else { return false }
            return layout.screenConfigs.contains { $0.identityKey == candidateIDs }
        }
    }
}
