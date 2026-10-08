import AppKit
import SwiftUI

/// About window, like the other apps by Gionnio.
struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "") (\(info?["CFBundleVersion"] as? String ?? ""))"
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 110, height: 110)
                .shadow(radius: 4)

            VStack(spacing: 5) {
                Text(verbatim: "Upgrady").font(.system(size: 26, weight: .bold))
                Text("Version \(version)").font(.callout).foregroundStyle(.secondary)
            }

            Divider().frame(width: 280).padding(.vertical, 4)

            HStack(spacing: 4) {
                Text("Made with")
                Image(systemName: "heart.fill").foregroundStyle(.red)
                Text(verbatim: "by Gionnio").fontWeight(.medium)
            }

            Link(destination: URL(string: "https://github.com/Gionnio/upgrady")!) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                    Text("GitHub Repository").fontWeight(.medium)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }

            Spacer().frame(height: 4)

            VStack(spacing: 3) {
                Text(verbatim: "MIT License").font(.caption).fontWeight(.semibold)
                Text("Uses Sparkle (MIT License)").font(.caption2).foregroundStyle(.secondary)
                Text(verbatim: "Copyright © 2026 Gionnio").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(30)
        .frame(width: 320)
        .background(VisualEffect(material: .hudWindow).ignoresSafeArea())
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
