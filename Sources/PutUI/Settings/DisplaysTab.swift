import CoreGraphics
import PutCore
import PutDisplay
import SwiftUI

struct DisplaysTab: View {
    /// A preview awaiting the user's confirmation.
    private struct PendingDefaults {
        let pinning: Set<UUID>
        let combinationCount: Int
    }

    @State private var displays: [DisplayFingerprint] = []
    @State private var pending: PendingDefaults?
    @State private var notice: String?
    @State private var isUpdatingDefaults = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Current arrangement")
                    .font(.headline)
                Spacer()
                Button("Set All as Default") {
                    prepareDefaults(for: displays)
                }
                .disabled(isUpdatingDefaults || displays.isEmpty)
                .help("Use every display's current resolution in all combinations of these displays")
                Button("Refresh") {
                    refresh()
                }
            }

            if displays.isEmpty {
                Text("No active displays.")
                    .foregroundStyle(.secondary)
            } else {
                DisplayCanvas(displays: displays)
                    .frame(minHeight: 220)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            displayList
        }
        .padding()
        .onAppear { refresh() }
        // Keep the panel in sync while it's visible. CG reconfig events deliver
        // on the observer's private queue; refresh() runs on the main actor
        // when one arrives.
        .onDisplayConfigurationChange { refresh() }
        .alert(
            "Set as Default?",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending)
        { defaults in
            Button("Set as Default") { applyDefaults(defaults.pinning) }
            Button("Cancel", role: .cancel) {}
        } message: { defaults in
            Text("Sets the default resolution and scaling for \(combinationCount(defaults.combinationCount)).")
        }
        .alert(
            notice ?? "",
            isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } }))
        {
            Button("OK", role: .cancel) {}
        }
    }

    private var displayList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(displays, id: \.id) { display in
                GroupBox {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(display.localizedName ?? "Display")
                                .font(.subheadline.weight(.medium))
                            if display.isPrimary {
                                Text("primary")
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.2))
                                    .clipShape(Capsule())
                            }
                            Spacer()
                            Button("Set as Default") {
                                prepareDefaults(for: [display])
                            }
                            .controlSize(.small)
                            .disabled(isUpdatingDefaults || display.uuid == nil)
                            .help("Use this display's current resolution in all combinations of the connected displays")
                        }
                        Text(summary(for: display))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let uuid = display.uuid {
                            Text("UUID: \(uuid.uuidString)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func summary(for display: DisplayFingerprint) -> String {
        let origin = String(format: "(%.0f, %.0f)", display.globalOrigin.x, display.globalOrigin.y)
        let point = String(format: "%.0f x %.0f pt", display.pointSize.width, display.pointSize.height)
        let pixel = String(format: "%.0f x %.0f px", display.pixelSize.width, display.pixelSize.height)
        return "\(origin) \u{2022} \(point) @\(String(format: "%.2fx", display.scaleFactor)) \u{2022} \(pixel)"
    }

    private func refresh() {
        displays = (try? DisplayProbe.snapshot()) ?? []
    }

    private func combinationCount(_ count: Int) -> String {
        count == 1 ? "1 display combination" : "\(count) display combinations"
    }

    private func prepareDefaults(for targets: [DisplayFingerprint]) {
        let pinning = Set(targets.compactMap(\.uuid))
        let connected = displays
        runDefaultsTask {
            try DisplayDefaultsWriter.preview(displays: connected, pinning: pinning)
        } onSuccess: { count in
            if count == 0 {
                notice = "Already the default resolution and scaling."
            } else {
                pending = PendingDefaults(pinning: pinning, combinationCount: count)
            }
        }
    }

    private func applyDefaults(_ pinning: Set<UUID>) {
        refresh()
        let connected = displays
        runDefaultsTask {
            try DisplayDefaultsWriter.apply(displays: connected, pinning: pinning)
        } onSuccess: { count in
            notice = count == 0
                ? "Already the default resolution and scaling."
                : "Default resolution and scaling set for \(combinationCount(count))."
        }
    }

    /// The writer blocks on subprocesses, so it stays off the main actor.
    private func runDefaultsTask(
        _ work: @escaping @Sendable () throws -> Int,
        onSuccess: @escaping (Int) -> Void)
    {
        isUpdatingDefaults = true
        Task {
            defer { isUpdatingDefaults = false }
            do {
                try await onSuccess(Task.detached(priority: .userInitiated, operation: work).value)
            } catch {
                notice = error.localizedDescription
            }
        }
    }
}

private struct DisplayCanvas: View {
    let displays: [DisplayFingerprint]

    var body: some View {
        GeometryReader { geometry in
            let bounds = combinedBounds()
            let scale = fit(bounds: bounds, into: geometry.size)
            let offsetX = geometry.size.width / 2 - (bounds.midX * scale)
            let offsetY = geometry.size.height / 2 - (bounds.midY * scale)

            ZStack(alignment: .topLeading) {
                ForEach(displays, id: \.id) { display in
                    let rect = CGRect(origin: display.globalOrigin, size: display.pointSize)
                    let scaled = CGRect(
                        x: rect.origin.x * scale + offsetX,
                        y: rect.origin.y * scale + offsetY,
                        width: rect.size.width * scale,
                        height: rect.size.height * scale)
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(display.isPrimary ? Color.accentColor : Color.secondary, lineWidth: 2)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill((display.isPrimary ? Color.accentColor : Color.secondary).opacity(0.15)))
                        .overlay(
                            Text(display.localizedName ?? "Display")
                                .font(.caption)
                                .padding(4))
                        .frame(width: scaled.width, height: scaled.height)
                        .offset(x: scaled.origin.x, y: scaled.origin.y)
                }
            }
        }
    }

    private func combinedBounds() -> CGRect {
        guard let first = displays.first else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        var rect = CGRect(origin: first.globalOrigin, size: first.pointSize)
        for display in displays.dropFirst() {
            rect = rect.union(CGRect(origin: display.globalOrigin, size: display.pointSize))
        }
        return rect.insetBy(dx: -40, dy: -40)
    }

    private func fit(bounds: CGRect, into size: CGSize) -> CGFloat {
        guard bounds.width > 0, bounds.height > 0 else { return 1 }
        let sx = size.width / bounds.width
        let sy = size.height / bounds.height
        return min(sx, sy)
    }
}
