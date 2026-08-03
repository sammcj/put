import Foundation

public struct Rule: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// User-facing name shown in Settings, distinct from the live window title.
    public var descriptiveLabel: String
    public var matchCriteria: MatchCriteria
    public var targetDisplay: DisplayFingerprint
    public var frame: WindowFrame
    public var missingDisplayPolicy: MissingDisplayPolicy
    public var isEnabled: Bool
    /// How much of `frame` restoring re-asserts. The saved frame is captured in
    /// full regardless, so turning a component off and on again later never
    /// loses the original coordinates.
    public var restoreComponents: RestoreComponents
    /// Whether automatic triggers place this window: display reconfiguration,
    /// wake, app launch, Put's own launch, and a layout activated by a
    /// screen-configuration match. Off leaves the window where it is until the
    /// user asks for it.
    public var autoPlace: Bool
    /// Whether the restore-all hotkey and menu item place this window.
    ///
    /// The active-window hotkey, the per-app menu action and a layout activated
    /// by its own hotkey ignore this and `autoPlace` alike: each names what to
    /// place, so the rule applies. With both off, the geometry stays saved and
    /// only those explicit actions ever apply it.
    public var includeInRestoreAll: Bool

    public init(
        id: UUID = UUID(),
        descriptiveLabel: String = "",
        matchCriteria: MatchCriteria,
        targetDisplay: DisplayFingerprint,
        frame: WindowFrame,
        missingDisplayPolicy: MissingDisplayPolicy = .primaryProportional,
        isEnabled: Bool = true,
        restoreComponents: RestoreComponents = .sizeAndPosition,
        autoPlace: Bool = true,
        includeInRestoreAll: Bool = true)
    {
        self.id = id
        self.descriptiveLabel = descriptiveLabel
        self.matchCriteria = matchCriteria
        self.targetDisplay = targetDisplay
        self.frame = frame
        self.missingDisplayPolicy = missingDisplayPolicy
        self.isEnabled = isEnabled
        self.restoreComponents = restoreComponents
        self.autoPlace = autoPlace
        self.includeInRestoreAll = includeInRestoreAll
    }

    enum CodingKeys: String, CodingKey {
        case id
        case descriptiveLabel
        case matchCriteria
        case targetDisplay
        case frame
        case missingDisplayPolicy
        case isEnabled
        case restoreComponents
        case autoPlace
        case includeInRestoreAll
        /// Superseded by `restoreComponents`. Still read (for configs written
        /// before the components existed) and still written (so a config
        /// round-tripping through an older build degrades to the nearest scope
        /// rather than re-asserting geometry the user cleared).
        case restoreScope
        /// Superseded by `restoreScope`, itself superseded by
        /// `restoreComponents`. Read and written for the same reason, one
        /// generation further back.
        case restoresPosition
    }

    /// Backwards-compatible decoder, newest key first. Configs predating
    /// `restoreComponents` carry a `restoreScope` string; those predating both
    /// carry a `restoresPosition` bool; those predating all three get the
    /// default.
    ///
    /// `restoreScope` is decoded as a raw string rather than the enum so a
    /// value this build doesn't know (a scope added by a newer build, which
    /// wouldn't bump the schema version any more than `restoreScope` itself
    /// did) falls back to the legacy bool instead of throwing. A throw here
    /// propagates to `ConfigStore.load`, which quarantines the file and
    /// bootstraps a fresh default - losing every rule the user has.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        descriptiveLabel = try container.decodeIfPresent(String.self, forKey: .descriptiveLabel) ?? ""
        matchCriteria = try container.decode(MatchCriteria.self, forKey: .matchCriteria)
        targetDisplay = try container.decode(DisplayFingerprint.self, forKey: .targetDisplay)
        frame = try container.decode(WindowFrame.self, forKey: .frame)
        missingDisplayPolicy = try container.decodeIfPresent(
            MissingDisplayPolicy.self,
            forKey: .missingDisplayPolicy) ?? .primaryProportional
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        if let components = try container.decodeIfPresent(RestoreComponents.self, forKey: .restoreComponents) {
            restoreComponents = components
        } else if let scope = try container
            .decodeIfPresent(String.self, forKey: .restoreScope)
            .flatMap(RestoreScope.init(rawValue:))
        {
            restoreComponents = scope.components
        } else {
            let legacyRestoresPosition = try container.decodeIfPresent(Bool.self, forKey: .restoresPosition) ?? true
            restoreComponents = legacyRestoresPosition ? .sizeAndPosition : .sizeOnly
        }
        autoPlace = try container.decodeIfPresent(Bool.self, forKey: .autoPlace) ?? true
        includeInRestoreAll = try container.decodeIfPresent(Bool.self, forKey: .includeInRestoreAll) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(descriptiveLabel, forKey: .descriptiveLabel)
        try container.encode(matchCriteria, forKey: .matchCriteria)
        try container.encode(targetDisplay, forKey: .targetDisplay)
        try container.encode(frame, forKey: .frame)
        try container.encode(missingDisplayPolicy, forKey: .missingDisplayPolicy)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(restoreComponents, forKey: .restoreComponents)
        try container.encode(autoPlace, forKey: .autoPlace)
        try container.encode(includeInRestoreAll, forKey: .includeInRestoreAll)
        let legacyScope = RestoreScope.closest(to: restoreComponents)
        try container.encode(legacyScope, forKey: .restoreScope)
        try container.encode(legacyScope == .sizeAndPosition, forKey: .restoresPosition)
    }
}
