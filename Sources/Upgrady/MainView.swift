import SwiftUI
import UpgradyCore

/// Selection shared with the menu bar panel, so it can open the window on a given app.
@MainActor
final class LibraryState: ObservableObject {
    static let shared = LibraryState()
    @Published var section: LibrarySection = .updates
    @Published var selection: URL?

    func show(_ id: URL) {
        section = .all
        selection = id
    }
}

enum LibrarySection: String, CaseIterable, Identifiable, Hashable {
    case updates, all, ignored
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .updates: "Updates"
        case .all: "All Apps"
        case .ignored: "Ignored"
        }
    }

    var symbol: String {
        switch self {
        case .updates: "arrow.up.circle"
        case .all: "square.grid.2x2"
        case .ignored: "eye.slash"
        }
    }
}

/// The main window: sections on the left, apps in the middle, details on the right.
struct MainView: View {
    @EnvironmentObject private var center: UpdateCenter
    @EnvironmentObject private var preferences: Preferences
    @ObservedObject private var state = LibraryState.shared
    @Environment(\.openWindow) private var openWindow
    @State private var search = ""
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: Binding(get: { state.section }, set: { if let section = $0 { state.section = section } })) {
                Section {
                    ForEach([LibrarySection.updates, .all]) { sidebarRow($0) }
                }
                Section {
                    sidebarRow(.ignored)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } content: {
            appList
                .navigationTitle(state.section.title)
                .navigationSubtitle(subtitle)
                .searchable(text: $search, placement: .toolbar, prompt: Text("Search apps"))
                .toolbar { toolbar }
                .navigationSplitViewColumnWidth(min: 360, ideal: 440)
        } detail: {
            Group {
                if let status = selectedStatus {
                    AppDetail(status: status)
                } else {
                    ContentUnavailableView("No app selected", systemImage: "app.dashed",
                                           description: Text("Select an app to see its release notes."))
                }
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 380)
        }
        .overlay(alignment: .bottom) { StatusBanner() }
        .frame(minWidth: 900, minHeight: 480)
    }

    private func sidebarRow(_ section: LibrarySection) -> some View {
        Label(section.title, systemImage: section.symbol)
            .badge(count(for: section))
            .tag(section)
    }

    // MARK: List

    @ViewBuilder
    private var appList: some View {
        let apps = visible
        if apps.isEmpty {
            if !search.isEmpty {
                ContentUnavailableView.search(text: search)
            } else if state.section == .updates {
                ContentUnavailableView("Everything is up to date", systemImage: "checkmark.seal",
                                       description: Text(center.lastCheck == nil ? "Checking your apps…" : "Upgrady checks again automatically."))
            } else {
                ContentUnavailableView("No apps here", systemImage: "tray")
            }
        } else {
            List(apps, selection: $state.selection) { status in
                AppRow(status: status)
                    .tag(status.id)
                    .contextMenu { contextMenu(for: status) }
            }
            .listStyle(.inset)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Picker("Sort By", selection: $preferences.sortOrder) {
                    ForEach(Preferences.SortOrder.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort By", systemImage: "arrow.up.arrow.down")
            }
            .help("Sort By")
            Button { Task { await center.check() } } label: { Label("Check for Updates", systemImage: "arrow.clockwise") }
                .disabled(center.isChecking)
                .help("Check for updates")
            if !center.adoptable.isEmpty {
                Button { openWindow(id: "adoption") } label: { Label("Link to Homebrew", systemImage: "shippingbox") }
                    .help("Link apps installed by hand to Homebrew")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Update All") { center.updateAll() }
                .prominentGlassButton()
                .disabled(!center.updates.contains(where: center.canUpdateInApp))
        }
    }

    private var subtitle: String {
        if center.isChecking { return String(localized: "Checking…") }
        guard let lastCheck = center.lastCheck else { return "" }
        return String(localized: "Checked \(lastCheck.formatted(.relative(presentation: .named)))")
    }

    @ViewBuilder
    private func contextMenu(for status: AppStatus) -> some View {
        if status.updateAvailable { Button("Update") { center.update(status) } }
        Button("Open") { NSWorkspace.shared.open(status.app.url) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([status.app.url]) }
        Divider()
        if status.updateAvailable && !center.isSkipped(status) {
            Button("Skip This Version") { center.skipVersion(status) }
        }
        Button(center.isIgnored(status) ? "Stop Ignoring" : "Ignore") { center.setIgnored(!center.isIgnored(status), status) }
    }

    // MARK: Data

    private var selectedStatus: AppStatus? {
        state.selection.flatMap { id in center.statuses.first { $0.id == id } }
    }

    private func apps(in section: LibrarySection) -> [AppStatus] {
        let all = center.statuses
        switch section {
        case .updates: return center.updates
        case .all: return all.filter { !center.isIgnored($0) && (preferences.showUnsupportedApps || $0.source != .none) }
        case .ignored: return all.filter(center.isIgnored)
        }
    }

    private func count(for section: LibrarySection) -> Int {
        section == .updates || section == .ignored ? apps(in: section).count : 0
    }

    private var visible: [AppStatus] {
        var apps = apps(in: state.section)
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty { apps = apps.filter { $0.app.name.localizedCaseInsensitiveContains(query) } }
        switch preferences.sortOrder {
        case .name:
            return apps.sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
        case .date:
            return apps.sorted { ($0.sortDate ?? .distantPast) > ($1.sortDate ?? .distantPast) }
        }
    }
}

extension AppStatus {
    /// The date shown and sorted by: the release of the available update, otherwise when the app last changed on disk.
    var sortDate: Date? {
        // Some installers leave a placeholder date (1979-1980) on the files: not worth showing.
        let changed = app.modificationDate.flatMap { $0 > Date(timeIntervalSince1970: 946_684_800) ? $0 : nil }
        return updateAvailable ? (releaseDate ?? changed) : changed
    }

    /// "today", "yesterday", "3 days ago", or a short date.
    var dateText: String? {
        guard let date = sortDate else { return nil }
        if Date().timeIntervalSince(date) < 7 * 86_400 {
            return date.formatted(.relative(presentation: .named))
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

/// One app in the list.
private struct AppRow: View {
    @EnvironmentObject private var center: UpdateCenter
    let status: AppStatus

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(url: status.app.url, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.app.name).lineLimit(1)
                HStack(spacing: 4) {
                    VersionLine(status: status)
                    if let date = status.dateText {
                        Text(verbatim: "·")
                        Text(verbatim: date)
                    }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if center.isSkipped(status) {
                Text("Skipped").font(.caption).foregroundStyle(.secondary)
            }
            SourceBadge(source: status.source)
            Group {
                if status.updateAvailable && !center.isIgnored(status) && !center.isSkipped(status) {
                    UpdateCapsule(status: status)
                } else if status.decision == .upToDate {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            .frame(width: 96, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }
}

/// Details and release notes of an app.
struct AppDetail: View {
    @EnvironmentObject private var center: UpdateCenter
    let status: AppStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    AppIconView(url: status.app.url, size: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(status.app.name).font(.title3.weight(.semibold)).lineLimit(2)
                        VersionLine(status: status).font(.callout).foregroundStyle(.secondary)
                    }
                }
                SupportRow(status: status)
                if let date = status.releaseDate {
                    Text("Released \(date, format: .dateTime.day().month().year())").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    if status.updateAvailable && !center.isIgnored(status) { UpdateCapsule(status: status, prominent: true) }
                    Button("Open") { NSWorkspace.shared.open(status.app.url) }
                    Menu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([status.app.url]) }
                        if status.updateAvailable && !center.isSkipped(status) {
                            Button("Skip This Version") { center.skipVersion(status) }
                        }
                        Button(center.isIgnored(status) ? "Stop Ignoring" : "Ignore") { center.setIgnored(!center.isIgnored(status), status) }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .controlSize(.small)
            }
            .padding(16)
            Divider()
            NotesView(status: status)
        }
    }
}

/// Progress feedback floating at the bottom of the window, like a toast.
private struct StatusBanner: View {
    @EnvironmentObject private var center: UpdateCenter

    var body: some View {
        Group {
            if center.isChecking {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Checking for updates…")
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .floatingCapsule()
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if center.needsAppManagementPermission {
                HStack(spacing: 10) {
                    Image(systemName: "lock.shield").foregroundStyle(.orange)
                    Text("Allow Upgrady in Privacy & Security → App Management to update apps.")
                    Button("Open Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")!)
                    }
                    Button { center.needsAppManagementPermission = false } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .floatingCapsule()
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: center.isChecking)
        .animation(.spring(duration: 0.3), value: center.needsAppManagementPermission)
        .padding(.bottom, 16)
    }
}

/// What Upgrady can do for an app, explained in the details.
private struct SupportRow: View {
    let status: AppStatus

    var body: some View {
        let level = status.source.supportLevel
        HStack(alignment: explanation == nil ? .center : .top, spacing: 8) {
            Image(systemName: level.symbol).foregroundStyle(level.color).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(level.title).font(.callout.weight(.medium))
                    SourceBadge(source: status.source)
                }
                if let explanation { Text(explanation).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(level.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    /// A short note only where the title alone is not enough.
    private var explanation: LocalizedStringKey? {
        switch status.source {
        case .homebrewAvailable: "Upgrady lets you know when a new version is out."
        default: nil
        }
    }
}
