import Foundation

/// Where update information for an app comes from.
public enum UpdateSource: Hashable, Sendable {
    /// Installed from the Mac App Store.
    case appStore
    /// Installed with Homebrew; updated with `brew upgrade --cask`.
    case homebrew(cask: String)
    /// The app updates itself through a Sparkle feed.
    case sparkle(feed: URL)
    /// Installed manually, but available as a Homebrew cask (can be adopted).
    case homebrewAvailable(cask: String)
    /// No known source.
    case none

    public var label: String {
        switch self {
        case .appStore: "App Store"
        case .homebrew, .homebrewAvailable: "Homebrew"
        case .sparkle: "Sparkle"
        case .none: "—"
        }
    }
}

/// The outcome of checking one app.
public struct AppStatus: Identifiable, Hashable, Sendable {
    public let app: InstalledApp
    public var source: UpdateSource
    public var available: AppVersion?
    public var decision: UpdateDecision
    public var notes: ReleaseNotes?
    public var releaseDate: Date?
    /// The cask behind a Homebrew source, needed to update or adopt the app.
    public var cask: Cask?

    public var id: URL { app.id }
    public var updateAvailable: Bool { decision.isUpdate }

    public init(app: InstalledApp, source: UpdateSource, available: AppVersion?, decision: UpdateDecision,
                notes: ReleaseNotes? = nil, releaseDate: Date? = nil, cask: Cask? = nil) {
        self.app = app
        self.source = source
        self.available = available
        self.decision = decision
        self.notes = notes
        self.releaseDate = releaseDate
        self.cask = cask
    }
}

/// Settings that influence how sources are chosen.
public struct CheckOptions: Sendable {
    /// Update apps installed with Homebrew through brew (instead of their own updater).
    public var preferHomebrew = true
    /// Ignore Mac App Store apps completely.
    public var hideAppStoreApps = false
    /// Suggest linking App Store apps to Homebrew too.
    public var adoptAppStoreApps = false

    public init(preferHomebrew: Bool = true, hideAppStoreApps: Bool = false, adoptAppStoreApps: Bool = false) {
        self.preferHomebrew = preferHomebrew
        self.hideAppStoreApps = hideAppStoreApps
        self.adoptAppStoreApps = adoptAppStoreApps
    }
}

/// Chooses a source for every app and decides about updates from App Store and Homebrew data.
///
/// Sparkle feeds are checked separately (they need one request per app); this type only assigns the source.
public struct SourceResolver: Sendable {
    public let matcher: CaskMatcher?
    public let appStore: [String: AppStoreListing]
    public let options: CheckOptions

    public init(matcher: CaskMatcher?, appStore: [String: AppStoreListing], options: CheckOptions) {
        self.matcher = matcher
        self.appStore = appStore
        self.options = options
    }

    public func status(for app: InstalledApp) -> AppStatus? {
        // 1. Mac App Store
        if app.hasAppStoreReceipt {
            guard !options.hideAppStoreApps else { return nil }
            guard let listing = appStore[app.bundleIdentifier] else {
                return AppStatus(app: app, source: .appStore, available: nil, decision: .unknown)
            }
            let available = AppVersion(display: listing.version, build: nil)
            return AppStatus(app: app, source: .appStore, available: available,
                             decision: UpdateDecision.compare(installed: app.version, available: available),
                             notes: listing.releaseNotes.map(ReleaseNotes.text), releaseDate: listing.releaseDate)
        }

        // 2. Installed with Homebrew
        if options.preferHomebrew, let matcher, let installed = matcher.installedCask(for: app) {
            let definition = matcher.definition(for: installed)
            let name = definition?.qualifiedName ?? installed.token
            guard let version = definition?.version else {
                return AppStatus(app: app, source: .homebrew(cask: name), available: nil, decision: .unknown, cask: definition)
            }
            let available = AppVersion(caskVersion: version)
            // Like `brew outdated`: nothing to do when brew already installed this version,
            // and an app that updated itself past the cask is up to date.
            let decision: UpdateDecision = installed.versions.contains(version)
                ? .upToDate
                : UpdateDecision.compare(installed: app.version, available: available)
            return AppStatus(app: app, source: .homebrew(cask: name), available: available, decision: decision,
                             notes: definition.flatMap { Self.gitHubNotes(for: $0, installed: app) }, cask: definition)
        }

        // 3. Sparkle (checked later)
        if let feed = app.sparkleFeedURL {
            return AppStatus(app: app, source: .sparkle(feed: feed), available: nil, decision: .unknown)
        }

        // 4. Available on Homebrew
        if let matcher, let cask = matcher.availableCask(for: app) {
            let available = cask.version.map(AppVersion.init(caskVersion:))
            let decision = available.map { UpdateDecision.compare(installed: app.version, available: $0) } ?? .unknown
            return AppStatus(app: app, source: .homebrewAvailable(cask: cask.qualifiedName), available: available, decision: decision,
                             notes: Self.gitHubNotes(for: cask, installed: app), cask: cask)
        }

        // 5. Unsupported
        return AppStatus(app: app, source: .none, available: nil, decision: .unknown)
    }

    /// Release notes from GitHub when the cask is distributed through a GitHub repository.
    static func gitHubNotes(for cask: Cask, installed app: InstalledApp) -> ReleaseNotes? {
        guard let version = cask.version,
              let repository = GitHubRepository(addresses: [cask.downloadURL, cask.homepage].compactMap { $0 }) else { return nil }
        return .gitHub(repository, newVersion: version, installedVersion: app.version.display)
    }
}
