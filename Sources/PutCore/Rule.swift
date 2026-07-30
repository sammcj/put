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
    /// full regardless, so narrowing the scope and widening it again later never
    /// loses the original coordinates.
    public var restoreScope: RestoreScope

    public init(
        id: UUID = UUID(),
        descriptiveLabel: String = "",
        matchCriteria: MatchCriteria,
        targetDisplay: DisplayFingerprint,
        frame: WindowFrame,
        missingDisplayPolicy: MissingDisplayPolicy = .primaryProportional,
        isEnabled: Bool = true,
        restoreScope: RestoreScope = .sizeAndPosition)
    {
        self.id = id
        self.descriptiveLabel = descriptiveLabel
        self.matchCriteria = matchCriteria
        self.targetDisplay = targetDisplay
        self.frame = frame
        self.missingDisplayPolicy = missingDisplayPolicy
        self.isEnabled = isEnabled
        self.restoreScope = restoreScope
    }

    enum CodingKeys: String, CodingKey {
        case id
        case descriptiveLabel
        case matchCriteria
        case targetDisplay
        case frame
        case missingDisplayPolicy
        case isEnabled
        case restoreScope
        /// Superseded by `restoreScope`. Still read (for configs written before
        /// the display-only scope existed) and still written (so a config
        /// round-tripping through an older build degrades to size-only rather
        /// than silently re-asserting a position the user cleared).
        case restoresPosition
    }

    /// Backwards-compatible decoder. Configs predating `restoreScope` carry a
    /// `restoresPosition` bool instead; configs predating both get the default.
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
        let rawScope = try container.decodeIfPresent(String.self, forKey: .restoreScope)
        if let scope = rawScope.flatMap(RestoreScope.init(rawValue:)) {
            restoreScope = scope
        } else {
            let legacyRestoresPosition = try container.decodeIfPresent(Bool.self, forKey: .restoresPosition) ?? true
            restoreScope = legacyRestoresPosition ? .sizeAndPosition : .sizeOnly
        }
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
        try container.encode(restoreScope, forKey: .restoreScope)
        try container.encode(restoreScope == .sizeAndPosition, forKey: .restoresPosition)
    }
}
