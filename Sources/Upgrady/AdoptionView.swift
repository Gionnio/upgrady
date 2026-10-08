import SwiftUI
import UpgradyCore

/// Apps installed by hand that Homebrew could manage.
struct AdoptionView: View {
    @EnvironmentObject private var center: UpdateCenter
    @State private var selection = Set<String>()
    @State private var showsLog = false
    @State private var confirmation: Confirmation?

    private enum Confirmation: Identifiable {
        case trust([AdoptionCandidate], reinstall: Bool)
        case reinstall([AdoptionCandidate])
        var id: String {
            switch self {
            case .trust(let list, let reinstall): "trust\(reinstall)" + list.map(\.id).joined()
            case .reinstall(let list): "reinstall" + list.map(\.id).joined()
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Link apps to Homebrew").font(.title3.weight(.semibold))
                Text("These apps were installed by hand but are available on Homebrew. Once linked, Homebrew manages and updates them. If your copy differs from Homebrew's, linking fails: you can reinstall the app from Homebrew instead. Settings and data are kept.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if center.adoptable.isEmpty {
                Text("No apps to link").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(center.adoptable) { candidate in
                    row(candidate)
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
            }

            DisclosureGroup("Homebrew output", isExpanded: $showsLog) {
                ScrollView {
                    Text(center.brewLog.isEmpty ? "—" : center.brewLog)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 110)
            }

            HStack {
                Button("Select All") { selection = Set(center.adoptable.filter(\.likelyToWork).map(\.id)) }
                Button("Don't Suggest") {
                    center.adoptable.filter { selection.contains($0.id) }.forEach(center.dismissAdoption)
                    selection.removeAll()
                }
                .disabled(selection.isEmpty)
                Spacer()
                Button("Reinstall from Homebrew") { confirmation = .reinstall(selected) }
                    .disabled(selection.isEmpty || busy)
                Button("Link to Homebrew") { start(selected, reinstall: false) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection.isEmpty || busy)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 440)
        .alert(item: $confirmation) { confirmation in
            switch confirmation {
            case .reinstall(let list):
                Alert(title: Text("Reinstall from Homebrew?"),
                      message: Text("The installed copies are replaced with the ones from Homebrew. Settings and data are kept."),
                      primaryButton: .destructive(Text("Reinstall")) { start(list, reinstall: true, confirmed: true) },
                      secondaryButton: .cancel())
            case .trust(let list, let reinstall):
                Alert(title: Text("Trust casks from third-party taps?"),
                      message: Text("Homebrew only installs casks from taps you trust. Upgrady trusts just these casks, not the whole taps:\n\(list.filter(\.needsTrust).map(\.cask.qualifiedName).joined(separator: "\n"))"),
                      primaryButton: .default(Text("Trust and Continue")) { run(list, reinstall: reinstall) },
                      secondaryButton: .cancel())
            }
        }
    }

    private var selected: [AdoptionCandidate] { center.adoptable.filter { selection.contains($0.id) } }
    private var busy: Bool { !center.adoptions.isEmpty && center.adoptions.values.contains { if case .failed = $0 { false } else { true } } }

    private func start(_ list: [AdoptionCandidate], reinstall: Bool, confirmed: Bool = false) {
        if list.contains(where: \.needsTrust) {
            confirmation = .trust(list, reinstall: reinstall)
        } else {
            run(list, reinstall: reinstall)
        }
    }

    private func run(_ list: [AdoptionCandidate], reinstall: Bool) {
        showsLog = true
        selection.removeAll()
        Task { await center.adopt(list, reinstall: reinstall) }
    }

    @ViewBuilder
    private func row(_ candidate: AdoptionCandidate) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { selection.contains(candidate.id) },
                                     set: { if $0 { selection.insert(candidate.id) } else { selection.remove(candidate.id) } }))
                .labelsHidden()
            AppIconView(url: candidate.app.url, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.app.name)
                Text("\(candidate.cask.qualifiedName) · installed \(candidate.app.version.description), Homebrew \(candidate.cask.version ?? "?")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            state(candidate)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func state(_ candidate: AdoptionCandidate) -> some View {
        switch center.adoptions[candidate.id] {
        case .queued?: Text("Queued").font(.caption).foregroundStyle(.secondary)
        case .downloading(let fraction)?:
            HStack(spacing: 6) {
                Text(verbatim: "\(Int(fraction * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                ProgressView(value: fraction).progressViewStyle(.circular).controlSize(.small)
            }
        case .preparing?, .installing?: ProgressView().controlSize(.small)
        case .failed(let message)?:
            Label("Failed", systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.caption).help(message)
        case nil:
            HStack(spacing: 4) {
                if candidate.needsTrust { badge("Untrusted tap", .orange) }
                if candidate.cask.tap != nil { badge("Tap", .purple) }
                if candidate.versionMatches { badge("Same version", .green) }
                else if candidate.cask.autoUpdates { badge("Self-updating", .blue) }
                else { badge("Different version", .orange) }
            }
        }
    }

    private func badge(_ text: LocalizedStringKey, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }
}
