import Foundation

/// Options shared by the find bar and the replace actions.
public struct FindOptions: Equatable, Sendable {
    /// Literal matching is case-insensitive by default; regex matching keeps
    /// the user's casing unless they opt in. The find bar exposes this as a
    /// toggle.
    public var caseSensitive: Bool
    /// When true, `query` is compiled as an ICU regular expression.
    public var usesRegularExpression: Bool

    public init(caseSensitive: Bool = false, usesRegularExpression: Bool = false) {
        self.caseSensitive = caseSensitive
        self.usesRegularExpression = usesRegularExpression
    }

    public static let `default` = FindOptions()
}

/// One match inside a document. Ranges are UTF-16 ranges so they can be fed
/// straight to AppKit text APIs.
public struct FindMatch: Equatable, Sendable {
    public let range: NSRange
    /// The exact text of the match, useful for highlights and previews.
    public let text: String

    public init(range: NSRange, text: String) {
        self.range = range
        self.text = text
    }
}

public enum FindError: Error, Equatable, LocalizedError {
    case invalidRegularExpression(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidRegularExpression(message):
            return "Invalid regular expression: \(message)"
        }
    }
}

/// Pure, Foundation-only find/replace logic.
///
/// Keeping this out of the AppKit layer makes the behaviour testable on Linux
/// and guarantees the GUI and the tests use the same matching rules.
public enum FindEngine {
    /// Returns every non-overlapping match of `query` in `text`.
    ///
    /// An empty query returns no matches. Regex queries compile once and
    /// report syntax errors as `FindError.invalidRegularExpression` instead of
    /// silently treating the pattern as literal text.
    public static func matches(
        of query: String,
        in text: String,
        options: FindOptions = .default
    ) throws -> [FindMatch] {
        guard !query.isEmpty else { return [] }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        if options.usesRegularExpression {
            let expression: NSRegularExpression
            do {
                expression = try NSRegularExpression(
                    pattern: query,
                    options: options.caseSensitive ? [] : [.caseInsensitive]
                )
            } catch {
                throw FindError.invalidRegularExpression(error.localizedDescription)
            }
            return expression.matches(in: text, options: [], range: fullRange).map { result in
                FindMatch(range: result.range, text: nsText.substring(with: result.range))
            }
        }

        var matches: [FindMatch] = []
        var searchRange = fullRange
        let compareOptions: NSString.CompareOptions = options.caseSensitive ? [] : [.caseInsensitive]

        while searchRange.length > 0 {
            let found = nsText.range(of: query, options: compareOptions, range: searchRange)
            guard found.location != NSNotFound else { break }
            matches.append(FindMatch(range: found, text: nsText.substring(with: found)))
            let nextLocation = found.location + max(found.length, 1)
            if nextLocation >= fullRange.length { break }
            searchRange = NSRange(location: nextLocation, length: fullRange.length - nextLocation)
        }
        return matches
    }

    /// Replaces every match. For regex queries the replacement is treated as a
    /// template (`$1`, `${name}`), matching Xcode/TextEdit behaviour. For
    /// literal queries the replacement is inserted verbatim.
    public static func replacingAll(
        in text: String,
        query: String,
        replacement: String,
        options: FindOptions = .default
    ) throws -> String {
        guard !query.isEmpty else { return text }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        if options.usesRegularExpression {
            let expression: NSRegularExpression
            do {
                expression = try NSRegularExpression(
                    pattern: query,
                    options: options.caseSensitive ? [] : [.caseInsensitive]
                )
            } catch {
                throw FindError.invalidRegularExpression(error.localizedDescription)
            }
            return expression.stringByReplacingMatches(
                in: text,
                options: [],
                range: fullRange,
                withTemplate: replacement
            )
        }

        let matches = try matches(of: query, in: text, options: options)
        guard !matches.isEmpty else { return text }
        let mutable = NSMutableString(string: text)
        for match in matches.reversed() {
            mutable.replaceCharacters(in: match.range, with: replacement)
        }
        return mutable as String
    }

    /// Replaces a single match, returning the new text.
    public static func replacing(
        match: FindMatch,
        in text: String,
        with replacement: String
    ) -> String {
        let mutable = NSMutableString(string: text)
        guard match.range.location != NSNotFound,
              NSMaxRange(match.range) <= mutable.length else { return text }
        mutable.replaceCharacters(in: match.range, with: replacement)
        return mutable as String
    }

    /// The match index that contains or follows `location`, for keeping the
    /// selection anchored after edits. Returns `nil` when there are none.
    public static func matchIndex(nearest location: Int, in matches: [FindMatch]) -> Int? {
        guard !matches.isEmpty else { return nil }
        if let index = matches.firstIndex(where: { NSLocationInRange(location, $0.range) }) {
            return index
        }
        if let index = matches.firstIndex(where: { $0.range.location >= location }) {
            return index
        }
        return matches.count - 1
    }
}
