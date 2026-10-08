import Foundation

/// A version string split into comparable pieces, e.g. `2.0b3` → 2, 0, b, 3.
public struct VersionNumber: Hashable, Sendable, CustomStringConvertible {

    public enum Piece: Hashable, Sendable {
        case number(Int)
        case word(String)
    }

    /// The text the version was read from, without prefixes like `v` or `Version`.
    public let text: String
    public let pieces: [Piece]

    public var description: String { text }

    /// Reads a version. Returns nil if the text contains no digits.
    ///
    /// Leading words (`v`, `Version`, `release-`) are skipped, and anything after a space or an opening
    /// parenthesis is ignored (`5.1 (431)` → `5.1`).
    public init?(_ string: String) {
        guard let firstDigit = string.firstIndex(where: \.isNumber) else { return nil }
        var body = Substring(string[firstDigit...])
        if let end = body.firstIndex(where: { $0 == " " || $0 == "(" || $0 == "[" }) {
            body = body[..<end]
        }
        let trimmed = String(body).trimmingCharacters(in: CharacterSet(charactersIn: ".-_+ "))
        guard !trimmed.isEmpty else { return nil }

        var pieces = [Piece]()
        var current = ""
        var currentIsDigit = false
        func flush() {
            guard !current.isEmpty else { return }
            if currentIsDigit {
                // Very long digit runs (hashes, timestamps beyond Int) are kept as words.
                pieces.append(Int(current).map(Piece.number) ?? .word(current))
            } else {
                pieces.append(.word(current.lowercased()))
            }
            current = ""
        }
        for character in trimmed {
            if character.isNumber {
                if !currentIsDigit { flush() }
                currentIsDigit = true
                current.append(character)
            } else if character.isLetter {
                if currentIsDigit { flush() }
                currentIsDigit = false
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        guard pieces.contains(where: { if case .number = $0 { true } else { false } }) else { return nil }

        self.text = trimmed
        self.pieces = pieces
    }

    /// Ranks for words marking a pre-release. Higher means closer to the final release.
    private static let preReleaseRanks: [String: Int] = [
        "dev": 0, "nightly": 0, "snapshot": 0,
        "alpha": 1, "a": 1,
        "beta": 2, "b": 2,
        "pre": 3, "preview": 3,
        "rc": 4, "candidate": 4,
    ]

    static func preReleaseRank(_ word: String) -> Int? {
        preReleaseRanks[word]
    }

    /// Compares two versions. Pre-releases come before the final version (`2.0b3` < `2.0`),
    /// trailing zeros do not matter (`2.0` == `2.0.0`).
    public static func compare(_ lhs: VersionNumber, _ rhs: VersionNumber) -> ComparisonResult {
        let count = max(lhs.pieces.count, rhs.pieces.count)
        for index in 0..<count {
            let left = index < lhs.pieces.count ? lhs.pieces[index] : nil
            let right = index < rhs.pieces.count ? rhs.pieces[index] : nil
            switch (left, right) {
            case let (.number(a)?, .number(b)?):
                if a != b { return a < b ? .orderedAscending : .orderedDescending }
            case let (.word(a)?, .word(b)?):
                if a != b {
                    let rankA = preReleaseRank(a) ?? 5
                    let rankB = preReleaseRank(b) ?? 5
                    if rankA != rankB { return rankA < rankB ? .orderedAscending : .orderedDescending }
                    return a < b ? .orderedAscending : .orderedDescending
                }
            case (.number?, .word?):
                return .orderedDescending
            case (.word?, .number?):
                return .orderedAscending
            case let (piece?, nil):
                return tailOrder(piece, remaining: Array(lhs.pieces[index...]))
            case let (nil, piece?):
                return tailOrder(piece, remaining: Array(rhs.pieces[index...])).reversed
            case (nil, nil):
                return .orderedSame
            }
        }
        return .orderedSame
    }

    /// How a version with extra pieces compares to the shorter one: extra zeros are equal,
    /// a pre-release word makes it older, anything else makes it newer.
    private static func tailOrder(_ first: Piece, remaining: [Piece]) -> ComparisonResult {
        if case .word = first { return .orderedAscending }
        let allZero = remaining.allSatisfy { if case .number(0) = $0 { true } else { false } }
        return allZero ? .orderedSame : .orderedDescending
    }

    /// Whether the version is a pre-release (contains alpha, beta, rc…).
    public var isPreRelease: Bool {
        pieces.contains { if case .word(let word) = $0 { Self.preReleaseRank(word) != nil } else { false } }
    }

    /// The numbers of the version, ignoring words.
    public var numbers: [Int] {
        pieces.compactMap { if case .number(let n) = $0 { n } else { nil } }
    }
}

extension VersionNumber: Comparable {
    public static func < (lhs: VersionNumber, rhs: VersionNumber) -> Bool {
        compare(lhs, rhs) == .orderedAscending
    }

    public static func == (lhs: VersionNumber, rhs: VersionNumber) -> Bool {
        compare(lhs, rhs) == .orderedSame
    }

    public func hash(into hasher: inout Hasher) {
        // Equal versions may differ in trailing zeros, so only hash the significant numbers.
        var numbers = self.numbers
        while numbers.last == 0 { numbers.removeLast() }
        hasher.combine(numbers)
    }
}

private extension ComparisonResult {
    var reversed: ComparisonResult {
        switch self {
        case .orderedAscending: .orderedDescending
        case .orderedDescending: .orderedAscending
        case .orderedSame: .orderedSame
        }
    }
}
