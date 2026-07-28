import Foundation

/// Captured screen arrangement that activates a `Layout` when the current
/// display set matches. Stored in `Layout.screenConfigs`. Pure value type;
/// matching logic lives in `PutDisplay.ScreenConfigMatcher` to keep Core free
/// of CoreGraphics-flavoured comparisons.
public struct ScreenConfigTrigger: Codable, Hashable, Sendable {
    /// Snapshot of the displays present when the user captured this trigger.
    public var displays: [DisplayFingerprint]
    /// When true, the matcher also requires the arrangement (relative
    /// `globalOrigin` of each display) to match. When false, identity-set
    /// match is sufficient. UI default is `true`.
    public var arrangementStrict: Bool
    /// When true, a successful match auto-activates the owning layout
    /// (set active + restore-all). When false, the trigger is captured for
    /// reference only; the user must press the layout's hotkey to activate.
    public var autoActivate: Bool
    /// When the trigger was captured. Diagnostics only.
    public var capturedAt: Date

    public init(
        displays: [DisplayFingerprint],
        arrangementStrict: Bool = true,
        autoActivate: Bool = true,
        capturedAt: Date = Date())
    {
        self.displays = displays
        self.arrangementStrict = arrangementStrict
        self.autoActivate = autoActivate
        self.capturedAt = capturedAt
    }

    /// Tolerant decoder. Older configs that predate this trigger never write
    /// the field at all, but a future addition (e.g. a new flag) shouldn't
    /// fail decoding for documents written before it existed.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displays = try container.decode([DisplayFingerprint].self, forKey: .displays)
        arrangementStrict = try container.decodeIfPresent(Bool.self, forKey: .arrangementStrict) ?? true
        autoActivate = try container.decodeIfPresent(Bool.self, forKey: .autoActivate) ?? true
        capturedAt = try container.decodeIfPresent(Date.self, forKey: .capturedAt) ?? Date()
    }

    /// Display identity set. Two triggers describe the same physical
    /// arrangement when their identity keys are equal, regardless of
    /// arrangement-strict / auto-activate flags or capture time. Used to keep
    /// a configuration claimed by at most one layout and to dedupe within a
    /// layout.
    public var identityKey: Set<String> {
        Set(displays.map(\.id))
    }
}
