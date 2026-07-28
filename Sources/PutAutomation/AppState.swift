import Foundation
import Observation
import PutCore

/// Shared observable application state. SwiftUI views read the config from
/// here; the `ActionCoordinator` mutates it. All access is on the main actor.
@MainActor
@Observable
public final class AppState {
    public var config: Config
    /// Rule IDs currently waiting for their target display to reconnect.
    public var queuedRuleIDs: Set<UUID>
    /// Most recent persistence failure message, surfaced to Settings so the
    /// user knows on-disk state diverged from what they see. `nil` once a
    /// subsequent save succeeds.
    public var lastSaveError: String?
    /// Rules whose app is running but whose window Put couldn't reach on the
    /// last full restore, because it's parked on another Mission Control Space
    /// (typically after a sleep/wake Space collapse). Drives the menu bar
    /// "Recover" affordance; macOS offers no SIP-free way to move a window
    /// across Spaces silently, so recovery is a user-initiated one-click action.
    public var unreachableWindows: [UnreachableWindow] = []

    public init(config: Config, queuedRuleIDs: Set<UUID> = []) {
        self.config = config
        self.queuedRuleIDs = queuedRuleIDs
    }

    public var activeLayout: Layout? {
        config.resolvedActiveLayout()
    }

    public func replaceActiveLayout(_ layout: Layout) {
        guard let index = config.layouts.firstIndex(where: { $0.id == layout.id }) else { return }
        config.layouts[index] = layout
        config.activeLayoutID = layout.id
    }

    /// Applies a launch-at-login toggle: writes through to the login item,
    /// mirrors the resulting live state into `config.launchAtLogin`, and runs
    /// `onChange` (typically a debounced persist) on success. Returns an error
    /// message on failure, or `nil` on success; callers surface the message in
    /// their own error slot. `onChange` never fires on the failure path.
    @discardableResult
    public func applyLaunchAtLogin(
        _ enabled: Bool,
        loginItem: some LoginItemToggling,
        onChange: () -> Void) -> String?
    {
        do {
            try loginItem.setEnabled(enabled)
            config.launchAtLogin = loginItem.isEnabled
            onChange()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// A rule Put is managing whose window has become unreachable because it sits
/// on a non-active Space. Cross-Space window moves need SIP disabled, so Put
/// can't silently relocate it; instead it surfaces a one-click recover action
/// that activates the app (bringing the window into AX reach) and re-places it.
public struct UnreachableWindow: Identifiable, Sendable, Equatable {
    public let ruleID: UUID
    /// Display label for the menu (the rule's descriptive label, else bundle ID).
    public let label: String
    /// Friendly name of the display the rule targets, if known.
    public let displayName: String?

    public var id: UUID {
        ruleID
    }

    public init(ruleID: UUID, label: String, displayName: String? = nil) {
        self.ruleID = ruleID
        self.label = label
        self.displayName = displayName
    }
}
