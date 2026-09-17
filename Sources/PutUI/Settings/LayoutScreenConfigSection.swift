import PutAutomation
import PutCore
import PutDisplay
import SwiftUI

/// "Screen configuration triggers" section inside the Layouts tab. A layout
/// can hold several captured configurations so it auto-activates across more
/// than one monitor arrangement. Owns its own alert state (capture conflict,
/// removal confirmation, capture failure) so the parent `LayoutsTab` stays
/// focused on layout selection.
struct LayoutScreenConfigSection: View {
    @Bindable var state: AppState
    let persister: ConfigPersister
    @Binding var layout: PutCore.Layout

    @State private var captureFailure: String?
    @State private var conflict: ConflictPrompt?
    @State private var pendingRemoval: RemovalPrompt?

    /// Pending capture awaiting user confirmation when the proposed config
    /// already belongs to another layout.
    private struct ConflictPrompt: Identifiable {
        let id = UUID()
        let conflictingLayoutID: PutCore.Layout.ID
        let conflictingLayoutName: String
        let proposed: ScreenConfigTrigger
    }

    /// Pending trigger removal awaiting confirmation.
    private struct RemovalPrompt: Identifiable {
        let id = UUID()
        let key: Set<String>
        let displays: [DisplayFingerprint]
    }

    var body: some View {
        Section("Screen configuration triggers") {
            if layout.screenConfigs.isEmpty {
                emptyView
            } else {
                ForEach(layout.screenConfigs, id: \.identityKey) { trigger in
                    triggerRow(trigger)
                }
                Button("Add current configuration") {
                    captureCurrent()
                }
                .padding(.top, 4)
            }
        }
        .alert(item: $conflict) { prompt in
            Alert(
                title: Text("This screen configuration is already used"),
                message: Text(conflictMessage(for: prompt)),
                primaryButton: .destructive(Text("Move here")) {
                    applyTrigger(prompt.proposed, evicting: prompt.conflictingLayoutID)
                },
                secondaryButton: .cancel())
        }
        .alert(item: $pendingRemoval) { prompt in
            Alert(
                title: Text("Remove screen-config trigger?"),
                message: Text(removalMessage(for: prompt)),
                primaryButton: .destructive(Text("Remove")) {
                    removeTrigger(prompt.key)
                },
                secondaryButton: .cancel())
        }
        .alert(
            "Couldn't read displays",
            isPresented: captureErrorBinding,
            presenting: captureFailure)
        { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func triggerRow(_ trigger: ScreenConfigTrigger) -> some View {
        let key = trigger.identityKey
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(DisplaySetFormatter.label(for: trigger.displays))
                    .font(.body.weight(.medium))
                Text("ID \(DisplaySetFormatter.shortHash(for: trigger.displays))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text("Captured \(trigger.capturedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle(
                "Auto-activate when this configuration is detected",
                isOn: Binding(
                    get: { trigger.autoActivate },
                    set: { newValue in updateTrigger(key) { $0.autoActivate = newValue } }))

            Button("Remove", role: .destructive) {
                pendingRemoval = RemovalPrompt(key: key, displays: trigger.displays)
            }
        }
        .padding(.vertical, 4)
    }

    private var emptyView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No triggers captured.")
                .foregroundStyle(.secondary)
            Text(
                "Capture a display set so this layout activates automatically whenever that arrangement is connected. "
                    + "Add more than one to cover several arrangements.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Capture current configuration") {
                captureCurrent()
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Actions

    private func captureCurrent() {
        let displays: [DisplayFingerprint]
        do {
            displays = try DisplayProbe.snapshot()
        } catch {
            captureFailure = "Put couldn't read the current display arrangement: \(error.localizedDescription)"
            return
        }
        guard !displays.isEmpty else {
            captureFailure = "No active displays were detected."
            return
        }

        let proposed = ScreenConfigTrigger(displays: displays)

        // Re-capturing a configuration this layout already holds refreshes it
        // in place (new fingerprints + timestamp) rather than adding a
        // duplicate identity set.
        if layout.screenConfigs.contains(where: { $0.identityKey == proposed.identityKey }) {
            updateTrigger(proposed.identityKey) {
                $0.displays = displays
                $0.capturedAt = proposed.capturedAt
            }
            return
        }

        if let conflicting = state.config.layoutClaimingScreenConfig(
            identicalTo: proposed,
            excluding: layout.id)
        {
            conflict = ConflictPrompt(
                conflictingLayoutID: conflicting.id,
                conflictingLayoutName: conflicting.name,
                proposed: proposed)
            return
        }
        applyTrigger(proposed, evicting: nil)
    }

    private func applyTrigger(
        _ trigger: ScreenConfigTrigger,
        evicting evictedLayoutID: PutCore.Layout.ID?)
    {
        if let evictedLayoutID,
           let evictedIndex = state.config.layouts.firstIndex(where: { $0.id == evictedLayoutID })
        {
            state.config.layouts[evictedIndex].screenConfigs.removeAll { $0.identityKey == trigger.identityKey }
        }
        guard let index = state.config.layouts.firstIndex(where: { $0.id == layout.id }) else { return }
        state.config.layouts[index].screenConfigs.append(trigger)
        persister.scheduleWrite()
    }

    private func removeTrigger(_ key: Set<String>) {
        guard let index = state.config.layouts.firstIndex(where: { $0.id == layout.id }) else { return }
        state.config.layouts[index].screenConfigs.removeAll { $0.identityKey == key }
        persister.scheduleWrite()
    }

    private func updateTrigger(_ key: Set<String>, _ mutation: (inout ScreenConfigTrigger) -> Void) {
        guard let index = state.config.layouts.firstIndex(where: { $0.id == layout.id }),
              let triggerIndex = state.config.layouts[index].screenConfigs.firstIndex(where: { $0.identityKey == key })
        else { return }
        mutation(&state.config.layouts[index].screenConfigs[triggerIndex])
        persister.scheduleWrite()
    }

    // MARK: - Messages

    private func removalMessage(for prompt: RemovalPrompt) -> String {
        let label = DisplaySetFormatter.label(for: prompt.displays)
        let hash = DisplaySetFormatter.shortHash(for: prompt.displays)
        return "Layout \"\(layout.name)\" will no longer auto-activate when \(label) [\(hash)] is connected."
    }

    private func conflictMessage(for prompt: ConflictPrompt) -> String {
        let label = DisplaySetFormatter.label(for: prompt.proposed.displays)
        let hash = DisplaySetFormatter.shortHash(for: prompt.proposed.displays)
        let other = prompt.conflictingLayoutName
        return """
        \(label) [\(hash)] is currently a trigger for layout "\(other)". \
        Moving it here will add this trigger to the selected layout and clear \
        it from "\(other)".
        """
    }

    private var captureErrorBinding: Binding<Bool> {
        Binding(
            get: { captureFailure != nil },
            set: { if !$0 { captureFailure = nil } })
    }
}
