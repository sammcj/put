import Foundation

public struct Layout: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var rules: [Rule]
    /// Optional `KeyboardShortcuts.Name` raw value that activates this layout.
    /// Stored as a string so Core stays UI-framework independent.
    public var activationShortcutID: String?
    /// Captured screen configurations that activate this layout automatically
    /// when the current display set matches any of them. An empty array means
    /// no screen-config trigger; only the hotkey activates the layout.
    public var screenConfigs: [ScreenConfigTrigger]

    private enum CodingKeys: String, CodingKey {
        case id, name, rules, activationShortcutID, screenConfigs
    }

    /// Schema <= 2 stored a single optional `screenConfig`. Decoded into the
    /// first element of `screenConfigs` when the array key is absent.
    private enum LegacyCodingKeys: String, CodingKey {
        case screenConfig
    }

    public init(
        id: UUID = UUID(),
        name: String,
        rules: [Rule] = [],
        activationShortcutID: String? = nil,
        screenConfigs: [ScreenConfigTrigger] = [])
    {
        self.id = id
        self.name = name
        self.rules = rules
        self.activationShortcutID = activationShortcutID
        self.screenConfigs = screenConfigs
    }

    /// Backwards-compatible decoder. Reads the `screenConfigs` array when
    /// present (schema 3+); otherwise wraps the legacy single `screenConfig`
    /// (schema <= 2) into an array, and defaults to empty for configs that
    /// predate triggers entirely.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        rules = try container.decodeIfPresent([Rule].self, forKey: .rules) ?? []
        activationShortcutID = try container.decodeIfPresent(String.self, forKey: .activationShortcutID)
        if let configs = try container.decodeIfPresent([ScreenConfigTrigger].self, forKey: .screenConfigs) {
            screenConfigs = configs
        } else {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            let single = try legacy.decodeIfPresent(ScreenConfigTrigger.self, forKey: .screenConfig)
            screenConfigs = single.map { [$0] } ?? []
        }
    }

    public static func defaultLayout() -> Layout {
        Layout(name: "Default")
    }

    /// Identity keys of every display named by this layout's screen-config
    /// triggers. This is the set of monitors the layout is "for". Empty when
    /// the layout has no screen configs (hotkey-only), which means it declares
    /// no display scope - any display is in scope.
    public var expectedDisplayIDs: Set<String> {
        Set(screenConfigs.flatMap { $0.displays.map(\.id) })
    }

    /// Whether `displayID` falls within this layout's declared display scope.
    /// Always true for a layout with no screen configs. Used at save time to
    /// avoid stamping a rule for a window on a monitor the active layout isn't
    /// meant to cover (e.g. saving a docked window into a laptop-only layout).
    public func coversDisplay(_ displayID: String) -> Bool {
        let expected = expectedDisplayIDs
        return expected.isEmpty || expected.contains(displayID)
    }

    /// Returns a structural copy of this layout under a new identity: fresh
    /// `id`, fresh `id` on every nested `Rule`, and no activation shortcut or
    /// screen-config triggers (both must stay unique to a single layout and
    /// would clash if carried across).
    public func duplicated(name: String) -> Layout {
        Layout(
            name: name,
            rules: rules.map { rule in
                var copy = rule
                copy.id = UUID()
                return copy
            })
    }
}
