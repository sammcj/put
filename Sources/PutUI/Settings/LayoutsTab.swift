import KeyboardShortcuts
import PutAutomation
import PutCore
import PutHotkeys
import SwiftUI

struct LayoutsTab: View {
    @Bindable var state: AppState
    let persister: ConfigPersister

    @State private var selectedLayoutID: PutCore.Layout.ID?
    @State private var newLayoutName = ""
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        HSplitView {
            layoutList
                .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
            layoutDetail
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - List

    private var layoutList: some View {
        VStack(alignment: .leading) {
            HStack {
                TextField("New layout", text: $newLayoutName)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    addLayout()
                }
                .disabled(newLayoutName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            List(selection: $selectedLayoutID) {
                ForEach(state.config.layouts) { layout in
                    HStack {
                        Text(layout.name)
                        if layout.id == state.config.activeLayoutID {
                            Text("active")
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.2))
                                .clipShape(Capsule())
                        }
                        Spacer()
                        Text("\(layout.rules.count) rule\(layout.rules.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(Optional(layout.id))
                }
            }
            .listStyle(.sidebar)

            HStack {
                Button("Activate selected") {
                    guard let id = selectedLayoutID else { return }
                    state.config.activeLayoutID = id
                    persister.scheduleWrite()
                }
                .disabled(selectedLayoutID == nil)

                Button("Duplicate") {
                    guard let id = selectedLayoutID else { return }
                    duplicateLayout(id: id)
                }
                .disabled(selectedLayoutID == nil)

                Button("Delete") {
                    guard let id = selectedLayoutID else { return }
                    deleteLayout(id: id)
                }
                .disabled(!canDeleteSelected)
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder private var layoutDetail: some View {
        if let binding = bindingForSelectedLayout() {
            Form {
                Section("Identity") {
                    TextField("Name", text: binding.name)
                        .focused($nameFieldFocused)
                }
                Section("Activation hotkey") {
                    KeyboardShortcuts.Recorder(
                        "Activate this layout",
                        name: .layoutActivation(layoutID: binding.id.wrappedValue))
                    Text("Pressing the recorded shortcut switches the active layout and applies its rules.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LayoutScreenConfigSection(
                    state: state,
                    persister: persister,
                    layout: binding)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .textFieldStyle(.roundedBorder)
            // Only persist on edits that belong to this tab. Rule edits come
            // through RulesTab and have their own persist call; tracking the
            // whole layout here double-writes for every keystroke in a rule.
            // The activation shortcut is stored in `UserDefaults` by
            // `KeyboardShortcuts` and doesn't need our persistence.
            .onChange(of: binding.name.wrappedValue) { _, _ in
                persister.scheduleWrite()
            }
        } else {
            ContentUnavailableView(
                "No layout selected",
                systemImage: "rectangle.stack",
                description: Text("Pick a layout to rename it or record a per-layout activation shortcut."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Helpers

    private var canDeleteSelected: Bool {
        guard let id = selectedLayoutID else { return false }
        return state.config.layouts.count > 1 && id != state.config.activeLayoutID
    }

    private func bindingForSelectedLayout() -> Binding<PutCore.Layout>? {
        guard let id = selectedLayoutID,
              let initialIndex = state.config.layouts.firstIndex(where: { $0.id == id })
        else { return nil }
        // Capture a snapshot so the getter has a safe fallback if SwiftUI
        // reads this binding after the layout has been removed.
        let initialLayout = state.config.layouts[initialIndex]
        let capturedState = state
        return Binding(
            get: {
                guard let index = capturedState.config.layouts.firstIndex(where: { $0.id == id })
                else { return initialLayout }
                return capturedState.config.layouts[index]
            },
            set: { newValue in
                guard let index = capturedState.config.layouts.firstIndex(where: { $0.id == id })
                else { return }
                capturedState.config.layouts[index] = newValue
            })
    }

    private func addLayout() {
        let trimmed = newLayoutName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let layout = PutCore.Layout(name: trimmed)
        state.config.layouts.append(layout)
        selectedLayoutID = layout.id
        newLayoutName = ""
        persister.scheduleWrite()
    }

    private func duplicateLayout(id: UUID) {
        guard let original = state.config.layouts.first(where: { $0.id == id }) else { return }
        let copy = original.duplicated(name: "COPY OF \(original.name)")
        state.config.layouts.append(copy)
        selectedLayoutID = copy.id
        persister.scheduleWrite()
        // Defer focus by one runloop tick so the detail form has rebuilt
        // around the new selection before we hand focus to its name field.
        Task { @MainActor in
            nameFieldFocused = true
        }
    }

    private func deleteLayout(id: UUID) {
        guard canDeleteSelected else { return }
        state.config.layouts.removeAll { $0.id == id }
        if selectedLayoutID == id { selectedLayoutID = nil }
        persister.scheduleWrite()
    }
}
