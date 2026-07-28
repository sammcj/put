import CoreGraphics
import PutCore
import PutDisplay
import SwiftUI

struct DisplaysTab: View {
    @State private var displays: [DisplayFingerprint] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Current arrangement")
                    .font(.headline)
                Spacer()
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
