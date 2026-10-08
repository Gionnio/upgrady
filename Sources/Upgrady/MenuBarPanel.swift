import SwiftUI
import UpgradyCore

/// The panel shown from the menu bar icon.
struct MenuBarPanel: View {
    @EnvironmentObject private var center: UpdateCenter
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if center.updates.isEmpty {
                upToDate
            } else {
                // The panel sizes itself to its content and a scroll view has no height of its own:
                // short lists are shown as they are, long ones scroll in a fixed height.
                if center.updates.count <= Self.visibleRows {
                    updateList
                } else {
                    ScrollView { updateList }
                        .frame(height: CGFloat(Self.visibleRows) * 45)
                }
            }
            if !center.adoptable.isEmpty {
                Divider()
                Button { openWindow(id: "adoption"); Background.bringToFront() } label: {
                    HStack {
                        Image(systemName: "shippingbox")
                        Text("\(center.adoptable.count) apps can be linked to Homebrew")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption)
                    }
                    .font(.callout)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Divider()
            footer
        }
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .background(PanelSizer())
    }

    private static let visibleRows = 7

    private var updateList: some View {
        VStack(spacing: 0) {
            ForEach(center.updates) { status in
                UpdateRow(status: status)
                if status.id != center.updates.last?.id { Divider().padding(.leading, 54) }
            }
        }
        .padding(.vertical, 4)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(center.updates.isEmpty ? "No updates" : "\(center.updates.count) updates")
                    .font(.headline)
                Group {
                    if center.isChecking {
                        Text("Checking…")
                    } else if let lastCheck = center.lastCheck {
                        Text("Checked \(lastCheck, format: .relative(presentation: .named))")
                    } else {
                        Text("Not checked yet")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            // With a single update its own button in the list is enough.
            if center.updates.filter(center.canUpdateInApp).count > 1 {
                Button("Update All") { center.updateAll() }
                    .prominentGlassButton()
                    .controlSize(.small)
            }
        }
        .padding(14)
    }

    private var upToDate: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 28)).foregroundStyle(.green)
            Text("Everything is up to date").font(.callout)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button { Task { await center.check() } } label: { Label("Check Now", systemImage: "arrow.clockwise") }
                .disabled(center.isChecking)
            Button { openWindow(id: "main"); Background.bringToFront() } label: { Label("Open Upgrady", systemImage: "macwindow") }
            Spacer()
            SettingsLink { Image(systemName: "gearshape") }
                .simultaneousGesture(TapGesture().onEnded { Background.bringToFront() })
                .help("Settings…")
            Button { Background.quitCompletely() } label: { Image(systemName: "power") }
                .help("Quit Upgrady")
        }
        .buttonStyle(.plain)
        .labelStyle(.titleAndIcon)
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

/// One app with an update, in the panel.
private struct UpdateRow: View {
    @EnvironmentObject private var center: UpdateCenter
    let status: AppStatus

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(url: status.app.url, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.app.name).lineLimit(1)
                HStack(spacing: 6) {
                    VersionLine(status: status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    SourceBadge(source: status.source)
                }
            }
            Spacer(minLength: 8)
            UpdateCapsule(status: status)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            LibraryState.shared.show(status.id)
            Background.showMainWindow()
        }
    }
}

/// Keeps the panel window as tall as its content. The menu bar window grows with the content but does not
/// shrink when it gets shorter (for example when the list replaces "Everything is up to date" while it is open),
/// leaving empty bands above and below.
private struct PanelSizer: NSViewRepresentable {
    func makeNSView(context: Context) -> SizerView { SizerView() }
    func updateNSView(_ view: SizerView, context: Context) {}

    final class SizerView: NSView {
        override func layout() {
            super.layout()
            DispatchQueue.main.async { [weak self] in self?.fitWindow() }
        }

        private func fitWindow() {
            guard let window, let content = window.contentView else { return }
            let height = bounds.height
            guard height > 0, abs(content.frame.height - height) > 0.5 else { return }
            var frame = window.frame
            let extra = frame.height - content.frame.height
            frame.origin.y += frame.height - (height + extra)
            frame.size.height = height + extra
            window.setFrame(frame, display: true)
        }
    }
}
