import AppKit
import Foundation
import SwiftUI

/// Implemented by the host `AppDelegate` to track how many user-facing
/// windows are visible. Used to keep the dock icon up while any window is
/// open rather than yanking it down when an individual window closes.
@MainActor
public protocol AppWindowLifecycle: AnyObject {
    func didOpenUserFacingWindow()
    func didCloseUserFacingWindow()
}

public struct AboutLink: Sendable, Identifiable {
    public let title: String
    public let url: URL
    public var id: String {
        title
    }

    public init(title: String, url: URL) {
        self.title = title
        self.url = url
    }
}

/// Single source of truth for the app's About content. Used by both the
/// standalone `AboutWindow` and the `About` tab inside Settings so the two
/// surfaces never drift.
public struct AboutInfo: Sendable {
    public let appName: String
    public let version: String
    public let tagline: String
    public let copyright: String
    public let links: [AboutLink]

    public init(
        appName: String,
        version: String,
        tagline: String,
        copyright: String,
        links: [AboutLink] = [])
    {
        self.appName = appName
        self.version = version
        self.tagline = tagline
        self.copyright = copyright
        self.links = links
    }
}

@MainActor
public final class AboutWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private weak var lifecycle: AppWindowLifecycle?
    private var didReportOpen = false

    public init(
        title: String,
        info: AboutInfo,
        lifecycle: AppWindowLifecycle? = nil)
    {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 260),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        self.lifecycle = lifecycle
        super.init()
        window.delegate = self
        window.title = title
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()

        // Host the shared SwiftUI `AboutTab` so this window and the Settings
        // About tab render from one layout and can't drift.
        window.contentView = NSHostingView(rootView: AboutTab(info: info))
    }

    public func show() {
        if !didReportOpen {
            lifecycle?.didOpenUserFacingWindow()
            didReportOpen = true
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    public func windowWillClose(_ notification: Notification) {
        if didReportOpen {
            lifecycle?.didCloseUserFacingWindow()
            didReportOpen = false
        }
    }
}
