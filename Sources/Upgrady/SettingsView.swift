import ServiceManagement
import SwiftUI
import UpgradyCore

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AppsSettings().tabItem { Label("Apps", systemImage: "square.grid.2x2") }
            HomebrewSettings().tabItem { Label("Homebrew", systemImage: "shippingbox") }
        }
        .frame(width: 540)
    }
}

/// Short explanation under an option.
private struct Hint: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject private var preferences: Preferences
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var askRelaunch = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Language", selection: Binding(get: { preferences.language },
                                                          set: { preferences.language = $0; askRelaunch = true })) {
                        Text("System").tag("")
                        Text(verbatim: "Italiano").tag("it")
                        Text(verbatim: "English").tag("en")
                    }
                    Hint("Upgrady restarts to change language.")
                }
                Picker("Theme", selection: $preferences.theme) {
                    ForEach(Preferences.Theme.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Picker("Check for updates", selection: $preferences.checkInterval) {
                    ForEach(Preferences.CheckInterval.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Notify me about new updates", isOn: $preferences.notifyAboutUpdates)
            }

            Section("In the background") {
                Toggle("Open Upgrady at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { preferences.launchAtLogin = $0; launchAtLogin = SMAppService.mainApp.status == .enabled }))
                if preferences.launchAtLoginNeedsApproval {
                    HStack {
                        Text("To be approved in System Settings").font(.caption).foregroundStyle(.orange)
                        Button("Open…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show the icon in the menu bar", isOn: $preferences.showMenuBarIcon)
                    Hint("Without it, Upgrady behaves like a normal app: it quits when you quit it, and checks only while it is open.")
                }
                Picker("With ⌘Q", selection: $preferences.quitBehavior) {
                    ForEach(Preferences.QuitBehavior.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!preferences.showMenuBarIcon)
                Toggle("Show the Dock icon while a window is open", isOn: $preferences.showDockIconWithWindow)
                    .disabled(!preferences.showMenuBarIcon)
                Hint("Upgrady stays in the menu bar and keeps checking for updates even with its window closed. At login it starts without opening the window. To quit it completely, use Quit in the menu bar panel.")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .alert("Relaunch Upgrady to change the language?", isPresented: $askRelaunch) {
            Button("Relaunch Now") { Background.relaunch() }
            Button("Later", role: .cancel) {}
        }
    }
}

private struct AppsSettings: View {
    @EnvironmentObject private var preferences: Preferences
    @EnvironmentObject private var center: UpdateCenter

    var body: some View {
        Form {
            Section("Folders") {
                LabeledContent("Applications") { Text("Always included").foregroundStyle(.secondary) }
                ForEach(preferences.extraFolders, id: \.self) { folder in
                    LabeledContent {
                        Button(role: .destructive) { preferences.extraFolders.removeAll { $0 == folder } } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    } label: {
                        Label(folder.lastPathComponent, systemImage: "folder").help(folder.path)
                    }
                }
                Button("Add Folder…") { addFolder() }
            }

            Section("Mac App Store") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Hide Mac App Store apps", isOn: $preferences.hideAppStoreApps)
                    Hint("Hidden apps are neither listed nor checked. Update opens the App Store, which installs App Store updates.")
                }
            }

            Section("List") {
                Toggle("Show apps without update information", isOn: $preferences.showUnsupportedApps)
                LabeledContent("Ignored apps") { Text(verbatim: "\(preferences.ignoredApps.count)") }
                LabeledContent("Skipped versions") { Text(verbatim: "\(preferences.skippedVersions.count)") }
                Button("Reset Ignored and Skipped") {
                    preferences.ignoredApps = []
                    preferences.skippedVersions = [:]
                }
                .disabled(preferences.ignoredApps.isEmpty && preferences.skippedVersions.isEmpty)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: preferences.hideAppStoreApps) { Task { await center.check(refreshingHomebrew: false) } }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !preferences.extraFolders.contains(url) { preferences.extraFolders.append(url) }
        Task { await center.check(refreshingHomebrew: false) }
    }
}

private struct HomebrewSettings: View {
    @EnvironmentObject private var preferences: Preferences
    @EnvironmentObject private var center: UpdateCenter
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                Toggle("Use Homebrew", isOn: $preferences.homebrewEnabled)
                LabeledContent("Status") {
                    if let brew = HomebrewInstallation.locate(customPath: preferences.brewPath) {
                        Label(brew.brewURL.path, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label("Not found", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                TextField("brew path", text: $preferences.brewPath, prompt: Text("Automatic"))
            }

            Section("Updates") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Update apps installed with Homebrew using brew", isOn: $preferences.updateWithBrew)
                    Hint("Every check starts with brew update, so Homebrew knows the latest versions.")
                }
            }
            .disabled(!preferences.homebrewEnabled)

            Section("Apps installed by hand") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Suggest linking them to Homebrew", isOn: $preferences.suggestAdoption)
                    Hint("Once linked, Homebrew manages and updates them.")
                }
                Toggle("Include Mac App Store apps", isOn: $preferences.adoptAppStoreApps)
                    .disabled(!preferences.suggestAdoption || preferences.hideAppStoreApps)
                HStack {
                    Button("Show Apps to Link…") { openWindow(id: "adoption") }
                    Button("Suggest Dismissed Apps Again") { preferences.dismissedAdoptions = [] }
                        .disabled(preferences.dismissedAdoptions.isEmpty)
                }
            }
            .disabled(!preferences.homebrewEnabled)

            Section("Permission") {
                VStack(alignment: .leading, spacing: 4) {
                    Button("Open App Management Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")!)
                    }
                    Hint("To replace apps in the Applications folder, Upgrady needs the App Management permission in Privacy & Security.")
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: preferences.homebrewEnabled) { Task { await center.check(refreshingHomebrew: false) } }
        .onChange(of: preferences.updateWithBrew) { Task { await center.check(refreshingHomebrew: false) } }
    }
}
