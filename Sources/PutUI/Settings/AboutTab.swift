import AppKit
import SwiftUI

struct AboutTab: View {
    let info: AboutInfo

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            HStack(alignment: .top, spacing: 20) {
                AppIconView()
                    .frame(width: 96, height: 96)

                VStack(alignment: .leading, spacing: 4) {
                    Text(info.appName)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("Version \(info.version)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 6)
                    Text(info.tagline)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28)

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                if !info.links.isEmpty {
                    HStack(spacing: 14) {
                        ForEach(info.links) { link in
                            Button {
                                NSWorkspace.shared.open(link.url)
                            } label: {
                                Text(link.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .underline()
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                            .accessibilityLabel("Open \(link.title)")
                        }
                    }
                }
                Text(info.copyright)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.bottom, 22)
        }
    }
}

private struct AppIconView: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSImageView {
        let view = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        view.imageScaling = .scaleProportionallyUpOrDown
        return view
    }

    func updateNSView(_ nsView: NSImageView, context _: Context) {
        nsView.image = NSApp.applicationIconImage ?? NSImage()
    }
}
