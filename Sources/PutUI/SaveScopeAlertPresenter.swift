import AppKit
import Foundation
import OSLog
import PutAutomation
import PutCore

/// Shows a non-blocking-feeling notice when a save skipped windows that sat on
/// monitors outside the active layout's screen configuration. Keeps the user
/// from silently losing a save when they're running, say, a laptop-only layout
/// while docked. Concrete `SaveScopeNotifying` for `PutAutomation`, mirroring
/// `SaveFlashPresenter`.
@MainActor
public final class SaveScopeAlertPresenter: SaveScopeNotifying {
    private let log: Logger = PutLog.logger(category: "ui.savescope")

    public init() {}

    public func warnOutOfScopeSaves(layoutName: String, skipped: [OutOfScopeSave]) {
        guard !skipped.isEmpty else { return }

        let windowLines = skipped
            .map { "  - \($0.appLabel) (on \($0.displayName))" }
            .joined(separator: "\n")

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = skipped.count == 1
            ? "One window wasn't saved into \"\(layoutName)\""
            : "\(skipped.count) windows weren't saved into \"\(layoutName)\""
        alert.informativeText = """
        These windows are on a monitor that isn't part of the \"\(layoutName)\" \
        layout, so saving them here would create rules that can't restore once \
        that monitor is gone:

        \(windowLines)

        Switch to the layout that matches your current monitors before saving \
        them, or add this monitor to \"\(layoutName)\" in Settings.
        """
        alert.addButton(withTitle: "OK")
        log.info("Presented out-of-scope save notice for \(skipped.count, privacy: .public) window(s)")
        alert.runModal()
    }
}
