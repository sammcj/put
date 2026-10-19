import AppKit
import Foundation
import PutAutomation
import PutUI

extension AppDelegate {
    /// `put://` entry point. A URL that launches Put arrives before bootstrap
    /// has loaded the config, so it waits in `pendingURLs` until then.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard isBootstrapped else {
            pendingURLs.append(contentsOf: urls)
            return
        }
        for url in urls {
            performURLCommand(url)
        }
    }

    /// Each command takes the same path as its hotkey or menu item, including
    /// the restore source, so per-rule trigger opt-outs behave identically.
    func performURLCommand(_ url: URL) {
        guard state.config.urlCommandsEnabled else {
            log.notice("Ignoring URL; put:// commands are off in Settings: \(url.absoluteString, privacy: .public)")
            return
        }
        guard let command = URLCommand(url: url) else {
            log.warning("Ignoring unrecognised URL: \(url.absoluteString, privacy: .public)")
            return
        }
        log.info("URL command: \(url.absoluteString, privacy: .public)")
        switch command {
        case .saveFocusedWindow:
            Task { await coordinator.saveFocusedWindowAllApp() }
        case .saveFocusedWindowTitleOnly:
            Task { await coordinator.saveFocusedWindowTitleOnly() }
        case .saveAllWindows:
            Task { await coordinator.saveAllWindows() }
        case .restoreActiveWindow:
            Task { await coordinator.restoreActiveWindow() }
        case .restoreAllWindows:
            Task { await coordinator.restoreAllWindows(source: .explicitAll) }
        case let .activateLayout(reference):
            guard let layout = reference.resolve(in: state.config.layouts) else {
                log.warning("URL names no existing layout: \(url.absoluteString, privacy: .public)")
                return
            }
            Task { await activateLayout(id: layout.id) }
        case let .openSettings(tab):
            showSettings(tab: tab.flatMap(SettingsTab.init(rawValue:)))
        }
    }
}
