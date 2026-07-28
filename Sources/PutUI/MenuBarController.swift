import AppKit
import Foundation
import OSLog
import PutAutomation
import PutCore
import PutWindows

@MainActor
public final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let coordinator: ActionCoordinator
    private let state: AppState
    private let log: Logger = PutLog.logger(category: "ui.menubar")

    public var openSettings: () -> Void = {}
    public var openRulesEditor: () -> Void = {}
    public var openAboutWindow: () -> Void = {}
    public var openWelcome: () -> Void = {}
    public var exportDiagnostics: () -> Void = {}
    /// Invoked when the user picks a layout from the menu. Owner persists
    /// `state.config.activeLayoutID`; this controller only mutates local state.
    public var setActiveLayout: (UUID) -> Void = { _ in }

    public init(coordinator: ActionCoordinator, state: AppState) {
        self.coordinator = coordinator
        self.state = state
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureStatusItem()
    }

    // MARK: - Public

    /// Installs the menu and wires the delegate so items are refreshed on
    /// every open (running apps, rules, layouts can all change between opens).
    public func install() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        rebuildItems(in: menu)
    }

    /// NSMenuDelegate: re-populate right before display so the menu always
    /// reflects the current `AppState` and running apps.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        rebuildItems(in: menu)
    }

    public func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        rebuildItems(in: menu)
    }

    private func rebuildItems(in menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(buildHeader("Put"))
        menu.addItem(.separator())

        addUnreachableSection(to: menu)

        menu.addItem(buildAppsSubmenu())

        menu.addItem(.separator())
        menu.addItem(menuItem(
            title: "Save Focused Window (All App Windows)",
            selector: #selector(handleSaveFocusedAllApp),
            keyEquivalent: ""))
        menu.addItem(menuItem(
            title: "Save Focused Window (This Title Only)",
            selector: #selector(handleSaveFocusedTitleOnly),
            keyEquivalent: ""))
        menu.addItem(menuItem(
            title: "Save All Windows",
            selector: #selector(handleSaveAll),
            keyEquivalent: ""))
        menu.addItem(buildSaveSizeOnlySubmenu())
        menu.addItem(menuItem(
            title: "Restore All Windows",
            selector: #selector(handleRestoreAll),
            keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(buildJumpSubmenu())
        menu.addItem(buildLayoutsSubmenu())

        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Edit Rules...", selector: #selector(handleEditRules), keyEquivalent: ""))
        menu.addItem(menuItem(title: "Settings...", selector: #selector(handleSettings), keyEquivalent: ","))
        menu.addItem(menuItem(
            title: "Export Diagnostics...",
            selector: #selector(handleExportDiagnostics),
            keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "About Put", selector: #selector(handleAbout), keyEquivalent: ""))
        menu.addItem(menuItem(title: "Welcome...", selector: #selector(handleWelcome), keyEquivalent: ""))
        menu.addItem(menuItem(title: "Quit Put", selector: #selector(handleQuit), keyEquivalent: "q"))
    }

    // MARK: - Setup

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular, scale: .medium)
        let image = (NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "Put")
            ?? NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "Put"))?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        button.image = image
        button.toolTip = "Put"
    }

    private func buildHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// Size-only counterparts of the global save actions. The window keeps its
    /// current position when the rule is later applied; only the size is
    /// restored. Grouped in a submenu so the flat save list stays readable.
    private func buildSaveSizeOnlySubmenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Save Size Only", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let entries: [(String, Selector)] = [
            ("Focused Window (All App Windows)", #selector(handleSaveFocusedAllAppSizeOnly)),
            ("Focused Window (This Title Only)", #selector(handleSaveFocusedTitleOnlySizeOnly)),
            ("All Windows", #selector(handleSaveAllSizeOnly))
        ]
        for (title, selector) in entries {
            submenu.addItem(menuItem(title: title, selector: selector, keyEquivalent: ""))
        }
        item.submenu = submenu
        return item
    }

    private func buildAppsSubmenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Apps", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }

        if running.isEmpty {
            let empty = NSMenuItem(title: "(no regular apps running)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for app in running {
                submenu.addItem(buildAppSubmenu(for: app))
            }
        }

        item.submenu = submenu
        return item
    }

    private func buildAppSubmenu(for app: NSRunningApplication) -> NSMenuItem {
        let title = app.localizedName ?? app.bundleIdentifier ?? "Unknown"
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.image = app.icon?.resized(to: NSSize(width: 16, height: 16))

        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let bundleID = app.bundleIdentifier ?? ""
        let saveAll = NSMenuItem(
            title: "Save All Windows for \(title)",
            action: #selector(handleSaveAllForApp(_:)),
            keyEquivalent: "")
        saveAll.target = self
        saveAll.representedObject = bundleID

        let saveAllSizeOnly = NSMenuItem(
            title: "Save All Windows (Size Only) for \(title)",
            action: #selector(handleSaveAllForAppSizeOnly(_:)),
            keyEquivalent: "")
        saveAllSizeOnly.target = self
        saveAllSizeOnly.representedObject = bundleID

        let restoreAll = NSMenuItem(
            title: "Restore All Windows for \(title)",
            action: #selector(handleRestoreAllForApp(_:)),
            keyEquivalent: "")
        restoreAll.target = self
        restoreAll.representedObject = bundleID

        submenu.addItem(saveAll)
        submenu.addItem(saveAllSizeOnly)
        submenu.addItem(restoreAll)

        menuItem.submenu = submenu
        return menuItem
    }

    /// Lists the active layout's rules; picking one raises the first live
    /// window that matches, switching Spaces to follow it. Navigation only —
    /// no window is moved.
    private func buildJumpSubmenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Jump to Window", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let rules = state.activeLayout?.rules ?? []
        if rules.isEmpty {
            let empty = NSMenuItem(title: "(no rules in active layout)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for rule in rules {
                let ruleItem = NSMenuItem(
                    title: MenuBarModel.jumpTitle(for: rule),
                    action: #selector(handleJumpToWindow(_:)),
                    keyEquivalent: "")
                ruleItem.target = self
                ruleItem.representedObject = rule.id.uuidString
                submenu.addItem(ruleItem)
            }
        }

        item.submenu = submenu
        return item
    }

    private func buildLayoutsSubmenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Layout", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let items = MenuBarModel.layoutItems(
            layouts: state.config.layouts,
            activeLayoutID: state.config.activeLayoutID)
        if items.isEmpty {
            let empty = NSMenuItem(title: "(no layouts)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for layout in items {
                let layoutItem = NSMenuItem(
                    title: layout.title,
                    action: #selector(handleActivateLayout(_:)),
                    keyEquivalent: "")
                layoutItem.state = layout.isActive ? .on : .off
                layoutItem.target = self
                layoutItem.representedObject = layout.id.uuidString
                submenu.addItem(layoutItem)
            }
        }

        item.submenu = submenu
        return item
    }

    private func menuItem(title: String, selector: Selector, keyEquivalent: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    // MARK: - Action handlers

    @objc
    private func handleSaveFocusedAllApp() {
        Task { await coordinator.saveFocusedWindowAllApp() }
    }

    @objc
    private func handleSaveFocusedTitleOnly() {
        Task { await coordinator.saveFocusedWindowTitleOnly() }
    }

    @objc
    private func handleSaveAll() {
        Task { await coordinator.saveAllWindows() }
    }

    @objc
    private func handleSaveFocusedAllAppSizeOnly() {
        Task { await coordinator.saveFocusedWindowAllApp(restoresPosition: false) }
    }

    @objc
    private func handleSaveFocusedTitleOnlySizeOnly() {
        Task { await coordinator.saveFocusedWindowTitleOnly(restoresPosition: false) }
    }

    @objc
    private func handleSaveAllSizeOnly() {
        Task { await coordinator.saveAllWindows(restoresPosition: false) }
    }

    @objc
    private func handleRestoreAll() {
        Task { await coordinator.restoreAllWindows() }
    }

    @objc
    private func handleSaveAllForApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String, !bundleID.isEmpty else { return }
        Task { @MainActor in
            let handles = WindowProbe.windows(forBundleID: bundleID)
            await coordinator.save(windowsForUI: handles)
        }
    }

    @objc
    private func handleSaveAllForAppSizeOnly(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String, !bundleID.isEmpty else { return }
        Task { @MainActor in
            let handles = WindowProbe.windows(forBundleID: bundleID)
            await coordinator.save(windowsForUI: handles, restoresPosition: false)
        }
    }

    @objc
    private func handleRestoreAllForApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String, !bundleID.isEmpty else { return }
        Task { @MainActor in
            let handles = WindowProbe.windows(forBundleID: bundleID)
            await coordinator.restore(windowsForUI: handles)
        }
    }

    @objc
    private func handleJumpToWindow(_ sender: NSMenuItem) {
        guard let uuidString = sender.representedObject as? String,
              let id = UUID(uuidString: uuidString) else { return }
        Task { await coordinator.jumpToWindow(ruleID: id) }
    }

    @objc
    private func handleActivateLayout(_ sender: NSMenuItem) {
        guard let uuidString = sender.representedObject as? String,
              let id = UUID(uuidString: uuidString) else { return }
        setActiveLayout(id)
        rebuildMenu()
    }

    @objc
    private func handleSettings() {
        openSettings()
    }

    @objc
    private func handleEditRules() {
        openRulesEditor()
    }

    @objc
    private func handleAbout() {
        openAboutWindow()
    }

    @objc
    private func handleWelcome() {
        openWelcome()
    }

    @objc
    private func handleExportDiagnostics() {
        exportDiagnostics()
    }

    @objc
    private func handleQuit() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Unreachable windows (stranded on another Space)

extension MenuBarController {
    /// Surfaces windows Put is managing that are stranded on another Space
    /// (app running, no reachable window). Each entry activates the app and
    /// re-places the window. Only rendered when there's something to recover.
    func addUnreachableSection(to menu: NSMenu) {
        let windows = state.unreachableWindows
        guard !windows.isEmpty else { return }
        let header = NSMenuItem(title: "On another Space", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for window in windows {
            let item = NSMenuItem(
                title: "Recover \(window.label)",
                action: #selector(handleRecoverUnreachable(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = window.ruleID.uuidString
            menu.addItem(item)
        }
        menu.addItem(.separator())
    }

    @objc
    func handleRecoverUnreachable(_ sender: NSMenuItem) {
        guard let uuidString = sender.representedObject as? String,
              let id = UUID(uuidString: uuidString) else { return }
        Task { await coordinator.recoverUnreachable(ruleID: id) }
    }
}

private extension NSImage {
    /// Renders a new image at the target size using a drawing handler. This
    /// avoids the deprecated `lockFocus`/`unlockFocus` pair which is fragile
    /// under retina backing.
    func resized(to size: NSSize) -> NSImage {
        let source = self
        return NSImage(size: size, flipped: false) { rect in
            source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
    }
}
