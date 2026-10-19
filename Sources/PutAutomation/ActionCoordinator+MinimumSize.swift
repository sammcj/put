import CoreGraphics
import Foundation
import PutCore
import PutPlacement
import PutWindows

extension ActionCoordinator {
    /// `frame` raised to the rule's learned minimum when the write will set a
    /// size. A position-only write leaves the size alone, so it never needs it.
    /// Shared by both write paths (here and `AutoTriggerController.tryFulfil`).
    func respectingLearnedMinimum(_ frame: CGRect, rule: Rule) -> CGRect {
        switch rule.restoreComponents.write {
        case .frame, .size:
            let raised = learnedMinimums.applying(to: frame, ruleID: rule.id)
            if raised != frame {
                log.debug(
                    """
                    Raised target to learned minimum for rule \(rule.id.uuidString, privacy: .public): \
                    \(Self.formatDriftFrame(raised), privacy: .public)
                    """)
            }
            return raised
        case .position, .nothing:
            return frame
        }
    }

    /// Learn from a drifted write. The snapshot frame is the window's size
    /// before the write, which is what tells a refused shrink apart from an
    /// ignored write.
    func learnMinimum(rule: Rule, handle: WindowHandle, target: CGRect, actual: CGRect) async {
        guard let minimum = learnedMinimums.learn(
            ruleID: rule.id,
            initial: handle.descriptor.frame.size,
            target: target.size,
            actual: actual.size)
        else { return }
        let bundleID = handle.descriptor.bundleID
        let size = "\(Int(minimum.width))x\(Int(minimum.height))"
        log.info(
            """
            Learned minimum size \(size, privacy: .public) for \(bundleID, privacy: .public) \
            (rule=\(rule.id.uuidString, privacy: .public))
            """)
        await fileLog.append(
            level: .info,
            category: "actions",
            message: "Learned minimum size",
            metadata: ["bundle": bundleID, "rule": rule.id.uuidString, "minimum": size])
    }
}
