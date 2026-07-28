import AppKit
import PutAutomation
import PutCore
import PutDisplay
import SwiftUI

struct RulesTab: View {
    @Bindable var state: AppState
    let persister: ConfigPersister
    let coordinator: ActionCoordinator

    @State private var selectedRuleID: Rule.ID?
    /// Per-rule regex compile failure message, keyed by rule ID. Cleared when
    /// the pattern compiles or the rule is switched to literal mode.
    @State private var regexErrors: [UUID: String] = [:]
    @State private var ruleIDPendingDeletion: UUID?
    /// Snapshot of currently connected displays, kept fresh by the display
    /// observer task below. Passed to the rule preview so it can render the
    /// actual arrangement alongside the saved target.
    @State private var connectedDisplays: [DisplayFingerprint] = []

    var body: some View {
        HSplitView {
            rulesList
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 360, maxHeight: .infinity)
            ruleDetail
                .frame(minWidth: 720, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .onAppear { refreshDisplays() }
        // Keep `connectedDisplays` in sync with real hardware so the rule
        // preview reflects the current arrangement without needing the tab to
        // be re-opened.
        .onDisplayConfigurationChange { refreshDisplays() }
        .confirmationDialog(
            "Delete this rule?",
            isPresented: deletionBinding,
            titleVisibility: .visible,
            presenting: ruleIDPendingDeletion)
        { id in
            Button("Delete", role: .destructive) { deleteRule(id: id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This can't be undone.")
        }
    }

    private var deletionBinding: Binding<Bool> {
        Binding(
            get: { ruleIDPendingDeletion != nil },
            set: { if !$0 { ruleIDPendingDeletion = nil } })
    }

    // MARK: - List

    private var rulesList: some View {
        VStack(alignment: .leading, spacing: 0) {
            layoutPicker
            header

            List(selection: $selectedRuleID) {
                ForEach(sortedRules(), id: \.id) { rule in
                    HStack(spacing: 6) {
                        Text(primaryLabel(for: rule))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(Self.subtitle(for: rule))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .font(.callout)
                    .tag(Optional(rule.id))
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .onKeyPress(.delete) {
                guard let id = selectedRuleID else { return .ignored }
                ruleIDPendingDeletion = id
                return .handled
            }
        }
    }

    /// Shows - and switches - the layout whose rules are being edited. The
    /// rules list, the "+" button, and the detail binding all key off
    /// `activeLayoutID`, so changing it here re-targets the whole tab. Setting
    /// the active layout is side-effect-free (no restore fires); it's the same
    /// state the Layouts tab toggles.
    private var layoutPicker: some View {
        Picker("Layout", selection: layoutSelection) {
            ForEach(state.config.layouts) { layout in
                Text(layout.name).tag(layout.id)
            }
        }
        .labelsHidden()
        .font(.callout)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
    }

    private var layoutSelection: Binding<UUID> {
        Binding(
            get: { state.config.activeLayoutID },
            set: { newID in
                guard newID != state.config.activeLayoutID else { return }
                selectedRuleID = nil
                state.config.activeLayoutID = newID
                persister.scheduleWrite()
            })
    }

    private var header: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)

            Button {
                Task { await coordinator.saveFocusedWindowAllApp() }
            } label: {
                Image(systemName: "plus").frame(width: 18)
            }
            .help("New rule from the window you were last using (⌘N)")
            .keyboardShortcut("n", modifiers: .command)

            Button {
                guard let id = selectedRuleID else { return }
                Task { await coordinator.duplicateRule(id: id) }
            } label: {
                Image(systemName: "plus.square.on.square").frame(width: 18)
            }
            .help("Duplicate the selected rule")
            .disabled(selectedRuleID == nil)

            Button {
                guard let id = selectedRuleID else { return }
                ruleIDPendingDeletion = id
            } label: {
                Image(systemName: "trash").frame(width: 18)
            }
            .help("Delete the selected rule (⌫)")
            .disabled(selectedRuleID == nil)

            Spacer(minLength: 0)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding([.bottom], 6)
    }

    // MARK: - Detail

    @ViewBuilder private var ruleDetail: some View {
        if let binding = bindingForSelectedRule() {
            RuleDetailForm(
                rule: binding,
                regexErrors: $regexErrors,
                connectedDisplays: connectedDisplays)
                // Live regex feedback runs on every field change, and every edit
                // to the selected rule schedules a write. `ConfigPersister`
                // debounces it, so a burst of keystrokes still collapses into
                // one config.json write while an uncommitted edit can't be lost
                // to a crash. Switching rules is navigation, not an edit, and
                // writes nothing.
                .onChange(of: currentRule) { old, new in
                    if let new { validateRegex(for: new) }
                    persistence.fieldChanged(from: old, to: new)
                }
                .onSubmit {
                    validateRegex(for: binding.wrappedValue)
                    persistence.committed()
                }
        } else {
            ContentUnavailableView(
                "No rule selected",
                systemImage: "rectangle.on.rectangle",
                description: Text(
                    "Save a window via a hotkey or menu item, then pick it here to tune its match criteria."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Helpers

    /// Debounced-write scheduler shared by both persistence paths. Rebuilt each
    /// access (it is stateless), closing over the injected `persister`.
    private var persistence: RuleEditPersistence {
        RuleEditPersistence(persist: { [persister] in persister.scheduleWrite() })
    }

    private func sortedRules() -> [Rule] {
        guard let active = state.activeLayout else { return [] }
        return active.rules.sorted { lhs, rhs in
            let lhsApp = appName(for: lhs.matchCriteria.bundleID)
            let rhsApp = appName(for: rhs.matchCriteria.bundleID)
            if lhsApp != rhsApp { return lhsApp.localizedCaseInsensitiveCompare(rhsApp) == .orderedAscending }
            return lhs.descriptiveLabel.localizedCaseInsensitiveCompare(rhs.descriptiveLabel) == .orderedAscending
        }
    }

    private func appName(for bundleID: String) -> String {
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        return app?.localizedName ?? bundleID
    }

    private func primaryLabel(for rule: Rule) -> String {
        let app = appName(for: rule.matchCriteria.bundleID)
        let label = rule.descriptiveLabel
        if label.isEmpty || label == app { return app }
        return "\(app) · \(label)"
    }

    /// Secondary label for a rule row: the match scope in short form. Pure, so
    /// it is unit-tested directly.
    static func subtitle(for rule: Rule) -> String {
        if rule.matchCriteria.applyToAllWindows { return "All windows" }
        if rule.matchCriteria.titlePattern.isEmpty { return "Any title" }
        let prefix = rule.matchCriteria.titleMatchMode == .regex ? "re" : "="
        return "\(prefix) \(rule.matchCriteria.titlePattern)"
    }

    private var currentRule: Rule? {
        guard let id = selectedRuleID, let active = state.activeLayout else { return nil }
        return active.rules.first { $0.id == id }
    }

    private func bindingForSelectedRule() -> Binding<Rule>? {
        guard let id = selectedRuleID,
              let layoutIndex = state.config.layouts.firstIndex(where: { $0.id == state.config.activeLayoutID }),
              let initialRuleIndex = state.config.layouts[layoutIndex].rules.firstIndex(where: { $0.id == id })
        else { return nil }
        // Capture a snapshot so the getter has a safe fallback if SwiftUI
        // reads this binding after the rule has been removed.
        let initialRule = state.config.layouts[layoutIndex].rules[initialRuleIndex]
        let capturedState = state
        return Binding(
            get: {
                guard let li = capturedState.config.layouts
                    .firstIndex(where: { $0.id == capturedState.config.activeLayoutID }),
                    let ri = capturedState.config.layouts[li].rules.firstIndex(where: { $0.id == id })
                else { return initialRule }
                return capturedState.config.layouts[li].rules[ri]
            },
            set: { newValue in
                guard let li = capturedState.config.layouts
                    .firstIndex(where: { $0.id == capturedState.config.activeLayoutID }),
                    let ri = capturedState.config.layouts[li].rules.firstIndex(where: { $0.id == id })
                else { return }
                capturedState.config.layouts[li].rules[ri] = newValue
            })
    }

    private func refreshDisplays() {
        connectedDisplays = (try? DisplayProbe.snapshot()) ?? []
    }

    private func deleteRule(id: UUID) {
        guard let layoutIndex = state.config.layouts.firstIndex(where: { $0.id == state.config.activeLayoutID }) else {
            return
        }
        if selectedRuleID == id { selectedRuleID = nil }
        state.config.layouts[layoutIndex].rules.removeAll { $0.id == id }
        regexErrors.removeValue(forKey: id)
        persister.scheduleWrite()
    }

    /// Compile the rule's title pattern when it's in regex mode. Invalid
    /// patterns fail closed at match time (`RuleMatcher` never matches), so
    /// this is purely for surfacing the error to the user before they save.
    private func validateRegex(for rule: Rule) {
        guard rule.matchCriteria.titleMatchMode == .regex,
              !rule.matchCriteria.titlePattern.isEmpty
        else {
            if regexErrors[rule.id] != nil { regexErrors.removeValue(forKey: rule.id) }
            return
        }
        do {
            _ = try NSRegularExpression(pattern: rule.matchCriteria.titlePattern)
            if regexErrors[rule.id] != nil { regexErrors.removeValue(forKey: rule.id) }
        } catch {
            regexErrors[rule.id] = "Regex doesn't compile: \(error.localizedDescription)"
        }
    }
}
