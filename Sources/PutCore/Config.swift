import Foundation

/// Root persisted document. Schema-versioned for forward migration.
public struct Config: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var layouts: [Layout]
    public var activeLayoutID: UUID
    public var hotkeys: HotkeyBindings
    public var autoTriggers: AutoTriggerSettings
    public var launchAtLogin: Bool
    public var defaultMissingDisplayPolicy: MissingDisplayPolicy
    /// Stamp set the first time the user finishes the welcome wizard. `nil`
    /// means the wizard has never been completed; the bootstrap path uses
    /// this to decide whether to show the multi-step welcome flow on launch.
    /// Re-running the wizard from Settings does not modify this value.
    public var firstRunCompletedAt: Date?

    public init(
        schemaVersion: Int = putSchemaVersion,
        layouts: [Layout],
        activeLayoutID: UUID,
        hotkeys: HotkeyBindings = HotkeyBindings(),
        autoTriggers: AutoTriggerSettings = AutoTriggerSettings(),
        launchAtLogin: Bool = false,
        defaultMissingDisplayPolicy: MissingDisplayPolicy = .primaryProportional,
        firstRunCompletedAt: Date? = nil)
    {
        self.schemaVersion = schemaVersion
        self.layouts = layouts
        self.activeLayoutID = activeLayoutID
        self.hotkeys = hotkeys
        self.autoTriggers = autoTriggers
        self.launchAtLogin = launchAtLogin
        self.defaultMissingDisplayPolicy = defaultMissingDisplayPolicy
        self.firstRunCompletedAt = firstRunCompletedAt
    }

    /// Backwards-compatible decoder: older keys that have since been removed
    /// (e.g. `askScopeOnSingleAppSave`) are simply ignored.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        layouts = try container.decode([Layout].self, forKey: .layouts)
        activeLayoutID = try container.decode(UUID.self, forKey: .activeLayoutID)
        hotkeys = try container.decodeIfPresent(HotkeyBindings.self, forKey: .hotkeys) ?? HotkeyBindings()
        autoTriggers = try container
            .decodeIfPresent(AutoTriggerSettings.self, forKey: .autoTriggers) ?? AutoTriggerSettings()
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        defaultMissingDisplayPolicy = try container.decodeIfPresent(
            MissingDisplayPolicy.self,
            forKey: .defaultMissingDisplayPolicy) ?? .primaryProportional
        firstRunCompletedAt = try container.decodeIfPresent(Date.self, forKey: .firstRunCompletedAt)
    }

    /// Empty config with a single Default layout.
    public static func bootstrap() -> Config {
        let defaultLayout = Layout.defaultLayout()
        return Config(
            layouts: [defaultLayout],
            activeLayoutID: defaultLayout.id)
    }

    /// Returns the active layout, falling back to the first layout if the ID
    /// is stale (e.g. the active layout was deleted outside the app).
    public func resolvedActiveLayout() -> Layout? {
        if let match = layouts.first(where: { $0.id == activeLayoutID }) {
            return match
        }
        return layouts.first
    }
}
