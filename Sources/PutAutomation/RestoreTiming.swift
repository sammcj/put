import Foundation

/// Single home for the timing constants that govern automatic restore. These
/// were previously scattered across `AutoTriggerController` as inline literals;
/// gathering them here makes the system's clock-driven behaviour easy to find
/// and reason about when debugging "Put fired too early / too late / twice".
///
/// Not included here, on purpose: the moved-by-user suppression, which has
/// *no* timer. Once Put detects a window as user-moved it stays suppressed
/// until the display layout changes or the user restores manually - see
/// `PlacementHistory` (in PutPlacement) for that rule and the reasoning.
public enum RestoreTiming {
    /// Trailing-edge debounce applied to wake and display-reconfigure events.
    /// A wake immediately followed by an external-panel reconnect burst folds
    /// into one settle pass instead of firing a premature restore that the
    /// in-flight guard would then drop. Overridable per-instance for tests.
    public static let debounceInterval: TimeInterval = 1.0

    /// Backoff schedule for corrective restore passes after wake. A wake
    /// restore can land short of the saved layout for two reasons: an app's
    /// Accessibility server wasn't ready the instant `didWakeNotification`
    /// fired (surfaces as AX errors), or an external panel was still at a
    /// transient resolution so windows were remapped proportionally onto the
    /// wrong geometry. Either way the displays usually settle within a few
    /// seconds; these passes re-probe and replay the saved absolute frames.
    /// The loop stops early as soon as a pass reports no AX errors and no
    /// proportional placements, so a quick settle costs a single retry while a
    /// slow panel still gets corrected. At most one schedule runs per wake.
    /// The horizon runs to ~50s total because a mirrored panel driven through a
    /// HiDPI dongle can take far longer than the old 16s tail to finish
    /// reconfiguring and bring a Metal app's AX server back online after wake.
    public static let wakeRetryDelays: [TimeInterval] = [3.0, 5.0, 8.0, 13.0, 21.0]

    /// How long the display-reconfigure stream must be quiet before a wake
    /// restore runs. A wake on a mirrored set emits a burst of reconfigure
    /// events as panels renegotiate; restoring mid-burst races the layout and
    /// collides with the display-change restore (single-flight drops one).
    /// Waiting for quiescence means the first wake pass runs against the final
    /// geometry. Longer than `debounceInterval` so it actually adds settle time.
    public static let wakeSettleQuietWindow: TimeInterval = 2.0

    /// Upper bound on how long a wake restore waits for the display set to go
    /// quiet. A panel that never stops dribbling reconfigure events must not
    /// block the restore indefinitely; past this the restore runs regardless.
    public static let wakeSettleCap: TimeInterval = 8.0

    /// Pause before re-attempting a wake retry that was dropped by the
    /// single-flight guard (a concurrent display-change restore was in flight).
    /// A dropped attempt must not consume a backoff slot, so it waits this long
    /// and retries the same step instead of advancing the schedule.
    public static let wakeRetryDropBackoff: TimeInterval = 1.0

    /// Cap on consecutive dropped wake retries before giving up, so a
    /// permanently busy coordinator can't spin the retry loop forever.
    public static let wakeRetryMaxConsecutiveDrops = 8

    /// Settle pause in `recoverUnreachable` between activating an app and
    /// re-probing its windows. Activation either switches to the Space holding
    /// the stranded window or pulls it onto the active one; the window server
    /// needs a beat to finish that before an AX snapshot can see it.
    public static let spaceSwitchSettle: TimeInterval = 0.6

    /// Backoff schedule for the per-app launch retry loop. The first delay
    /// gives the app time to open its initial window; later delays catch slow
    /// cold launches and `isRestoring` collisions with concurrent
    /// wake/display restores. The loop stops early once the restore applies.
    public static let launchRetryDelays: [Duration] = [
        .milliseconds(500),
        .seconds(1),
        .milliseconds(1500),
        .seconds(2),
        .seconds(3),
        .seconds(5),
        .seconds(7)
    ]
}
