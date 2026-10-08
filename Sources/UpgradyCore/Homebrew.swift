import Foundation

/// A local Homebrew installation.
public struct HomebrewInstallation: Sendable {
    public let brewURL: URL

    /// The Homebrew prefix, e.g. `/opt/homebrew`.
    public var prefix: URL { brewURL.deletingLastPathComponent().deletingLastPathComponent() }
    public var caskroom: URL { prefix.appendingPathComponent("Caskroom") }
    public var taps: URL { prefix.appendingPathComponent("Library/Taps") }

    public init(brewURL: URL) {
        self.brewURL = brewURL
    }

    /// Finds brew in the usual places, or at `customPath` if given.
    public static func locate(customPath: String? = nil) -> HomebrewInstallation? {
        let candidates: [String]
        if let customPath, !customPath.trimmingCharacters(in: .whitespaces).isEmpty {
            candidates = [(customPath as NSString).expandingTildeInPath]
        } else {
            candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        }
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:))
            .map { HomebrewInstallation(brewURL: URL(fileURLWithPath: $0)) }
    }
}

// MARK: - Casks

/// A cask definition from the Homebrew API or a tap.
public struct Cask: Hashable, Sendable {
    public let token: String
    /// The tap, nil for the official casks.
    public let tap: String?
    /// The raw cask version, e.g. `1.2.3,456`. Nil for `version :latest`.
    public let version: String?
    /// App bundle names installed by the cask, e.g. `Google Chrome.app`.
    public let appNames: Set<String>
    /// Identifiers mentioned by the cask (quit, uninstall, zap), used to confirm a match.
    public let identifierHints: Set<String>
    public let autoUpdates: Bool
    public let downloadURL: String?
    public let homepage: String?

    /// The name to use with brew: `user/tap/token` for tap casks.
    public var qualifiedName: String { tap.map { "\($0)/\(token)" } ?? token }

    public init(token: String, tap: String? = nil, version: String?, appNames: Set<String>, identifierHints: Set<String> = [],
                autoUpdates: Bool = false, downloadURL: String? = nil, homepage: String? = nil) {
        self.token = token
        self.tap = tap
        self.version = version
        self.appNames = appNames
        self.identifierHints = identifierHints
        self.autoUpdates = autoUpdates
        self.downloadURL = downloadURL
        self.homepage = homepage
    }
}

/// A cask installed on this Mac.
public struct InstalledCask: Hashable, Sendable {
    public let token: String
    /// The tap it was installed from, nil if official or unknown.
    public let tap: String?
    /// Versions present in the Caskroom.
    public let versions: Set<String>
    /// App bundle names, from the install receipt.
    public let appNames: Set<String>
}

/// Reads installed casks from the Caskroom. Fast, does not run brew.
public enum Caskroom {

    public static func read(_ installation: HomebrewInstallation) -> [InstalledCask] {
        read(caskroom: installation.caskroom)
    }

    public static func read(caskroom: URL) -> [InstalledCask] {
        let fileManager = FileManager.default
        guard let tokens = try? fileManager.contentsOfDirectory(atPath: caskroom.path) else { return [] }
        return tokens.filter { !$0.hasPrefix(".") }.sorted().map { token in
            let folder = caskroom.appendingPathComponent(token)
            let versions = ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }
            let receiptURL = folder.appendingPathComponent(".metadata/INSTALL_RECEIPT.json")
            let receipt = (try? Data(contentsOf: receiptURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let tap = ((receipt?["source"] as? [String: Any])?["tap"] as? String).flatMap { $0 == "homebrew/cask" || $0.isEmpty ? nil : $0 }
            return InstalledCask(token: token, tap: tap, versions: Set(versions),
                                 appNames: CaskJSON.appNames(in: receipt?["uninstall_artifacts"] ?? []))
        }
    }
}

/// Parsing helpers for cask JSON (API and install receipts).
enum CaskJSON {

