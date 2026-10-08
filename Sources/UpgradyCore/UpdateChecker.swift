import Foundation

/// An app installed by hand that Homebrew could manage.
public struct AdoptionCandidate: Identifiable, Hashable, Sendable {
    public let app: InstalledApp
    public let cask: Cask
    /// Installed version equals the cask version: adopting is expected to work.
    public let versionMatches: Bool
    /// The cask comes from a tap Homebrew does not trust yet.
    public let needsTrust: Bool

    public var id: String { cask.qualifiedName }
    /// Adoption should work: same version, or the app updates itself (Homebrew accepts a different copy).
    public var likelyToWork: Bool { versionMatches || cask.autoUpdates }
}

/// The result of a full check.
public struct CheckResult: Sendable {
    public var statuses: [AppStatus]
    public var adoptionCandidates: [AdoptionCandidate]
    public var date: Date
}

/// Runs a full update check.
public struct UpdateChecker: Sendable {
    public var options: CheckOptions
    public var folders: [URL]
    public var excludedIdentifiers: Set<String>
    public var cacheDirectory: URL
    public var homebrew: HomebrewInstallation?
    /// Feeds are fetched in parallel, at most this many at once.
    public var parallelFeeds = 8

    public init(options: CheckOptions, folders: [URL] = AppScanner.defaultFolders, excludedIdentifiers: Set<String>,
                cacheDirectory: URL, homebrew: HomebrewInstallation?) {
        self.options = options
        self.folders = folders
        self.excludedIdentifiers = excludedIdentifiers
        self.cacheDirectory = cacheDirectory
        self.homebrew = homebrew
    }

    public func run() async -> CheckResult {
        let apps = AppScanner(folders: folders, excludedIdentifiers: excludedIdentifiers).scan()

        var matcher: CaskMatcher?
        if let homebrew {
            let catalog = await CaskCatalog.load(cacheURL: cacheDirectory.appendingPathComponent("casks.json"))
            matcher = CaskMatcher(installedCasks: Caskroom.read(homebrew), catalog: catalog, tapCasks: TapCatalog.read(homebrew))
        }

        let storeApps = options.hideAppStoreApps ? [] : apps.filter(\.hasAppStoreReceipt).map(\.bundleIdentifier)
        let listings = await AppStoreCatalog().listings(for: storeApps)
        let resolver = SourceResolver(matcher: matcher, appStore: listings, options: options)
        var statuses = apps.compactMap(resolver.status(for:))

        // Sparkle feeds: one request per app.
        let sparkle = statuses.enumerated().compactMap { index, status -> (Int, URL)? in
            if case .sparkle(let feed) = status.source { return (index, feed) }
            return nil
        }
        let items = await fetchFeeds(sparkle.map(\.1))
        for (position, entry) in sparkle.enumerated() {
            guard let item = items[position] else { continue }
            var status = statuses[entry.0]
            status.available = item.version
            status.decision = item.isInformationalOnly ? .unknown : UpdateDecision.compare(installed: status.app.version, available: item.version)
            status.releaseDate = item.date
            if let html = item.description() {
                status.notes = .html(html)
            } else if let page = item.releaseNotesURL ?? item.fullReleaseNotesURL {
                status.notes = .page(page)
            }
            statuses[entry.0] = status
        }

        let candidates = matcher.map { adoptionCandidates(statuses: statuses, matcher: $0) } ?? []
        return CheckResult(statuses: statuses, adoptionCandidates: candidates, date: Date())
    }

    private func fetchFeeds(_ feeds: [URL]) async -> [AppcastItem?] {
        let client = AppcastClient()
        var results = [AppcastItem?](repeating: nil, count: feeds.count)
        await withTaskGroup(of: (Int, AppcastItem?).self) { group in
            var next = 0
            func addNext() {
                guard next < feeds.count else { return }
                let index = next
                next += 1
                group.addTask { (index, await client.newestItem(feed: feeds[index])) }
            }
            for _ in 0..<min(parallelFeeds, feeds.count) { addNext() }
            while let (index, item) = await group.next() {
                results[index] = item
                addNext()
            }
        }
        return results
    }

    /// Apps in /Applications installed by hand that a cask could manage.
    func adoptionCandidates(statuses: [AppStatus], matcher: CaskMatcher) -> [AdoptionCandidate] {
        let trust = TapTrust.load()
        return statuses.compactMap { status in
            let app = status.app
            if case .homebrew = status.source { return nil }
            // Homebrew can only adopt apps in its own app folder.
            guard app.url.deletingLastPathComponent().path == "/Applications" else { return nil }
            if app.hasAppStoreReceipt && !options.adoptAppStoreApps { return nil }
            guard let cask = matcher.availableCask(for: app),
                  !matcher.installedCasks.contains(where: { $0.token == cask.token }) else { return nil }
            let version = cask.version.map(AppVersion.init(caskVersion:))
            let matches = version.map { UpdateDecision.compare(installed: app.version, available: $0) == .upToDate
                && UpdateDecision.compare(installed: $0, available: app.version) == .upToDate } ?? false
            return AdoptionCandidate(app: app, cask: cask, versionMatches: matches, needsTrust: !trust.trusts(cask))
        }
    }
}

/// Which third-party taps and casks Homebrew trusts (Homebrew 7 ignores the others).
public struct TapTrust: Sendable {
    public let taps: Set<String>
    public let casks: Set<String>
    /// No trust file: older Homebrew without tap trust, everything is allowed.
    public let enforced: Bool

    public static func load() -> TapTrust {
        let environment = ProcessInfo.processInfo.environment
        let url = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0).appendingPathComponent("homebrew/trust.json") }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".homebrew/trust.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return TapTrust(taps: [], casks: [], enforced: false)
        }
        let taps = (json["trustedtaps"] as? [String] ?? []).map { entry -> String in
            // Entries can be `user/name` or a repository address.
            let parts = entry.lowercased().split(separator: "/").suffix(2)
            return parts.joined(separator: "/").replacingOccurrences(of: "homebrew-", with: "")
        }
        return TapTrust(taps: Set(taps), casks: Set((json["trustedcasks"] as? [String] ?? []).map { $0.lowercased() }), enforced: true)
    }

    public func trusts(_ cask: Cask) -> Bool {
        guard enforced, let tap = cask.tap?.lowercased() else { return true }
        return taps.contains(tap) || casks.contains(cask.qualifiedName.lowercased())
    }
}
