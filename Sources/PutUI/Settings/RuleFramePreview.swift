import CoreGraphics
import PutCore
import PutDisplay
import SwiftUI

/// Read-only visual of a rule's saved window placement. Draws every currently
/// connected display plus a ghost of the rule's saved target if it's not
/// connected, then overlays the saved window rect on its target. Uses
/// `Canvas` rather than a `ZStack` of offset shapes because `GeometryReader`
/// + offsets inside the grouped-style form containers produces unpredictable
/// bounds; `Canvas` clips cleanly to its own frame and gives exact control
/// over fit-and-centre math.
struct RuleFramePreview: View {
    let rule: Rule
    let connectedDisplays: [DisplayFingerprint]

    var body: some View {
        Canvas(opaque: false) { context, size in
            let scene = composeScene()
            let bounds = combinedBounds(scene.displays.map(\.rect))
            let scale = fit(bounds: bounds, into: size)
            let offsetX = size.width / 2 - bounds.midX * scale
            let offsetY = size.height / 2 - bounds.midY * scale
            let transform: (CGRect) -> CGRect = { rect in
                CGRect(
                    x: rect.origin.x * scale + offsetX,
                    y: rect.origin.y * scale + offsetY,
                    width: rect.size.width * scale,
                    height: rect.size.height * scale)
            }

            for display in scene.displays {
                draw(display: display, in: transform(display.rect), context: context)
            }
            if let windowRect = scene.windowGlobalRect {
                drawWindow(
                    rect: transform(windowRect),
                    targetConnected: scene.targetConnected,
                    context: context)
            }
        }
    }

    // MARK: - Scene composition

    private struct DisplayEntry {
        let id: String
        let rect: CGRect
        let label: String
        let isTarget: Bool
        let isConnected: Bool
    }

    private struct Scene {
        let displays: [DisplayEntry]
        /// nil unless the rule restores a saved position, which is the only
        /// component that makes a drawn rect true. For the others the
        /// highlighted target display is the whole of what the rule says.
        let windowGlobalRect: CGRect?
        let targetConnected: Bool
    }

    private func composeScene() -> Scene {
        let target = rule.targetDisplay
        let match = DisplayMatcher.resolve(target: target, among: connectedDisplays)
        let targetConnected: Bool = {
            guard let match else { return false }
            return match.quality <= .equivalent
        }()
        let resolvedTarget = match?.display ?? target

        var entries: [DisplayEntry] = connectedDisplays.map { display in
            DisplayEntry(
                id: display.id,
                rect: CGRect(origin: display.globalOrigin, size: display.pointSize),
                label: display.localizedName ?? "Display",
                isTarget: display.id == resolvedTarget.id,
                isConnected: true)
        }
        if !targetConnected, !entries.contains(where: { $0.id == target.id }) {
            entries.append(DisplayEntry(
                id: target.id,
                rect: CGRect(origin: target.globalOrigin, size: target.pointSize),
                label: (target.localizedName ?? "Saved display") + " (not connected)",
                isTarget: true,
                isConnected: false))
        }

        // Only a restored position puts the window somewhere knowable. Drawing
        // the saved rect for a rule that doesn't restore it would promise a
        // placement that never happens - a size-only rule leaves the window
        // where it stands, and a display rule derives its origin from there.
        let globalWindow: CGRect? = !rule.restoreComponents.position ? nil : CGRect(
            x: resolvedTarget.globalOrigin.x + rule.frame.absolute.origin.x,
            y: resolvedTarget.globalOrigin.y + rule.frame.absolute.origin.y,
            width: rule.frame.absolute.size.width,
            height: rule.frame.absolute.size.height)

        return Scene(
            displays: entries,
            windowGlobalRect: globalWindow,
            targetConnected: targetConnected)
    }

    // MARK: - Drawing

    private func draw(display: DisplayEntry, in rect: CGRect, context: GraphicsContext) {
        let stroke: Color = display.isTarget ? .accentColor : .secondary
        let path = Path(roundedRect: rect, cornerRadius: 6)
        context.fill(path, with: .color(stroke.opacity(display.isConnected ? 0.1 : 0.04)))
        let style = StrokeStyle(
            lineWidth: display.isTarget ? 2 : 1.5,
            dash: display.isConnected ? [] : [6, 4])
        context.stroke(path, with: .color(stroke), style: style)

        let resolved = context.resolve(
            Text(display.label)
                .font(.caption)
                .foregroundColor(.secondary))
        let textSize = resolved.measure(in: CGSize(width: max(rect.width - 12, 20), height: 20))
        let textOrigin = CGPoint(x: rect.origin.x + 6, y: rect.origin.y + 4)
        let textRect = CGRect(origin: textOrigin, size: textSize)
        if textRect.width <= rect.width - 8 {
            context.draw(resolved, in: textRect)
        }
    }

    private func drawWindow(rect: CGRect, targetConnected: Bool, context: GraphicsContext) {
        guard rect.width > 0, rect.height > 0 else { return }
        let drawRect = CGRect(
            x: rect.origin.x,
            y: rect.origin.y,
            width: max(rect.width, 2),
            height: max(rect.height, 2))
        let path = Path(roundedRect: drawRect, cornerRadius: 4)
        context.fill(path, with: .color(Color.accentColor.opacity(targetConnected ? 0.35 : 0.2)))
        context.stroke(path, with: .color(.accentColor), lineWidth: 1.5)
    }

    // MARK: - Geometry

    private func combinedBounds(_ rects: [CGRect]) -> CGRect {
        guard let first = rects.first else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        var bounds = first
        for rect in rects.dropFirst() {
            bounds = bounds.union(rect)
        }
        return bounds.insetBy(dx: -40, dy: -40)
    }

    private func fit(bounds: CGRect, into size: CGSize) -> CGFloat {
        guard bounds.width > 0, bounds.height > 0 else { return 1 }
        return min(size.width / bounds.width, size.height / bounds.height)
    }
}
