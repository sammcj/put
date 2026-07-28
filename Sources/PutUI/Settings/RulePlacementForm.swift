import CoreGraphics
import PutCore
import PutDisplay
import SwiftUI

/// Placement editor for a single `Rule`: target display, saved frame, and the
/// live preview. Split out of `RuleDetailForm` so the match criteria and the
/// placement geometry are separate, individually-reasoned views.
struct RulePlacementForm: View {
    @Binding var rule: Rule
    let connectedDisplays: [DisplayFingerprint]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            savedPlacementBox
            previewBox
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var savedPlacementBox: some View {
        GroupBox("Saved placement") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Display")
                        .foregroundStyle(.secondary)
                    Picker("", selection: displayBinding) {
                        ForEach(displayOptions, id: \.id) { display in
                            Text(label(for: display)).tag(display.id)
                        }
                    }
                    .labelsHidden()
                    .gridCellColumns(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if rule.restoresPosition {
                    GridRow {
                        Text("X").foregroundStyle(.secondary)
                        TextField("", value: frameBinding(\.origin.x), format: .number)
                        Text("Y").foregroundStyle(.secondary)
                        TextField("", value: frameBinding(\.origin.y), format: .number)
                    }
                }
                GridRow {
                    Text("Width").foregroundStyle(.secondary)
                    TextField("", value: frameBinding(\.size.width), format: .number)
                    Text("Height").foregroundStyle(.secondary)
                    TextField("", value: frameBinding(\.size.height), format: .number)
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding(.vertical, 4)
            positionToggleRow
            Text(placementCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var previewBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preview")
                .font(.subheadline.weight(.semibold))
            RuleFramePreview(rule: rule, connectedDisplays: connectedDisplays)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Toggle between "restore size and position" (default) and "restore size
    /// only". Clearing position retains the saved X/Y in the model so the user
    /// can re-enable later without losing the original coordinates.
    private var positionToggleRow: some View {
        HStack {
            if rule.restoresPosition {
                Spacer()
                Button("Clear position") { rule.restoresPosition = false }
                    .help(
                        "Restore size only. The window keeps its current "
                            + "position whenever this rule is applied.")
            } else {
                Text("Position not saved - the window keeps its current position.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Set position") { rule.restoresPosition = true }
                    .help("Resume restoring the saved X/Y coordinates.")
            }
        }
        .padding(.top, 4)
    }

    private var placementCaption: String {
        rule.restoresPosition
            ? "Coordinates are in points, relative to the saved display's top-left."
            : "Width and height are in points. Position is left as-is at restore time."
    }

    /// Picker options: every connected display plus the rule's saved target
    /// if it isn't connected right now (so the user can still see and keep
    /// the existing selection even while the display is unplugged).
    private var displayOptions: [DisplayFingerprint] {
        var options = connectedDisplays
        if !options.contains(where: { $0.id == rule.targetDisplay.id }) {
            options.append(rule.targetDisplay)
        }
        return options
    }

    private func label(for display: DisplayFingerprint) -> String {
        let name = display.localizedName ?? display.id
        let connected = connectedDisplays.contains(where: { $0.id == display.id })
        return connected ? name : "\(name) · not connected"
    }

    /// Two-way binding to the saved target display. On change, re-derive
    /// `rule.frame.normalised` against the new display's point size so the
    /// proportional-fallback rect still means what the name says.
    private var displayBinding: Binding<String> {
        Binding(
            get: { rule.targetDisplay.id },
            set: { id in
                guard let chosen = displayOptions.first(where: { $0.id == id }) else { return }
                rule.targetDisplay = chosen
                if let normalised = Self.recomputeNormalised(absolute: rule.frame.absolute, on: chosen) {
                    rule.frame.normalised = normalised
                }
            })
    }

    /// Two-way binding to a single component of `rule.frame.absolute`, exposed
    /// as `Double` so SwiftUI's `TextField(value:format:)` can infer
    /// `FloatingPointFormatStyle<Double>.number`. On set, also recomputes
    /// `rule.frame.normalised` against the saved target display so the
    /// proportional-fallback path stays consistent with the edited rect.
    private func frameBinding(_ keyPath: WritableKeyPath<CGRect, CGFloat>) -> Binding<Double> {
        Binding(
            get: { Double(rule.frame.absolute[keyPath: keyPath]) },
            set: { newValue in
                var absolute = rule.frame.absolute
                absolute[keyPath: keyPath] = CGFloat(newValue)
                rule.frame.absolute = absolute
                if let normalised = Self.recomputeNormalised(absolute: absolute, on: rule.targetDisplay) {
                    rule.frame.normalised = normalised
                }
            })
    }

    /// Re-derives the proportional (`normalised`) rect from an absolute frame
    /// against a display's point size. Returns nil when the display reports a
    /// non-positive point size, so callers keep the existing normalised rect
    /// rather than collapsing it to a zero rect at the origin. Pure, so the
    /// derivation is unit-tested directly.
    static func recomputeNormalised(absolute: CGRect, on display: DisplayFingerprint) -> UnitRect? {
        let size = display.pointSize
        guard size.width > 0, size.height > 0 else { return nil }
        return UnitRect(
            x: Double(absolute.origin.x) / Double(size.width),
            y: Double(absolute.origin.y) / Double(size.height),
            width: Double(absolute.size.width) / Double(size.width),
            height: Double(absolute.size.height) / Double(size.height))
    }
}
