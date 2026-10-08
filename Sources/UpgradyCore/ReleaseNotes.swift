import Foundation

/// Where the release notes of an update can be read.
public enum ReleaseNotes: Hashable, Sendable {
    /// HTML included in the feed.
    case html(String)
    /// Plain text (App Store).
    case text(String)
    /// A web page with the notes.
    case page(URL)
    /// The releases of a GitHub repository, loaded on demand.
    case gitHub(GitHubRepository, newVersion: String, installedVersion: String?)
}

/// A GitHub repository, recognized from a download URL or a homepage.
public struct GitHubRepository: Hashable, Sendable {
    public let owner: String
    public let name: String

    public init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }

    /// Finds `github.com/owner/name` or `owner.github.io/name` in the given addresses.
    public init?(addresses: [String]) {
        for address in addresses {
            guard let url = URL(string: address), let host = url.host?.lowercased() else { continue }
            let path = url.pathComponents.filter { $0 != "/" }
            if host == "github.com" || host == "www.github.com", path.count >= 2 {
                let owner = path[0]
                guard !["orgs", "users", "sponsors", "apps", "features", "marketplace"].contains(owner.lowercased()) else { continue }
                var name = path[1]
                if name.hasSuffix(".git") { name.removeLast(4) }
                self.init(owner: owner, name: name)
                return
            }
            if host.hasSuffix(".github.io"), let first = path.first {
                self.init(owner: String(host.dropLast(".github.io".count)), name: first)
                return
            }
        }
        return nil
    }

    public var releasesPage: URL { URL(string: "https://github.com/\(owner)/\(name)/releases")! }
}

/// A published GitHub release.
public struct GitHubRelease: Hashable, Sendable, Decodable {
    public let tag: String
    public let title: String?
    public let html: String?
    public let page: URL
    public let isDraft: Bool
    public let isPreRelease: Bool
    public let published: Date?

    enum CodingKeys: String, CodingKey {
        case tag = "tag_name", title = "name", html = "body_html", page = "html_url"
        case isDraft = "draft", isPreRelease = "prerelease", published = "published_at"
    }

    public var version: VersionNumber? { VersionNumber(tag) }
}

/// Loads release notes from GitHub's public API (no account; about 60 requests per hour).
public struct GitHubReleases: Sendable {
    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public enum LoadError: Error, Equatable {
        case rateLimited
        case unavailable
    }

    /// Recent releases, newest first, with notes rendered to HTML by GitHub.
    ///
    /// Answers are kept for an hour and revalidated with their ETag (GitHub does not count those requests),
    /// and while GitHub is limiting requests nothing is sent until the limit resets.
    public func releases(of repository: GitHubRepository) async throws -> [GitHubRelease] {
        let key = "\(repository.owner)/\(repository.name)".lowercased()
        let cached = await GitHubCache.shared.entry(for: key)
        if let cached, Date().timeIntervalSince(cached.fetched) < 3600 { return cached.releases }
        if let reset = await GitHubCache.shared.limitedUntil, reset > Date() {
            if let cached { return cached.releases }
            throw LoadError.rateLimited
        }

        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository.owner)/\(repository.name)/releases?per_page=30")!,
                                 timeoutInterval: 20)
        request.setValue("application/vnd.github.html+json", forHTTPHeaderField: "Accept")
        request.setValue("Upgrady", forHTTPHeaderField: "User-Agent")
        if let etag = cached?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        switch http?.statusCode ?? 0 {
        case 200: break
        case 304 where cached != nil:
            await GitHubCache.shared.store(cached!.releases, etag: cached!.etag, for: key)
            return cached!.releases
        case 403, 429:
            let reset = (http?.value(forHTTPHeaderField: "x-ratelimit-reset")).flatMap(TimeInterval.init)
                .map(Date.init(timeIntervalSince1970:)) ?? Date().addingTimeInterval(600)
            await GitHubCache.shared.limit(until: reset)
            if let cached { return cached.releases }
            throw LoadError.rateLimited
        default:
            if let cached { return cached.releases }
            throw LoadError.unavailable
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let releases = try decoder.decode([GitHubRelease].self, from: data).filter { !$0.isDraft }
        await GitHubCache.shared.store(releases, etag: http?.value(forHTTPHeaderField: "ETag"), for: key)
        return releases
    }

    /// The releases a user skips when updating from `installed` to `newest`: newer than the installed version,
    /// up to the new one. Falls back to the newest final release when versions cannot be matched.
    public static func relevant(_ releases: [GitHubRelease], newest: String, installed: String?) -> [GitHubRelease] {
        let target = VersionNumber(newest.split(separator: ",").first.map(String.init) ?? newest)
        let current = installed.flatMap(VersionNumber.init)
        let matching = releases.filter { release in
            guard let version = release.version else { return false }
            if let target, target < version { return false }
            if let current, !(current < version) { return false }
            return true
        }
        if !matching.isEmpty { return Array(matching.prefix(10)) }
        return releases.first { !$0.isPreRelease }.map { [$0] } ?? []
    }
}

/// Releases already downloaded in this session, so selecting an app again costs no request.
actor GitHubCache {
    static let shared = GitHubCache()

    struct Entry {
        let releases: [GitHubRelease]
        let etag: String?
        let fetched: Date
    }

    private var entries: [String: Entry] = [:]
    private(set) var limitedUntil: Date?

    func entry(for key: String) -> Entry? { entries[key] }

    func store(_ releases: [GitHubRelease], etag: String?, for key: String) {
        entries[key] = Entry(releases: releases, etag: etag, fetched: Date())
    }

    func limit(until date: Date) { limitedUntil = date }
}
