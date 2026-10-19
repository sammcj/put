import Foundation
import PutCore
import PutWindows

extension ActionCoordinator {
    /// Whether automatic placement should hold off right now. The settle path
    /// checks this before asking so it can wait without counting a drop;
    /// everything else meets the guard in the restore entry points.
    var isAutomaticPlacementPaused: Bool {
        missionControl?.isMissionControlActive ?? false
    }

    /// Automatic restores report a pause the same way as a busy drop, so each
    /// caller's existing re-queue or retry handles it. Explicit restores go
    /// ahead because the user asked for them.
    func isPausedForMissionControl(source: RestoreSource, reason: String) -> Bool {
        guard source == .auto, isAutomaticPlacementPaused else { return false }
        log.info("Mission Control open; deferring \(reason, privacy: .public)")
        return true
    }
}
