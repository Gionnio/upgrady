import SwiftUI
import ServiceManagement
import UpgradyCore

/// User settings. Every optional feature can be turned off here.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    // General
    @AppStorage("showMenuBarIcon") var showMenuBarIcon = true {
        // SwiftUI writes this back while updating the menu bar; only real changes may publish.
        willSet { if newValue != showMenuBarIcon { objectWillChange.send() } }
        didSet { if oldValue != showMenuBarIcon { Background.updateActivationPolicy() } }
    }
    @AppStorage("showDockIconWithWindow") var showDockIconWithWindow = true { willSet { objectWillChange.send() } }
    @AppStorage("sortOrder") var sortOrder = SortOrder.name { willSet { objectWillChange.send() } }
    @AppStorage("checkInterval") var checkInterval = CheckInterval.sixHours { willSet { objectWillChange.send() } }
    @AppStorage("notifyAboutUpdates") var notifyAboutUpdates = true { willSet { objectWillChange.send() } }
    @AppStorage("quitBehavior") var quitBehavior = QuitBehavior.ask { willSet { objectWillChange.send() } }
    @AppStorage("theme") var theme = Theme.system {
        willSet { objectWillChange.send() }
        didSet { applyTheme() }
    }

    // Apps
    @AppStorage("extraFolders") private var extraFoldersData = Data() { willSet { objectWillChange.send() } }
    @AppStorage("hideAppStoreApps") var hideAppStoreApps = false { willSet { objectWillChange.send() } }
    @AppStorage("showUnsupportedApps") var showUnsupportedApps = false { willSet { objectWillChange.send() } }
    @AppStorage("ignoredApps") private var ignoredAppsData = Data() { willSet { objectWillChange.send() } }
    @AppStorage("skippedVersions") private var skippedVersionsData = Data() { willSet { objectWillChange.send() } }

    // Homebrew
    @AppStorage("homebrewEnabled") var homebrewEnabled = true { willSet { objectWillChange.send() } }
    @AppStorage("updateWithBrew") var updateWithBrew = true { willSet { objectWillChange.send() } }
    @AppStorage("suggestAdoption") var suggestAdoption = true { willSet { objectWillChange.send() } }
    @AppStorage("adoptAppStoreApps") var adoptAppStoreApps = false { willSet { objectWillChange.send() } }
    @AppStorage("dismissedAdoptions") private var dismissedAdoptionsData = Data() { willSet { objectWillChange.send() } }
    @AppStorage("brewPath") var brewPath = "" { willSet { objectWillChange.send() } }

    enum CheckInterval: Int, CaseIterable, Identifiable {
        case never = 0, hourly = 3600, threeHours = 10800, sixHours = 21600, twelveHours = 43200, daily = 86400
        var id: Int { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .never: "Never"
            case .hourly: "Every hour"
            case .threeHours: "Every 3 hours"
            case .sixHours: "Every 6 hours"
            case .twelveHours: "Every 12 hours"
            case .daily: "Once a day"
            }
        }
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case name, date
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .name: "Name"
            case .date: "Date"
            }
        }
    }

    enum QuitBehavior: String, CaseIterable, Identifiable {
        case ask, keepInMenuBar, quit
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .ask: "Ask"
            case .keepInMenuBar: "Keep in the menu bar"
            case .quit: "Quit"
            }
        }
    }

    enum Theme: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
        var appearance: NSAppearance? {
            switch self {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }

    // MARK: Collections

    var extraFolders: [URL] {
        get { decode([String].self, from: extraFoldersData)?.map { URL(fileURLWithPath: $0) } ?? [] }
        set { extraFoldersData = encode(newValue.map(\.path)) }
    }

    var ignoredApps: Set<String> {
        get { decode(Set<String>.self, from: ignoredAppsData) ?? [] }
        set { ignoredAppsData = encode(newValue) }
    }

    /// Versions the user chose to skip, by bundle identifier.
    var skippedVersions: [String: String] {
        get { decode([String: String].self, from: skippedVersionsData) ?? [:] }
        set { skippedVersionsData = encode(newValue) }
    }

    var dismissedAdoptions: Set<String> {
        get { decode(Set<String>.self, from: dismissedAdoptionsData) ?? [] }
        set { dismissedAdoptionsData = encode(newValue) }
    }

    var checkOptions: CheckOptions {
        CheckOptions(preferHomebrew: homebrewEnabled && updateWithBrew, hideAppStoreApps: hideAppStoreApps,
                     adoptAppStoreApps: adoptAppStoreApps)
    }

    var homebrew: HomebrewInstallation? {
        homebrewEnabled ? HomebrewInstallation.locate(customPath: brewPath) : nil
    }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        }
    }

    var launchAtLoginNeedsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    // MARK: Language

    /// The interface language chosen in Settings; empty to follow the system.
    var language: String {
        get {
            let own = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
            return (own["AppleLanguages"] as? [String])?.first ?? ""
        }
        set {
            objectWillChange.send()
            if newValue.isEmpty {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([newValue], forKey: "AppleLanguages")
            }
        }
    }

    func applyTheme() {
        NSApp.appearance = theme.appearance
    }

    // MARK: Helpers

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        data.isEmpty ? nil : try? JSONDecoder().decode(type, from: data)
    }

    private func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }
}
