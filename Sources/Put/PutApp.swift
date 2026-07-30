import AppKit
import Foundation
import OSLog
import PutAutomation
import PutCore
import PutHotkeys
import PutStorage
import PutUI
import PutWindows
import UniformTypeIdentifiers

@main
@MainActor
enum PutApp {
    static func main() {
        let delegate = AppDelegate()
        NSApplication.shared.delegate = delegate
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, AppWindowLifecycle {
    private let log: Logger = PutLog.logger(category: "app")
    private let fileLog = FileLog()
    private let store = ConfigStore()
    private var state: AppState!
    private var coordinator: ActionCoordinator!
    private var hotkeyManager: HotkeyManager!
    private var menuBar: MenuBarController!
    private var onboardingWindow: OnboardingWizardController?
    private var persister: ConfigPersister!
    private var autoTriggers: AutoTriggerController!
    private var layoutHotkeys: LayoutHotkeys!
    private var loginItem: LoginItemController!
    private var activationHistory: ActivationHistory!
    private var layoutObservationTask: Task<Void, Never>?
    private var settingsWindow: SettingsWindowController?
    private var aboutWindow: AboutWindow?
    private lazy var relaunchHandler = RelaunchHandler(
        openSettings: { [weak self] in self?.showSettings() })
    /// Number of user-facing windows currently visible. Drives the app's
    /// activation policy: any window open means `.regular` (dock icon shown);
    /// zero means `.accessory` (menu bar only). Prevents the dock icon from
    /// vanishing while the About window is open just because Settings closed.
    private var openWindowCount = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        log.info("Put launched; version=\(Self.versionString(), privacy: .public)")

        Task { @MainActor in
            await bootstrap()
        }
    }

    /// Install a main menu so standard shortcuts (⌘Q, ⌘,, ⌘H) work when any
    /// of Put's windows is key. Accessory apps don't show the menu bar when
    /// active, but the responder chain still routes key equivalents through
    /// the main menu, so this is what makes ⌘Q actually quit.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = buildAppMenu()
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = buildEditMenu()
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = buildWindowMenu()
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    private func buildAppMenu() -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(
            title: "About Put",
            action: #selector(aboutMenuAction),
            keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: "Settings...",
            action: #selector(settingsMenuAction),
            keyEquivalent: ","))
        appMenu.addItem(NSMenuItem(
            title: "Show Welcome...",
            action: #selector(showWelcomeAction),
            keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: "Hide Put",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"))
        let hideOthers = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(
            title: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: "Quit Put",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"))
        return appMenu
    }

    /// Standard Edit menu so TextFields in the Settings window get the
    /// usual copy/paste shortcuts.
    private func buildEditMenu() -> NSMenu {
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        return editMenu
    }

    /// Window menu so Settings, About, and Onboarding windows pick up the
    /// standard ⌘W close shortcut. Without this there's no menu item
    /// wired to `performClose:`, and ⌘W silently does nothing.
    private func buildWindowMenu() -> NSMenu {
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(
            title: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"))
        windowMenu.addItem(NSMenuItem(
            title: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"))
        return windowMenu
    }

    @objc
    private func aboutMenuAction() {
        showAbout()
    }

    @objc
    private func settingsMenuAction() {
        showSettings()
    }

    @objc
    private func showWelcomeAction() {
        showOnboarding(reason: .userRequested)
    }

    private func bootstrap() async {
        let initialConfig: Config
        do {
            initialConfig = try await store.load()
        } catch {
            log.error("Config load failed; using bootstrap: \(error.localizedDescription, privacy: .public)")
            initialConfig = Config.bootstrap()
        }

        state = AppState(config: initialConfig)
        // Track the app the user was in before a Put window took focus, so the
        // Rules tab "+"/Cmd-N captures that app's window, not Put's Settings.
        activationHistory = ActivationHistory()
        activationHistory.start()
        coordinator = ActionCoordinator(
            state: state,
            store: store,
            fileLog: fileLog,
            activationHistory: activationHistory,
            saveFlash: SaveFlashPresenter(),
            saveScopeNotice: SaveScopeAlertPresenter())
        persister = ConfigPersister(state: state, store: store)
        loginItem = LoginItemController()
        autoTriggers = AutoTriggerController(state: state, coordinator: coordinator)
        autoTriggers.onActivateLayout = { [weak self] in self?.activateLayoutFromTrigger(id: $0) }
        autoTriggers.start()

        wireHotkeys()
        wireMenuBar()

        // First launch gets the full multi-step welcome wizard. Returning
        // users with revoked Accessibility get the wizard at the AX step so
        // the welcome blurb doesn't replay on every revoke.
        // `promptIfNeeded` is idempotent — only one system dialog per launch.
        if state.config.firstRunCompletedAt == nil {
            log.info("First launch detected; showing welcome wizard")
            if !AccessibilityTrust.isTrusted {
                AccessibilityTrust.promptIfNeeded()
            }
            showOnboarding(reason: .firstRun)
        } else if !AccessibilityTrust.isTrusted {
            log.info("Accessibility not yet granted; showing onboarding at AX step")
            AccessibilityTrust.promptIfNeeded()
            showOnboarding(reason: .userRequested, startAt: .accessibility)
        }

        await fileLog.append(
            level: .info,
            category: "lifecycle",
            message: "App started",
            metadata: ["version": Self.versionString()])

        await fireLaunchRestore()
    }

    private func wireHotkeys() {
        hotkeyManager = HotkeyManager()
        hotkeyManager.bind(handlers: .init(
            saveFocusedWindowAllApp: { [coordinator] in Task { await coordinator?.saveFocusedWindowAllApp() } },
            saveFocusedWindowTitleOnly: { [coordinator] in Task { await coordinator?.saveFocusedWindowTitleOnly() } },
            restoreActiveWindow: { [coordinator] in Task { await coordinator?.restoreActiveWindow() } },
            saveAllWindows: { [coordinator] in Task { await coordinator?.saveAllWindows() } },
            restoreAllWindows: { [coordinator] in Task { await coordinator?.restoreAllWindows() } }))

        layoutHotkeys = LayoutHotkeys()
        layoutHotkeys.bind { [weak self] layoutID in
            Task { @MainActor in await self?.activateLayout(id: layoutID) }
        }
        syncLayoutHotkeys()
        observeLayoutChanges()
    }

    private func wireMenuBar() {
        menuBar = MenuBarController(coordinator: coordinator, state: state)
        menuBar.openSettings = { [weak self] in self?.showSettings() }
        menuBar.openRulesEditor = { [weak self] in self?.showRulesEditor() }
        menuBar.openAboutWindow = { [weak self] in self?.showAbout() }
        menuBar.exportDiagnostics = { [weak self] in self?.exportDiagnostics() }
        menuBar.openWelcome = { [weak self] in self?.showOnboarding(reason: .userRequested) }
        menuBar.setActiveLayout = { [weak self] id in self?.setActiveLayoutFromMenu(id: id) }
        menuBar.install()
    }

    /// Re-launching Put while it's already running (Spotlight, Raycast,
    /// `open -a Put`, etc.) opens Settings. Returning `false` suppresses the
    /// default AppKit reopen behaviour, which is irrelevant for an accessory
    /// app with no Dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        relaunchHandler.handleRelaunch(hasVisibleWindows: flag)
        return false
    }

    /// Restore-on-launch trigger. Skipped when AX isn't granted yet — the
    /// onboarding window owns the first-grant restore handoff. A matching
    /// layout-trigger short-circuits the global path so we don't
    /// double-restore.
    private func fireLaunchRestore() async {
        guard AccessibilityTrust.isTrusted else { return }
        let (layoutFired, _) = await autoTriggers.applyLayoutTriggersIfMatching(reasonList: "launch")
        if !layoutFired, state.config.autoTriggers.onPutLaunch {
            log.info("onPutLaunch trigger fired; restoring windows")
            await coordinator.restoreAllWindows(source: .auto)
        }
    }

    /// Flush the debounced config write before quitting. `ConfigPersister`
    /// debounces settings edits (layout pick from the menu/hotkey, Settings
    /// edits) for 400ms; without this a change made inside that window is lost
    /// on ⌘Q. `flush()` is async, so we hold termination with `.terminateLater`
    /// and reply once the write completes. No-op before bootstrap wires the
    /// persister.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let persister else { return .terminateNow }
        Task { @MainActor in
            await persister.flush()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager?.unbind()
        layoutHotkeys?.removeAll()
        layoutObservationTask?.cancel()
        autoTriggers?.stop()
        loginItem?.stop()
        activationHistory?.stop()
        log.info("Put terminating")
    }

    // MARK: - Layout hotkeys

    private func syncLayoutHotkeys() {
        layoutHotkeys.syncRegistrations(layoutIDs: state.config.layouts.map(\.id))
    }

    private func observeLayoutChanges() {
        layoutObservationTask?.cancel()
        // Event-driven replacement for the old 2 s poll: withObservationTracking
        // fires its onChange closure exactly once per access, so we rebuild
        // and reinstall the tracking block on every layout-set change. Covers
        // both user edits in the Settings UI and coordinator mutations.
        layoutObservationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let waiter = AsyncStream<Void> { continuation in
                    withObservationTracking {
                        _ = self.state.config.layouts.map(\.id)
                    } onChange: {
                        continuation.yield()
                        continuation.finish()
                    }
                }
                for await _ in waiter {
                    break
                }
                if Task.isCancelled { return }
                syncLayoutHotkeys()
            }
        }
    }

    private func activateLayout(id: UUID) async {
        guard state.config.layouts.contains(where: { $0.id == id }) else { return }
        state.config.activeLayoutID = id
        persister.scheduleWrite()
        log.info("Layout activated via hotkey: \(id.uuidString, privacy: .public)")
        await coordinator.restoreAllWindows()
    }

    /// Screen-config-trigger driven layout switch. Mirrors the hotkey-driven
    /// path (set active + persist); the controller handles the restore.
    private func activateLayoutFromTrigger(id: UUID) {
        guard state.config.layouts.contains(where: { $0.id == id }) else { return }
        state.config.activeLayoutID = id
        persister.scheduleWrite()
    }

    /// Menu-driven layout switch. Persists the selection but doesn't trigger
    /// an immediate restore; hotkey activation remains the "apply now" path.
    private func setActiveLayoutFromMenu(id: UUID) {
        guard state.config.layouts.contains(where: { $0.id == id }) else { return }
        state.config.activeLayoutID = id
        persister.scheduleWrite()
        log.info("Layout activated via menu: \(id.uuidString, privacy: .public)")
    }
}

// MARK: - Windows

extension AppDelegate {
    func didOpenUserFacingWindow() {
        openWindowCount += 1
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func didCloseUserFacingWindow() {
        openWindowCount = max(0, openWindowCount - 1)
        if openWindowCount == 0 {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func showSettings(tab: SettingsTab? = nil) {
        // A relaunch (Spotlight/`open -a Put`) during a slow `await store.load()`
        // routes here via `applicationShouldHandleReopen` before `bootstrap()`
        // has populated the implicitly-unwrapped dependencies. Bail rather than
        // fatally unwrapping nil state.
        guard state != nil, coordinator != nil, persister != nil, loginItem != nil else {
            log.info("Settings requested before bootstrap completed; ignoring")
            return
        }
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(
                state: state,
                persister: persister,
                coordinator: coordinator,
                loginItem: loginItem,
                aboutInfo: Self.aboutInfo(),
                lifecycle: self,
                onShowWelcome: { [weak self] in self?.showOnboarding(reason: .userRequested) },
                onExportSettings: { [weak self] in self?.exportSettings() },
                onImportSettings: { [weak self] in self?.importSettings() })
        }
        settingsWindow?.show(tab: tab)
    }

    private func showRulesEditor() {
        showSettings(tab: .rules)
    }

    private func showAbout() {
        if aboutWindow == nil {
            aboutWindow = AboutWindow(
                title: "About Put",
                info: Self.aboutInfo(),
                lifecycle: self)
        }
        aboutWindow?.show()
    }

    private static func aboutInfo() -> AboutInfo {
        AboutInfo(
            appName: "Put",
            version: versionString(),
            tagline: """
            Put lives in your menu bar. It remembers and restores the screen, desktop, size \
            and placement of windows when triggered by a hotkey or configurable events such \
            as changing monitors.
            """,
            copyright: "© \(yearString()) Sam McLeod",
            links: [
                AboutLink(title: "GitHub", url: URL(string: "https://github.com/sammcj/put")!),
                AboutLink(title: "smcleod.net", url: URL(string: "https://smcleod.net")!),
                AboutLink(
                    title: "GPL-3.0",
                    url: URL(string: "https://github.com/sammcj/put/blob/main/LICENSE")!),
                AboutLink(
                    title: "Credits",
                    url: URL(
                        string: "https://github.com/sammcj/put/blob/main/THIRD-PARTY-NOTICES.md")!)
            ])
    }

    private static func yearString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        return formatter.string(from: Date())
    }

    private static func versionString() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }
}

// MARK: - Onboarding and diagnostics

extension AppDelegate {
    /// Opens the welcome wizard. `.firstRun` stamps `firstRunCompletedAt` on
    /// completion so the wizard doesn't auto-show again next launch.
    /// `.userRequested` leaves the timestamp untouched. `startAt:` lets the
    /// AX-revoke handoff path skip the welcome page.
    func showOnboarding(reason: OnboardingReason, startAt: OnboardingWizardController.Step = .welcome) {
        if onboardingWindow == nil {
            let window = OnboardingWizardController(
                reason: reason,
                startAt: startAt,
                state: state,
                persister: persister,
                loginItem: loginItem,
                lifecycle: self)
            window.onCompleted = { [weak self] in
                guard let self else { return }
                if reason == .firstRun, state.config.firstRunCompletedAt == nil {
                    state.config.firstRunCompletedAt = Date()
                    persister.scheduleWrite()
                    log.info("First-run wizard completed; firstRunCompletedAt stamped")
                } else {
                    log.info("Onboarding wizard completed (reason=\(String(describing: reason), privacy: .public))")
                }
            }
            window.onWindowClosed = { [weak self] in
                self?.onboardingWindow = nil
            }
            onboardingWindow = window
        }
        onboardingWindow?.show()
    }

    func exportDiagnostics() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        panel.title = "Choose destination for Put diagnostics"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        Task { @MainActor in
            do {
                let url = try await DiagnosticsExport.build(
                    config: self.state.config,
                    destinationDirectory: destination,
                    bundleVersion: Self.versionString())
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                self.log.error("Diagnostics export failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Write a full settings backup (every `Config` field plus the
    /// `KeyboardShortcuts` bindings) to a single JSON file the user chooses.
    func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = SettingsBackupArchive.suggestedFilename()
        panel.prompt = "Export"
        panel.title = "Export Put settings"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let shortcuts = ShortcutsBackup.capture(layoutIDs: state.config.layouts.map(\.id))
            let backup = SettingsBackup(
                appVersion: Self.versionString(),
                exportedAt: Date(),
                config: state.config,
                shortcuts: shortcuts)
            try SettingsBackupArchive.write(backup, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            log.error("Settings export failed: \(error.localizedDescription, privacy: .public)")
            presentError(title: "Couldn't export settings", error: error)
        }
    }

    /// Read a settings backup, warn that it overwrites everything, then apply
    /// it on confirmation.
    func importSettings() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = "Import"
        panel.title = "Choose a Put settings backup"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let backup: SettingsBackup
        do {
            backup = try SettingsBackupArchive.read(from: url)
        } catch {
            log.error("Settings import read failed: \(error.localizedDescription, privacy: .public)")
            presentError(title: "Couldn't read that backup", error: error)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Replace all settings?"
        alert.informativeText = """
        Importing this backup replaces your current layouts, rules, hotkeys, and preferences with \
        the ones in the file. This can't be undone.
        """
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task { @MainActor in await self.applyImportedSettings(backup) }
    }

    private func applyImportedSettings(_ backup: SettingsBackup) async {
        let oldLayoutIDs = Set(state.config.layouts.map(\.id))

        var config = backup.config
        // `decode` already rejected a newer-than-supported schema; stamp the
        // current version so subsequent writes are current.
        config.schemaVersion = putSchemaVersion
        state.config = config

        // Persist now rather than via the debounced path so disk matches the
        // imported state immediately.
        await persister.flush()

        // Reconcile hotkey bindings across both the old and new layout ids so
        // stale per-layout bindings are cleared on a full restore.
        let layoutIDs = Array(oldLayoutIDs.union(config.layouts.map(\.id)))
        ShortcutsBackup.apply(backup.shortcuts, layoutIDs: layoutIDs)

        // Re-register per-layout handlers for the imported layout set and
        // reconcile the login item with the imported preference.
        syncLayoutHotkeys()
        do {
            try loginItem.setEnabled(config.launchAtLogin)
        } catch {
            log.error("Login item reconcile after import failed: \(error.localizedDescription, privacy: .public)")
        }

        log.info("Settings imported (appVersion=\(backup.appVersion, privacy: .public))")
    }

    private func presentError(title: String, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
