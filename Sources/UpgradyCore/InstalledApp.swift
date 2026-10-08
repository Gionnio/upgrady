import Foundation

/// An application bundle found on disk.
public struct InstalledApp: Identifiable, Hashable, Sendable {
    /// The bundle location, unique per app.
    public let url: URL
    public let bundleIdentifier: String
    public let name: String
    public let version: AppVersion
    /// Whether the app was installed from the Mac App Store.
    public let hasAppStoreReceipt: Bool
    /// The Sparkle feed declared in the app's Info.plist.
    public let sparkleFeedURL: URL?
    public let modificationDate: Date?
    /// An iPhone or iPad app from the App Store, running on the Mac.
    public let isMobileApp: Bool

    public var id: URL { url }

    /// The bundle file name, e.g. `Google Chrome.app`.
    public var fileName: String { url.lastPathComponent }

    public init(url: URL, bundleIdentifier: String, name: String, version: AppVersion,
                hasAppStoreReceipt: Bool = false, sparkleFeedURL: URL? = nil, modificationDate: Date? = nil, isMobileApp: Bool = false) {
        self.url = url
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.version = version
        self.hasAppStoreReceipt = hasAppStoreReceipt
        self.sparkleFeedURL = sparkleFeedURL
        self.modificationDate = modificationDate
        self.isMobileApp = isMobileApp
    }
}

/// Finds applications in folders.
public struct AppScanner: Sendable {

    public static var defaultFolders: [URL] {
        [URL(fileURLWithPath: "/Applications"),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
    }

    public var folders: [URL]
    /// Bundle identifiers that are never listed (e.g. Upgrady itself).
    public var excludedIdentifiers: Set<String>
    /// How deep to look into subfolders (`/Applications/Utilities` is depth 1).
    public var maximumDepth = 3

    public init(folders: [URL] = AppScanner.defaultFolders, excludedIdentifiers: Set<String> = []) {
        self.folders = folders
        self.excludedIdentifiers = excludedIdentifiers
    }

    /// Returns all apps found, sorted by name. Duplicates (same path through different folders) are removed.
    public func scan() -> [InstalledApp] {
        var seen = Set<String>()
        var apps = [InstalledApp]()
        for folder in folders {
            collect(in: folder, depth: 0, into: &apps, seen: &seen)
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func collect(in folder: URL, depth: Int, into apps: inout [InstalledApp], seen: inout Set<String>) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }

        for entry in entries {
            let values = try? entry.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { continue }
            if entry.pathExtension == "app" {
                let path = entry.resolvingSymlinksInPath().path
                guard seen.insert(path).inserted, let app = Self.readApp(at: entry) else { continue }
                if excludedIdentifiers.contains(app.bundleIdentifier) || Self.isSystemApp(app) { continue }
                apps.append(app)
            } else if values?.isDirectory == true, values?.isPackage != true, depth < maximumDepth {
                collect(in: entry, depth: depth + 1, into: &apps, seen: &seen)
            }
        }
    }

    /// Reads the app at `url`. Returns nil for bundles without identifier or version.
    public static func readApp(at url: URL) -> InstalledApp? {
        if let mobile = readMobileApp(at: url) { return mobile }
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty else { return nil }

        let version = AppVersion(display: info["CFBundleShortVersionString"] as? String,
                                 build: info["CFBundleVersion"] as? String)
        guard version.display != nil || version.build != nil else { return nil }

        let name = (info["CFBundleDisplayName"] as? String)?.nilIfEmpty
            ?? (info["CFBundleName"] as? String)?.nilIfEmpty
            ?? url.deletingPathExtension().lastPathComponent
        let receipt = url.appendingPathComponent("Contents/_MASReceipt/receipt")
        // The feed is in the Info.plist, or set by the app at runtime in its preferences.
        let feedString = (info["SUFeedURL"] as? String)
            ?? (CFPreferencesCopyAppValue("SUFeedURL" as CFString, identifier as CFString) as? String)
        let feed = feedString.flatMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0.scheme == nil ? nil : $0 }
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        return InstalledApp(url: url, bundleIdentifier: identifier, name: name, version: version,
                            hasAppStoreReceipt: FileManager.default.fileExists(atPath: receipt.path),
                            sparkleFeedURL: feed, modificationDate: modified)
    }

    /// iPhone and iPad apps from the App Store are wrapped: `Name.app/Wrapper/Name.app` plus `iTunesMetadata.plist`.
    static func readMobileApp(at url: URL) -> InstalledApp? {
        let wrapper = url.appendingPathComponent("Wrapper")
        guard let inner = try? FileManager.default.contentsOfDirectory(at: wrapper, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }),
              let data = try? Data(contentsOf: inner.appendingPathComponent("Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty else { return nil }
        let version = AppVersion(display: info["CFBundleShortVersionString"] as? String, build: info["CFBundleVersion"] as? String)
        guard version.display != nil || version.build != nil else { return nil }
        let name = (info["CFBundleDisplayName"] as? String)?.nilIfEmpty ?? url.deletingPathExtension().lastPathComponent
        let fromStore = FileManager.default.fileExists(atPath: wrapper.appendingPathComponent("iTunesMetadata.plist").path)
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return InstalledApp(url: url, bundleIdentifier: identifier, name: name, version: version,
                            hasAppStoreReceipt: fromStore, modificationDate: modified, isMobileApp: true)
    }

    /// Apple's own apps are updated by macOS, unless they come from the App Store.
    static func isSystemApp(_ app: InstalledApp) -> Bool {
        if app.url.path.hasPrefix("/System/") { return true }
        return app.bundleIdentifier.hasPrefix("com.apple.") && !app.hasAppStoreReceipt
    }
}