    /// App bundle names in an artifacts list. Supports `"app": ["A.app", {"target": "B.app"}]` and a sibling `"target"`.
    static func appNames(in artifacts: Any) -> Set<String> {
        guard let list = artifacts as? [[String: Any]] else { return [] }
        var names = Set<String>()
        for artifact in list {
            guard let apps = artifact["app"] as? [Any] else { continue }
            if let target = artifact["target"] as? String {
                names.insert((target as NSString).lastPathComponent)
                continue
            }
            var pending: String?
            for item in apps {
                if let string = item as? String {
                    if let pending { names.insert(pending) }
                    pending = (string as NSString).lastPathComponent
                } else if let options = item as? [String: Any], let target = options["target"] as? String {
                    pending = (target as NSString).lastPathComponent
                }
            }
            if let pending { names.insert(pending) }
        }
        return names
    }

    /// Reverse-DNS identifiers mentioned anywhere in the given JSON value (uninstall, zap…).
    static func identifierHints(in value: Any) -> Set<String> {
        var strings = [String]()
        collectStrings(value, into: &strings)
        var hints = Set<String>()
        let pattern = try! NSRegularExpression(pattern: #"\b[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+){2,}\b"#)
        for string in strings {
            let range = NSRange(string.startIndex..., in: string)
            for match in pattern.matches(in: string, range: range) {
                guard let r = Range(match.range, in: string) else { continue }
                var hint = String(string[r])
                for suffix in [".plist", ".savedState", ".binarycookies", ".sfl2", ".sfl3"] where hint.hasSuffix(suffix) {
                    hint.removeLast(suffix.count)
                }
                hints.insert(hint)
            }
        }
        return hints
    }

    private static func collectStrings(_ value: Any, into strings: inout [String]) {
        if let string = value as? String {
            strings.append(string)
        } else if let list = value as? [Any] {
            list.forEach { collectStrings($0, into: &strings) }
        } else if let dictionary = value as? [String: Any] {
            dictionary.values.forEach { collectStrings($0, into: &strings) }
        }
    }
}

/// The official casks, from the Homebrew API.
public struct CaskCatalog: Sendable {
    public let casks: [Cask]
    private let byToken: [String: Cask]
    private let byAppName: [String: [Cask]]

    public init(casks: [Cask]) {
        self.casks = casks
        self.byToken = Dictionary(casks.map { ($0.token, $0) }, uniquingKeysWith: { first, _ in first })
        var byAppName = [String: [Cask]]()
        for cask in casks {
            for name in cask.appNames { byAppName[name.lowercased(), default: []].append(cask) }
        }
        self.byAppName = byAppName
    }

    public func cask(token: String) -> Cask? { byToken[token] }

    /// Casks installing an app with this file name, ignoring case.
    public func casks(appName: String) -> [Cask] { byAppName[appName.lowercased()] ?? [] }

    public static let apiURL = URL(string: "https://formulae.brew.sh/api/cask.json")!

    /// Parses the API response (a JSON array of casks).
    public static func parse(_ data: Data) -> CaskCatalog {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return CaskCatalog(casks: []) }
        let casks = list.compactMap { item -> Cask? in
            // Disabled casks can no longer be installed or upgraded.
            guard let token = item["token"] as? String, item["disabled"] as? Bool != true else { return nil }
            let artifacts = item["artifacts"] ?? []
            let names = CaskJSON.appNames(in: artifacts)
            guard !names.isEmpty else { return nil }
            let hintSources: [Any] = (artifacts as? [[String: Any]] ?? []).compactMap { $0["uninstall"] ?? $0["zap"] }
            let version = item["version"] as? String
            return Cask(token: token, tap: nil, version: version == "latest" ? nil : version, appNames: names,
                        identifierHints: CaskJSON.identifierHints(in: hintSources),
                        autoUpdates: item["auto_updates"] as? Bool ?? false,
                        downloadURL: item["url"] as? String, homepage: item["homepage"] as? String)
        }
        return CaskCatalog(casks: casks)
    }

