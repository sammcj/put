import PutAutomation
import SwiftUI

public enum SettingsTab: Hashable {
    case general
    case hotkeys
    case rules
    case layouts
    case displays
    case about
}

@MainActor
@Observable
public final class SettingsNavigation {
    public var selectedTab: SettingsTab = .general
    public init() {}
}

struct SettingsView: View {
    @Bindable var state: AppState
    let persister: ConfigPersister
    let coordinator: ActionCoordinator
    @Bindable var loginItem: LoginItemController
    @Bindable var navigation: SettingsNavigation
    let aboutInfo: AboutInfo
    let onShowWelcome: () -> Void
    let onExportSettings: () -> Void
    let onImportSettings: () -> Void

    var body: some View {
        TabView(selection: $navigation.selectedTab) {
            GeneralTab(
                state: state,
                persister: persister,
                loginItem: loginItem,
                onShowWelcome: onShowWelcome,
                onExportSettings: onExportSettings,
                onImportSettings: onImportSettings)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)

            HotkeysTab()
                .tabItem { Label("Hotkeys", systemImage: "keyboard") }
                .tag(SettingsTab.hotkeys)

            RulesTab(state: state, persister: persister, coordinator: coordinator)
                .tabItem { Label("Rules", systemImage: "rectangle.on.rectangle") }
                .tag(SettingsTab.rules)

            LayoutsTab(state: state, persister: persister)
                .tabItem { Label("Layouts", systemImage: "rectangle.stack") }
                .tag(SettingsTab.layouts)

            DisplaysTab()
                .tabItem { Label("Displays", systemImage: "display.2") }
                .tag(SettingsTab.displays)

            AboutTab(info: aboutInfo)
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .frame(minWidth: 1000, minHeight: 560)
    }
}
