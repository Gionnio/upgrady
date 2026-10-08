import Foundation

/// One release in a Sparkle feed.
public struct AppcastItem: Hashable, Sendable {
    public var title: String?
    /// The display version (`sparkle:shortVersionString`).
    public var shortVersion: String?
    /// The build (`sparkle:version`).
    public var build: String?
    public var minimumSystemVersion: String?
    public var maximumSystemVersion: String?
    /// Channel name; nil for the default channel.
    public var channel: String?
    public var isCritical = false
    public var isInformationalOnly = false
    public var releaseNotesURL: URL?
    public var fullReleaseNotesURL: URL?
    /// Inline release notes keyed by language (`""` when no language is given).
    public var descriptions: [String: String] = [:]
    public var date: Date?
    public var downloadURL: URL?
    /// Operating system of the download; nil means macOS.
    public var operatingSystem: String?

    public var version: AppVersion { AppVersion(display: shortVersion ?? build, build: build) }

    /// Inline notes in the preferred language, falling back to English and to the untagged ones.
    public func description(preferredLanguages: [String] = Locale.preferredLanguages) -> String? {
        for language in preferredLanguages.map({ String($0.prefix(2)) }) + ["en", ""] {
            if let text = descriptions[language], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        return descriptions.values.first
    }
}

/// Reads Sparkle appcast feeds.
public enum Appcast {

    public static func parse(_ data: Data) -> [AppcastItem] {
        let reader = FeedReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader.items
    }

    /// The newest release usable on this Mac: default channel, compatible system version, macOS download.
    public static func newest(in items: [AppcastItem],
                              systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> AppcastItem? {
        let system = VersionNumber("\(systemVersion.majorVersion).\(systemVersion.minorVersion).\(systemVersion.patchVersion)")!
        let usable = items.filter { item in
            guard item.channel == nil, item.build != nil || item.shortVersion != nil else { return false }
            if let os = item.operatingSystem?.lowercased(), !os.hasPrefix("mac") { return false }
            if let minimum = item.minimumSystemVersion.flatMap(VersionNumber.init), system < minimum { return false }
            if let maximum = item.maximumSystemVersion.flatMap(VersionNumber.init), maximum < system { return false }
            return true
        }
        return usable.max { a, b in
            UpdateDecision.compare(installed: a.version, available: b.version) == .updateAvailable
        }
    }
}

private final class FeedReader: NSObject, XMLParserDelegate {
    var items = [AppcastItem]()
    private var current: AppcastItem?
    private var text = ""
    private var language = ""

    private static let dateFormats: [DateFormatter] = ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss Z"].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if name == "item" {
            current = AppcastItem()
            return
        }
        guard current != nil else { return }
        language = attributes["xml:lang"].map { String($0.prefix(2)).lowercased() } ?? ""
        switch name {
        case "enclosure":
            var item = current!
            item.downloadURL = attributes["url"].flatMap(URL.init(string:))
            item.build = item.build ?? attributes["sparkle:version"]
            item.shortVersion = item.shortVersion ?? attributes["sparkle:shortVersionString"]
            item.operatingSystem = attributes["sparkle:os"]
            current = item
        case "sparkle:criticalUpdate":
            current?.isCritical = true
        case "sparkle:informationalUpdate":
            current?.isInformationalOnly = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA block: Data) {
        text += String(decoding: block, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "item" {
            if let item = current { items.append(item) }
            current = nil
            return
        }
        guard current != nil else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "title": current?.title = value
        case "sparkle:version": current?.build = value.nilIfEmpty
        case "sparkle:shortVersionString": current?.shortVersion = value.nilIfEmpty
        case "sparkle:minimumSystemVersion": current?.minimumSystemVersion = value.nilIfEmpty
        case "sparkle:maximumSystemVersion": current?.maximumSystemVersion = value.nilIfEmpty
        case "sparkle:channel": current?.channel = value.nilIfEmpty
        case "sparkle:releaseNotesLink": current?.releaseNotesURL = URL(string: value)
        case "sparkle:fullReleaseNotesLink": current?.fullReleaseNotesURL = URL(string: value)
        case "description": current?.descriptions[language] = value
        case "pubDate": current?.date = Self.dateFormats.lazy.compactMap { $0.date(from: value) }.first
        default: break
        }
        text = ""
    }
}

/// Downloads Sparkle feeds.
public struct AppcastClient: Sendable {
    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// The newest usable release of the feed, or nil if the feed cannot be read.
    public func newestItem(feed: URL) async -> AppcastItem? {
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("Upgrady", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else { return nil }
        return Appcast.newest(in: Appcast.parse(data))
    }

    /// The feed of an app: from its Info.plist, or set by the app in its preferences.
    public static func feedURL(for app: InstalledApp) -> URL? {
        if let feed = app.sparkleFeedURL { return feed }
        let value = CFPreferencesCopyAppValue("SUFeedURL" as CFString, app.bundleIdentifier as CFString) as? String
        return value.flatMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) }
    }
}
