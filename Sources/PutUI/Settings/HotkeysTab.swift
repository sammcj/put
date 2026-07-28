import KeyboardShortcuts
import PutHotkeys
import SwiftUI

struct HotkeysTab: View {
    var body: some View {
        Form {
            Section("Save focused window") {
                KeyboardShortcuts.Recorder(
                    "For all windows of this app",
                    name: .saveFocusedWindowAllApp)
                KeyboardShortcuts.Recorder(
                    "For this window title only",
                    name: .saveFocusedWindowTitleOnly)
            }

            Section("Restore") {
                KeyboardShortcuts.Recorder("Restore active window", name: .restoreActiveWindow)
            }

            Section("All windows across all apps") {
                KeyboardShortcuts.Recorder("Save", name: .saveAllWindows)
                KeyboardShortcuts.Recorder("Restore", name: .restoreAllWindows)
            }

            Section {
                Text("Hotkey conflicts are surfaced silently; if a shortcut stops working, clear and re-record it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding()
    }
}
