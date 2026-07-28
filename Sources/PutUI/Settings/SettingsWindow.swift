import AppKit
import PutAutomation
import SwiftUI

@MainActor
public final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let state: AppState
    private let persister: ConfigPersister
    private let coordinator: ActionCoordinator
    private let loginItem: LoginItemController
    private weak var lifecycle: AppWindowLifecycle?
    private var didReportOpen = false
    private let navigation = SettingsNavigation()

    public init(
        state: AppState,
        persister: ConfigPersister,
        coordinator: ActionCoordinator,
        loginItem: LoginItemController,
        aboutInfo: AboutInfo,
        lifecycle: AppWindowLifecycle? = nil,
        onShowWelcome: @escaping () -> Void = {},
        onExportSettings: @escaping () -> Void = {},
        onImportSettings: @escaping () -> Void = {})
    {
        self.state = state
        self.persister = persister
        self.coordinator = coordinator
        self.loginItem = loginItem
        self.lifecycle = lifecycle

        let controller = NSHostingController(
            rootView: SettingsView(
                state: state,
                persister: persister,
                coordinator: coordinator,
                loginItem: loginItem,
                navigation: navigation,
                aboutInfo: aboutInfo,
                onShowWelcome: onShowWelcome,
                onExportSettings: onExportSettings,
                onImportSettings: onImportSettings))
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Put Settings"
        // Unify the titlebar with the tab bar below it. A visible title plus the
        // TabView's own tab strip stacks two horizontal bands with a white gap
        // between them; a transparent, title-hidden bar lets the content sit
        // directly under the traffic lights with no dead band.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // With a transparent titlebar the bar shows the window's own background.
        // NSHostingController leaves that white, which reads as a white strip
        // above the content now the panes are grey; pin it to the standard
        // window background so the titlebar blends with the content below.
        window.backgroundColor = .windowBackgroundColor
        window.setContentSize(NSSize(width: 760, height: 540))
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("net.smcleod.put.settings")

        self.window = window
        super.init()
        window.delegate = self
    }

    public func show(tab: SettingsTab? = nil) {
        if let tab { navigation.selectedTab = tab }
        if !didReportOpen {
            lifecycle?.didOpenUserFacingWindow()
            didReportOpen = true
        }
        // Re-centre only on a fresh open. If the window is already visible the
        // user may have dragged it intentionally; yanking it back is jarring.
        if !window.isVisible {
            centreOnActiveDisplay()
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// Centre the window on the display under the mouse pointer. Settings
    /// should open where the user is looking, not on whichever monitor macOS
    /// considers "primary". NSWindow.center() always picks the primary screen,
    /// and autosaving the frame causes the window to reappear wherever it was
    /// last dragged - which on multi-display setups is a frequent source of
    /// "my window is off-screen" reports.
    private func centreOnActiveDisplay() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        var frame = window.frame
        frame.origin.x = visible.midX - frame.width / 2
        frame.origin.y = visible.midY - frame.height / 2
        window.setFrame(frame, display: false)
    }

    public func windowWillClose(_ notification: Notification) {
        Task { await persister.flush() }
        if didReportOpen {
            lifecycle?.didCloseUserFacingWindow()
            didReportOpen = false
        }
    }
}
