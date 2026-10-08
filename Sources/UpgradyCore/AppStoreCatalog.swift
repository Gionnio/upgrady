import Foundation

/// Information about an app in the Mac App Store.
public struct AppStoreListing: Hashable, Sendable {
    public let bundleIdentifier: String
    public let version: String
    public let releaseNotes: String?
    public let releaseDate: Date?
    public let pageURL: URL?
    public let minimumSystemVersion: String?
}

/// Reads versions from Apple's public lookup API.
public struct AppStoreCatalog: Sendable {

    public var session: URLSession
    /// Store country, e.g. `it`. Defaults to the region of the Mac.
    public var country: String

    public init(session: URLSession = .shared, country: String = Locale.current.region?.identifier.lowercased() ?? "us") {
        self.session = session
        self.country = country
    }

    /// Looks up the given apps. Unknown apps are missing from the result.
    public func listings(for bundleIdentifiers: [String]) async -> [String: AppStoreListing] {
        var result = [String: AppStoreListing]()
        // The API accepts several identifiers at once; keep requests short.
        for chunk in bundleIdentifiers.chunked(into: 40) {
            for listing in await lookup(chunk, country: country) {
                result[listing.bundleIdentifier] = listing
            }
            // iPhone and iPad apps are listed as "software", not as Mac software.
            var missing = chunk.filter { result[$0] == nil }
            if !missing.isEmpty {
                for listing in await lookup(missing, country: country, entity: "software") {
                    result[listing.bundleIdentifier] = listing
                }
            }
            // Apps only sold in the US store are missing from other regions.
            missing = chunk.filter { result[$0] == nil }
            if country != "us", !missing.isEmpty {
                for listing in await lookup(missing, country: "us") {
                    result[listing.bundleIdentifier] = listing
                }
            }
        }
        return result
    }

    private func lookup(_ identifiers: [String], country: String, entity: String = "desktopSoftware") async -> [AppStoreListing] {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "bundleId", value: identifiers.joined(separator: ",")),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "entity", value: entity),
        ]
        guard let url = components.url,
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return Self.parse(data)
    }

    static func parse(_ data: Data) -> [AppStoreListing] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [] }
        let dates = ISO8601DateFormatter()
        return results.compactMap { item in
            guard let identifier = item["bundleId"] as? String, let version = item["version"] as? String else { return nil }
            return AppStoreListing(
                bundleIdentifier: identifier,
                version: version,
                releaseNotes: item["releaseNotes"] as? String,
                releaseDate: (item["currentVersionReleaseDate"] as? String).flatMap(dates.date(from:)),
                pageURL: (item["trackViewUrl"] as? String).flatMap(URL.init(string:)),
                minimumSystemVersion: item["minimumOsVersion"] as? String
            )
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