    /// Downloads the catalog, using a cached copy younger than `maximumAge`.
    public static func load(cacheURL: URL, maximumAge: TimeInterval = 3600, session: URLSession = .shared) async -> CaskCatalog {
        let fileManager = FileManager.default
        if let attributes = try? fileManager.attributesOfItem(atPath: cacheURL.path),
           let modified = attributes[.modificationDate] as? Date, Date().timeIntervalSince(modified) < maximumAge,
           let data = try? Data(contentsOf: cacheURL) {
            return parse(data)
        }
        if let (data, response) = try? await session.data(from: apiURL), (response as? HTTPURLResponse)?.statusCode == 200 {
            try? fileManager.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
            return parse(data)
        }
        // Offline: an outdated copy is better than nothing.
        return (try? Data(contentsOf: cacheURL)).map(parse) ?? CaskCatalog(casks: [])
    }
}

/// Casks of the locally installed third-party taps.
public enum TapCatalog {

    public static func read(_ installation: HomebrewInstallation) -> [Cask] {
        read(taps: installation.taps)
    }

    public static func read(taps: URL) -> [Cask] {
        let fileManager = FileManager.default
        var casks = [Cask]()
        for user in (try? fileManager.contentsOfDirectory(atPath: taps.path)) ?? [] where !user.hasPrefix(".") && user != "homebrew" {
            let userURL = taps.appendingPathComponent(user)
            for repository in (try? fileManager.contentsOfDirectory(atPath: userURL.path)) ?? [] where repository.hasPrefix("homebrew-") {
                let tap = "\(user)/\(repository.dropFirst("homebrew-".count))"
                let casksURL = userURL.appendingPathComponent(repository).appendingPathComponent("Casks")
                guard let files = fileManager.enumerator(at: casksURL, includingPropertiesForKeys: nil) else { continue }
                for case let file as URL in files where file.pathExtension == "rb" {
                    guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
                    let cask = RubyCask.parse(source, token: file.deletingPathExtension().lastPathComponent, tap: tap)
                    if !cask.appNames.isEmpty { casks.append(cask) }
                }
            }
        }
        return casks
    }
}

/// Minimal reader for Ruby cask files: only the fields Upgrady needs.
public enum RubyCask {

    public static func parse(_ source: String, token: String, tap: String?) -> Cask {
        let version = firstValue(of: "version", in: source).flatMap { $0.contains("#{") ? nil : $0 }
        let appNames = Set(appStatements(in: source))
        return Cask(token: token, tap: tap, version: version, appNames: appNames,
                    identifierHints: CaskJSON.identifierHints(in: [source]),
                    autoUpdates: source.range(of: #"(?m)^\s*auto_updates\s+true"#, options: .regularExpression) != nil,
                    downloadURL: firstValue(of: "url", in: source), homepage: firstValue(of: "homepage", in: source))
    }

    /// The first quoted argument of a top-level statement like `version "1.2"`.
    static func firstValue(of keyword: String, in source: String) -> String? {
        let pattern = #"(?m)^\s*"# + keyword + #"\s+["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let range = Range(match.range(at: 1), in: source) else { return nil }
        return String(source[range])
    }

    /// `app "Name.app"` or `app "Folder/Name.app", target: "Other.app"` → installed bundle names.
    static func appStatements(in source: String) -> [String] {
        let pattern = #"(?m)^\s*app\s+["']([^"']+)["'](?:\s*,\s*target:\s*["']([^"']+)["'])?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap { match in
            let group = match.range(at: 2).location != NSNotFound ? 2 : 1
            guard let range = Range(match.range(at: group), in: source) else { return nil }
            let name = (String(source[range]) as NSString).lastPathComponent
            return name.contains("#{") ? nil : name
        }
    }
}

// MARK: - Matching

/// Connects installed apps with casks.
public struct CaskMatcher: Sendable {
    public let installedCasks: [InstalledCask]
    public let catalog: CaskCatalog
    public let tapCasks: [Cask]

