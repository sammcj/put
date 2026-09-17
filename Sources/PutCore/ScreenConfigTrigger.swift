import Foundation

/// Captured screen arrangement that activates a `Layout` when the current
/// display set matches. Stored in `Layout.screenConfigs`. Pure value type;
/// matching logic lives in `PutDisplay.ScreenConfigMatcher` to keep Core free
/// of CoreGraphics-flavoured comparisons.
public struct ScreenConfigTrigger: Codable, Hashable, Sendable {
    /// Snapshot of the displays present when the user captured this trigger.
    public var displays: [DisplayFingerprint]
    /// When true, a successful match auto-activates the owning layout
    /// (set active + restore-all). When false, the trigger is captured for
    /// reference only; the user must press the layout's hotkey to activate.
    public var autoActivate: Bool
    /// When the trigger was captured. Diagnostics only.
    public var capturedAt: Date

    public init(
        displays: [DisplayFingerprint],
        autoActivate: Bool = true,
        capturedAt: Date = Date())
    {
        self.displays = displays
        self.autoActivate = autoActivate
        self.capturedAt = capturedAt
    }

    /// Tolerant decoder. Older configs that predate this trigger never write
    /// the field at all, but a future addition (e.g. a new flag) shouldn't
    /// fail decoding for documents written before it existed. Removed fields
    /// (`arrangementStrict`) are ignored on read: macOS reshuffles the
    /// built-in display's offset on every replug, so a strict arrangement
    /// gate never matched again and only produced silent non-activation.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displays = try container.decode([DisplayFingerprint].self, forKey: .displays)
        autoActivate = try container.decodeIfPresent(Bool.self, forKey: .autoActivate) ?? true
        capturedAt = try container.decodeIfPresent(Date.self, forKey: .capturedAt) ?? Date()
    }

    /// Display identity set. Two triggers describe the same physical
    /// arrangement when their identity keys are equal, regardless of the
    /// auto-activate flag or capture time. Used to keep
    /// a configuration claimed by at most one layout and to dedupe within a
    /// layout.
    public var identityKey: Set<String> {
        Set(displays.map(\.id))
    }
}
