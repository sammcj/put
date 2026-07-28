import Foundation

public struct AutoTriggerSettings: Codable, Hashable, Sendable {
    public var onDisplayChange: Bool
    public var onAppLaunch: Bool
    public var onWake: Bool
    /// Restore all windows once when Put itself launches. Defaults to `true`
    /// so that simply starting Put after login lands windows where they were
    /// last saved without requiring a hotkey press.
    public var onPutLaunch: Bool

    /// When `true`, once Put has placed a window an auto-trigger won't snap it
    /// back if the user has since moved or resized it. The window is left
    /// alone until its rule resolves to a different target (e.g. a display is
    /// connected or removed) or the user restores it manually. When `false`,
    /// every auto-trigger re-asserts the saved frame (the "always snap back"
    /// behaviour). See `PlacementHistory.shouldSkipReplay` for the rule.
    public var respectManualMoves: Bool

    public init(
        onDisplayChange: Bool = true,
        onAppLaunch: Bool = true,
        onWake: Bool = true,
        onPutLaunch: Bool = true,
        respectManualMoves: Bool = true)
    {
        self.onDisplayChange = onDisplayChange
        self.onAppLaunch = onAppLaunch
        self.onWake = onWake
        self.onPutLaunch = onPutLaunch
        self.respectManualMoves = respectManualMoves
    }

    /// Decode legacy configs that predate `onPutLaunch` / `respectManualMoves`.
    /// Missing keys take the new default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        onDisplayChange = try container.decodeIfPresent(Bool.self, forKey: .onDisplayChange) ?? true
        onAppLaunch = try container.decodeIfPresent(Bool.self, forKey: .onAppLaunch) ?? true
        onWake = try container.decodeIfPresent(Bool.self, forKey: .onWake) ?? true
        onPutLaunch = try container.decodeIfPresent(Bool.self, forKey: .onPutLaunch) ?? true
        respectManualMoves = try container.decodeIfPresent(Bool.self, forKey: .respectManualMoves) ?? true
    }
}
