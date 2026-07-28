import PutAutomation
import PutCore
import SwiftUI

struct GeneralTab: View {
    @Bindable var state: AppState
    let persister: ConfigPersister
    @Bindable var loginItem: LoginItemController
    let onShowWelcome: () -> Void
    let onExportSettings: () -> Void
    let onImportSettings: () -> Void

    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            if let saveError = state.lastSaveError {
                Section {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Settings not saved to disk")
                                .font(.subheadline.weight(.semibold))
                            Text(saveError)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button("Dismiss") { state.lastSaveError = nil }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }
            }

            Section {
                // Bind the toggle to the live `SMAppService` state so the UI
                // reflects reality (e.g. the user disabling Put from System
                // Settings) rather than just the stored config preference.
                // On user flip: try to apply, and only mirror into the config
                // (for diagnostics / future defaults) on success.
                Toggle("Launch Put at login", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { newValue in
                        launchAtLoginError = state.applyLaunchAtLogin(
                            newValue,
                            loginItem: loginItem,
                            onChange: { persister.scheduleWrite() })
                    }))
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Automatic restore triggers") {
                Toggle("When Put launches", isOn: Binding(
                    get: { state.config.autoTriggers.onPutLaunch },
                    set: { state.config.autoTriggers.onPutLaunch = $0
                        persister.scheduleWrite()
                    }))
                Toggle("On display configuration change", isOn: Binding(
                    get: { state.config.autoTriggers.onDisplayChange },
                    set: { state.config.autoTriggers.onDisplayChange = $0
                        persister.scheduleWrite()
                    }))
                Toggle("On application launch", isOn: Binding(
                    get: { state.config.autoTriggers.onAppLaunch },
                    set: { state.config.autoTriggers.onAppLaunch = $0
                        persister.scheduleWrite()
                    }))
                Toggle("On wake from sleep", isOn: Binding(
                    get: { state.config.autoTriggers.onWake },
                    set: { state.config.autoTriggers.onWake = $0
                        persister.scheduleWrite()
                    }))
            }

            Section {
                Toggle("Leave windows I've moved alone", isOn: Binding(
                    get: { state.config.autoTriggers.respectManualMoves },
                    set: { state.config.autoTriggers.respectManualMoves = $0
                        persister.scheduleWrite()
                    }))
                Text(
                    """
                    After Put places a window, if you move or resize it, Put won't put it back \
                    until the display layout changes or you restore it manually. Turn this off to \
                    have every trigger re-apply the saved position.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Help") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Welcome wizard")
                            .font(.subheadline)
                        Text(
                            "Re-run the introduction and review default settings. Your existing settings stay untouched.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Show welcome again...") { onShowWelcome() }
                }
            }

            Section("Backup") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Settings backup")
                            .font(.subheadline)
                        Text(
                            """
                            Export all your layouts, rules, hotkeys, and preferences to a file, \
                            or import a backup. Importing replaces your current settings.
                            """)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Import...") { onImportSettings() }
                    Button("Export...") { onExportSettings() }
                }
            }

            Section("Default behaviour when a saved display is missing") {
                // swiftlint:disable closure_end_indentation
                Picker("", selection: Binding(
                    get: { state.config.defaultMissingDisplayPolicy },
                    set: { state.config.defaultMissingDisplayPolicy = $0
                        persister.scheduleWrite()
                    })) {
                        Text("Fallback to primary, proportional").tag(MissingDisplayPolicy.primaryProportional)
                        Text("Skip the window").tag(MissingDisplayPolicy.skip)
                        Text("Queue until the display reconnects").tag(MissingDisplayPolicy.queueForReconnect)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                // swiftlint:enable closure_end_indentation
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding()
    }
}
