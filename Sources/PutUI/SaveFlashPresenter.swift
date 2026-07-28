import AppKit
import Foundation
import OSLog
import PutAutomation
import PutCore

/// Displays a brief translucent pulse over each saved window's frame so the
/// user gets immediate confirmation that a hotkey fired. Windows are
/// borderless, non-activating, ignore mouse events, and self-dismiss on a
/// short timer, so the flash never steals focus or blocks input.
@MainActor
public final class SaveFlashPresenter: SaveFlashing {
    private let log: Logger = PutLog.logger(category: "ui.saveflash")
    private static let fadeDuration: TimeInterval = 0.28
    private static let holdDuration: TimeInterval = 0.08

    public init() {}

    public func flash(rects: [CGRect]) {
        for rect in rects {
            present(for: rect)
        }
    }

    private func present(for axRect: CGRect) {
        guard let cocoaRect = Self.cocoaRect(fromAX: axRect) else {
            log.debug("Skipping flash: could not convert AX rect")
            return
        }

        let panel = FlashPanel(contentRect: cocoaRect)
        panel.contentView = FlashView(frame: NSRect(origin: .zero, size: cocoaRect.size))
        panel.orderFrontRegardless()

        // Hold briefly at full alpha, then fade and dismiss. The completion
        // handler is a non-isolated `Sendable` closure but in practice fires
        // on the main thread; hop back via Task @MainActor so the
        // MainActor-only `orderOut`/`close` calls compile under Swift 6
        // strict concurrency.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.holdDuration))
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = Self.fadeDuration
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().alphaValue = 0
                } completionHandler: {
                    continuation.resume()
                }
            }
            panel.orderOut(nil)
            panel.close()
        }
    }

    /// Global AX space → Cocoa screens space. AX has the primary display's
    /// top-left at (0,0) with +y down; Cocoa has the primary's bottom-left
    /// at (0,0) with +y up. Only the vertical axis flips, relative to the
    /// primary height.
    static func cocoaRect(fromAX rect: CGRect) -> CGRect? {
        let screens = NSScreen.screens
        let primary = screens.first { $0.frame.origin == .zero } ?? screens.first
        guard let primaryHeight = primary?.frame.height else { return nil }
        return CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.origin.y - rect.size.height,
            width: rect.size.width,
            height: rect.size.height)
    }
}

private final class FlashPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isMovable = false
        hidesOnDeactivate = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}

private final class FlashView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 2, dy: 2)
        let path = NSBezierPath(roundedRect: inset, xRadius: 8, yRadius: 8)
        NSColor.controlAccentColor.withAlphaComponent(0.28).setFill()
        path.fill()
        path.lineWidth = 3
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        path.stroke()
    }
}
