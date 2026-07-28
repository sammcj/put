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
    /// When `false`, restoring this rule resizes the matched window but leaves
    /// its current screen position untouched. The saved `frame.absolute`
    /// origin is retained so the user can re-enable position restore later
    /// without losing the original coordinates.
    public var restoresPosition: Bool

    public init(
        id: UUID = UUID(),
        descriptiveLabel: String = "",
        matchCriteria: MatchCriteria,
        targetDisplay: DisplayFingerprint,
        frame: WindowFrame,
        missingDisplayPolicy: MissingDisplayPolicy = .primaryProportional,
        isEnabled: Bool = true,
        restoresPosition: Bool = true)
    {
        self.id = id
        self.descriptiveLabel = descriptiveLabel
        self.matchCriteria = matchCriteria
        self.targetDisplay = targetDisplay
        self.frame = frame
        self.missingDisplayPolicy = missingDisplayPolicy
        self.isEnabled = isEnabled
        self.restoresPosition = restoresPosition
    }

    /// Backwards-compatible decoder. Older configs predate `restoresPosition`;
    /// defaulting to `true` keeps existing rules behaving exactly as they did.
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
        restoresPosition = try container.decodeIfPresent(Bool.self, forKey: .restoresPosition) ?? true
    }
}