    private let installedByAppName: [String: InstalledCask]
    private let installedByToken: [String: InstalledCask]

    public init(installedCasks: [InstalledCask], catalog: CaskCatalog, tapCasks: [Cask]) {
        self.installedCasks = installedCasks
        self.catalog = catalog
        self.tapCasks = tapCasks
        var byName = [String: InstalledCask]()
        for cask in installedCasks { for name in cask.appNames { byName[name] = cask } }
        self.installedByAppName = byName
        self.installedByToken = Dictionary(installedCasks.map { ($0.token, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The installed cask managing this app, if any.
    public func installedCask(for app: InstalledApp) -> InstalledCask? {
        if let cask = installedByAppName[app.fileName] { return cask }
        // Several casks may install the same app (stable, @beta…): the installed one wins.
        let candidates = catalog.casks(appName: app.fileName) + tapCasks.filter { $0.appNames.contains(app.fileName) }
        let installed = candidates.filter { $0.appNames.contains(app.fileName) }.compactMap { installedByToken[$0.token] }
        if installed.count == 1 { return installed.first }
        if let cask = availableCask(for: app), let installed = installedByToken[cask.token] { return installed }
        return nil
    }

    /// The cask definition (official or from a tap) for an installed cask.
    public func definition(for installed: InstalledCask) -> Cask? {
        if let tap = installed.tap {
            return tapCasks.first { $0.tap == tap && $0.token == installed.token }
        }
        return catalog.cask(token: installed.token) ?? uniqueTapCask(token: installed.token)
    }

    /// A cask that would install this app, official first, then third-party taps.
    public func availableCask(for app: InstalledApp) -> Cask? {
        if let cask = Self.bestMatch(for: app, among: catalog.casks(appName: app.fileName)) { return cask }
        let tapCandidates = tapCasks.filter { $0.appNames.contains { $0.caseInsensitiveCompare(app.fileName) == .orderedSame } }
        return Self.bestMatch(for: app, among: tapCandidates)
    }

    private func uniqueTapCask(token: String) -> Cask? {
        let matches = tapCasks.filter { $0.token == token }
        return matches.count == 1 ? matches.first : nil
    }

    /// Picks the cask for an app among casks with a similar app name.
    ///
    /// An exact file name is enough when it is unambiguous; a name matching only when ignoring case,
    /// or several candidates, need the bundle identifier as confirmation.
    static func bestMatch(for app: InstalledApp, among candidates: [Cask]) -> Cask? {
        let exact = candidates.filter { $0.appNames.contains(app.fileName) }
        if exact.count == 1 { return exact.first }
        // Stable cask and channel variants (`name@beta`, `name@nightly`): the stable one.
        let stable = exact.filter { !$0.token.contains("@") }
        if stable.count == 1, exact.allSatisfy({ $0.token == stable[0].token || $0.token.hasPrefix(stable[0].token + "@") }) {
            return stable.first
        }
        let pool = exact.isEmpty ? candidates : exact
        let confirmed = pool.filter { confirms($0.identifierHints, app.bundleIdentifier) }
        return confirmed.count == 1 ? confirmed.first : nil
    }

    static let genericVendors: Set<String> = ["com.github.", "io.github.", "com.electron.", "org.chromium.", "com.apple.", "com.example."]

    /// Whether identifier hints point to the bundle identifier: the same identifier, or one of the same vendor.
    static func confirms(_ hints: Set<String>, _ bundleIdentifier: String) -> Bool {
        let identifier = bundleIdentifier.lowercased()
        let lowered = hints.map { $0.lowercased() }
        if lowered.contains(identifier) { return true }
        let parts = identifier.split(separator: ".")
        guard parts.count >= 3 else { return false }
        let vendor = parts.prefix(2).joined(separator: ".") + "."
        // Shared prefixes say nothing about the vendor.
        guard !genericVendors.contains(vendor) else { return false }
        return lowered.contains { $0.hasPrefix(vendor) }
    }
}
