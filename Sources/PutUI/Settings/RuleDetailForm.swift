import CoreGraphics
import PutAutomation
import PutCore
import PutDisplay
import SwiftUI

/// Match-criteria editor for a single `Rule`. Extracted from `RulesTab` so the
/// validation logic and match fields live together without bloating the
/// list/header view; the placement geometry lives in `RulePlacementForm`.
struct RuleDetailForm: View {
    @Binding var rule: Rule
    @Binding var regexErrors: [UUID: String]
    let connectedDisplays: [DisplayFingerprint]

    var body: some View {
        HSplitView {
            matchForm
                .frame(minWidth: 360, idealWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
            RulePlacementForm(rule: $rule, connectedDisplays: connectedDisplays)
                .frame(minWidth: 340, idealWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var matchForm: some View {
        Form {
            Section("Identity") {
                TextField("Name", text: $rule.descriptiveLabel)
                    .help("A human-friendly name for this rule, shown in the menu bar and rules list.")
                Toggle("Enabled", isOn: $rule.isEnabled)
            }

            Section {
                TextField("Bundle ID", text: $rule.matchCriteria.bundleID)
                    .help(
                        "The app's bundle identifier, e.g. com.apple.Safari. Usually set automatically when the rule was created.")
                TextField("Title pattern", text: $rule.matchCriteria.titlePattern)
                    .help("Match windows whose title contains or matches this text. Leave blank to match any title.")
                Picker("Title match", selection: $rule.matchCriteria.titleMatchMode) {
                    Text("Literal").tag(TitleMatchMode.literal)
                    Text("Regex").tag(TitleMatchMode.regex)
                }
                .pickerStyle(.segmented)
                if let errorMessage = regexErrors[rule.id] {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Toggle("Apply to all windows of this app", isOn: $rule.matchCriteria.applyToAllWindows)
                    .help("Ignore the title pattern entirely and match any window belonging to this app.")
                Toggle("Use title pattern exclusively", isOn: $rule.matchCriteria.useTitlePatternExclusively)
                    .help(
                        "When on, only the title pattern is used for matching. "
                            + "When off, the accessibility role below must also match.")
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Window type (optional)", text: Binding(
                        get: { rule.matchCriteria.axRole ?? "" },
                        set: { rule.matchCriteria.axRole = $0.isEmpty ? nil : $0 }))
                        .help(
                            "Restrict matching to a specific accessibility role. "
                                + "Leave blank unless you need to distinguish, for example, "
                                + "a document window from a modal sheet or dialog.")
                    Text(
                        "Advanced: macOS accessibility role, e.g. AXWindow "
                            + "(regular window), AXDialog, AXSheet. Leave blank in most cases.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Match criteria")
            } footer: {
                Text(
                    "A rule matches a window when its bundle ID matches, and "
                        + "either 'apply to all windows' is on or the title pattern matches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Missing-display behaviour") {
                Picker("", selection: $rule.missingDisplayPolicy) {
                    Text("Fallback to primary, proportional").tag(MissingDisplayPolicy.primaryProportional)
                    Text("Skip").tag(MissingDisplayPolicy.skip)
                    Text("Queue for reconnect").tag(MissingDisplayPolicy.queueForReconnect)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .textFieldStyle(.roundedBorder)
    }
}
