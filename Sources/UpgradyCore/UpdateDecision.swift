import Foundation

/// A version as reported by an app or by an update source: a display version and/or a build.
public struct AppVersion: Hashable, Sendable, CustomStringConvertible {
    public let display: String?
    public let build: String?

    public init(display: String?, build: String?) {
        self.display = display?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        self.build = build?.trimmingCharacters(in: .whitespaces).nilIfEmpty
    }

    /// A Homebrew cask version: `1.2.3,456` → display `1.2.3`. The part after the comma only identifies the download.
    public init(caskVersion: String) {
        let display = caskVersion.split(separator: ",", maxSplits: 1).first.map(String.init) ?? caskVersion
        self.init(display: display, build: nil)
    }

    public var description: String {
        switch (display, build) {
        case let (display?, build?) where display != build: "\(display) (\(build))"
        case let (display?, _): display
        case let (nil, build?): build
        default: "?"
        }
    }

    var displayNumber: VersionNumber? { display.flatMap(VersionNumber.init) }
    var buildNumber: VersionNumber? { build.flatMap(VersionNumber.init) }
}

/// Whether an available version is newer than the installed one.
public enum UpdateDecision: Equatable, Sendable {
    case updateAvailable
    case upToDate
    /// The versions cannot be compared reliably. Treated like "up to date".
    case unknown

    public var isUpdate: Bool { self == .updateAvailable }

    /// Decides whether `available` is newer than `installed`.
    ///
    /// The display version decides; the build only breaks ties or is used when a source reports nothing else.
    /// When in doubt, no update is reported.
    public static func compare(installed: AppVersion, available: AppVersion) -> UpdateDecision {
        let installedDisplay = installed.displayNumber
        let availableDisplay = available.displayNumber

        if let installedDisplay, let availableDisplay {
            // The build may be appended to the available version: 1.2 (40) vs 1.2.40.
            if let build = installed.buildNumber, appendsBuild(availableDisplay, to: installedDisplay, build: build) {
                return .upToDate
            }
            switch VersionNumber.compare(installedDisplay, availableDisplay) {
            case .orderedAscending:
                // A pre-release is only offered when a pre-release is installed.
                if availableDisplay.isPreRelease && !installedDisplay.isPreRelease { return .upToDate }
                return .updateAvailable
            case .orderedDescending:
                return .upToDate
            case .orderedSame:
                return compareBuilds(installed.buildNumber, available.buildNumber) ?? .upToDate
            }
        }

        // Only builds are known, e.g. a feed without a display version.
        if available.display == nil || availableDisplay == nil {
            return compareBuilds(installed.buildNumber, available.buildNumber) ?? .unknown
        }

        // The available version may equal the installed build (some feeds report builds as versions).
        if let installedBuild = installed.buildNumber, let availableDisplay {
            switch VersionNumber.compare(installedBuild, availableDisplay) {
            case .orderedAscending: return .updateAvailable
            default: return .upToDate
            }
        }
        return .unknown
    }

    private static func compareBuilds(_ installed: VersionNumber?, _ available: VersionNumber?) -> UpdateDecision? {
        guard let installed, let available else { return nil }
        switch VersionNumber.compare(installed, available) {
        case .orderedAscending: return .updateAvailable
        default: return .upToDate
        }
    }

    /// Whether `candidate` is `base` with `build` appended as last number(s), e.g. 1.2 + 40 → 1.2.40.
    private static func appendsBuild(_ candidate: VersionNumber, to base: VersionNumber, build: VersionNumber) -> Bool {
        let candidateNumbers = candidate.numbers
        let baseNumbers = base.numbers
        let buildNumbers = build.numbers
        guard !buildNumbers.isEmpty, candidateNumbers.count > baseNumbers.count,
              candidateNumbers.count == baseNumbers.count + buildNumbers.count else { return false }
        return Array(candidateNumbers.prefix(baseNumbers.count)) == baseNumbers
            && Array(candidateNumbers.suffix(buildNumbers.count)) == buildNumbers
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
