import Foundation

/// Maps Markdown source to presentation-only runs for the rich editor.
///
/// The rich (WYSIWYG) mode does not convert Markdown to a second document
/// format. It keeps the exact same `String` in the text storage and only
/// assigns visual styles: inline markers such as `**` are rendered at a
/// near-zero size and made transparent, while their content gets a bold font.
/// Because characters are never inserted, removed, or rewritten, switching
/// modes can never corrupt the Markdown and selection ranges stay valid.
///
/// The mapping is Foundation-only so it can be unit-tested on Linux. AppKit
/// consumes the runs in `MarkdownSyntaxHighlighter`.
public enum MarkdownPresentation {
    public enum Style: Hashable, Sendable {
        case body
        case heading(level: Int)
        case strong
        case emphasis
        case strikethrough
        case code
        case link
        case image
        case blockQuote
        case listMarker
        case taskMarker
        case tableHeader
        case codeBlock
        /// A Markdown marker that should be visually hidden, never removed.
        case hidden
    }

    public struct Run: Hashable, Sendable {
        public let range: NSRange
        public let style: Style

        public init(range: NSRange, style: Style) {
            self.range = range
            self.style = style
        }
    }

    public static func runs(in text: String) -> [Run] {
        runs(in: text, spans: MarkdownSyntax.spans(in: text))
    }

    public static func runs(in text: String, spans: [MarkdownSyntaxSpan]) -> [Run] {
        guard !text.isEmpty else { return [] }
        let source = text as NSString
        var runs: [Run] = []

        for span in spans {
            switch span.kind {
            case .heading(let level):
                addHeading(span.range, level: level, source: source, into: &runs)
            case .emphasis:
                addEmphasis(span.range, markerLength: 1, style: .emphasis, source: source, into: &runs)
            case .strong:
                addEmphasis(span.range, markerLength: 2, style: .strong, source: source, into: &runs)
            case .strikethrough:
                addStrikethrough(span.range, source: source, into: &runs)
            case .codeSpan:
                addCodeSpan(span.range, source: source, into: &runs)
            case .link:
                addLink(span.range, image: false, source: source, into: &runs)
            case .image:
                addLink(span.range, image: true, source: source, into: &runs)
            case .blockQuote:
                addBlockQuote(span.range, source: source, into: &runs)
            case .listMarker:
                add(span.range, .listMarker, into: &runs)
            case .taskMarker:
                add(span.range, .taskMarker, into: &runs)
            case .tableHeader:
                add(span.range, .tableHeader, into: &runs)
            case .tableDelimiter, .tableRow:
                add(span.range, .body, into: &runs)
            case .codeBlock:
                addCodeBlock(span.range, source: source, into: &runs)
            }
        }

        return normalised(runs)
    }

    // MARK: - Block spans

    private static func addHeading(
        _ range: NSRange,
        level: Int,
        source: NSString,
        into runs: inout [Run]
    ) {
        let end = NSMaxRange(range)
        var cursor = range.location
        while cursor < end, source.character(at: cursor) == 32 {
            cursor += 1
        }
        guard cursor < end, source.character(at: cursor) == 35 else {
            add(range, .body, into: &runs)
            return
        }
        while cursor < end, source.character(at: cursor) == 35 {
            cursor += 1
        }
        if cursor < end {
            let character = source.character(at: cursor)
            if character == 32 || character == 9 {
                cursor += 1
            }
        }
        add(NSRange(location: range.location, length: cursor - range.location), .hidden, into: &runs)
        add(NSRange(location: cursor, length: end - cursor), .heading(level: level), into: &runs)
    }

    private static func addBlockQuote(
        _ range: NSRange,
        source: NSString,
        into runs: inout [Run]
    ) {
        let end = NSMaxRange(range)
        var cursor = range.location
        while cursor < end, source.character(at: cursor) == 32 {
            cursor += 1
        }
        guard cursor < end, source.character(at: cursor) == 62 else {
            add(range, .body, into: &runs)
            return
        }
        cursor += 1
        if cursor < end {
            let character = source.character(at: cursor)
            if character == 32 || character == 9 {
                cursor += 1
            }
        }
        add(NSRange(location: range.location, length: cursor - range.location), .hidden, into: &runs)
        add(NSRange(location: cursor, length: end - cursor), .blockQuote, into: &runs)
    }

    private static func addCodeBlock(
        _ range: NSRange,
        source: NSString,
        into runs: inout [Run]
    ) {
        let end = NSMaxRange(range)
        var location = range.location
        var isOpeningLine = true

        while location < end {
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            let lineEnd = min(NSMaxRange(lineRange), end)
            var contentEnd = lineEnd
            while contentEnd > location {
                let character = source.character(at: contentEnd - 1)
                if character == 10 || character == 13 {
                    contentEnd -= 1
                } else {
                    break
                }
            }
            let contentRange = NSRange(location: location, length: contentEnd - location)
            let content = source.substring(with: contentRange)

            if isOpeningLine || isFenceLine(content) {
                add(NSRange(location: location, length: lineEnd - location), .hidden, into: &runs)
            } else {
                add(contentRange, .codeBlock, into: &runs)
            }

            isOpeningLine = false
            let next = NSMaxRange(lineRange)
            guard next > location else { break }
            location = next
        }
    }

    private static func isFenceLine(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first == "`" || first == "~" else { return false }
        let run = trimmed.prefix { $0 == first }.count
        guard run >= 3 else { return false }
        return trimmed.dropFirst(run).allSatisfy { $0 == first || $0.isWhitespace }
    }

    // MARK: - Inline spans

    private static func addEmphasis(
        _ range: NSRange,
        markerLength: Int,
        style: Style,
        source: NSString,
        into runs: inout [Run]
    ) {
        let end = NSMaxRange(range)
        guard range.length >= markerLength * 2 else {
            add(range, .body, into: &runs)
            return
        }
        let marker = source.character(at: range.location)
        guard marker == 42 || marker == 95 else {
            add(range, .body, into: &runs)
            return
        }
        guard source.character(at: end - 1) == marker else {
            add(range, .body, into: &runs)
            return
        }
        if markerLength == 2 {
            guard source.character(at: range.location + 1) == marker,
                  source.character(at: end - 2) == marker else {
                add(range, .body, into: &runs)
                return
            }
        }
        let content = NSRange(
            location: range.location + markerLength,
            length: range.length - markerLength * 2
        )
        addDelimited(content, in: range, style: style, into: &runs)
    }

    private static func addStrikethrough(
        _ range: NSRange,
        source: NSString,
        into runs: inout [Run]
    ) {
        let end = NSMaxRange(range)
        guard range.length >= 4,
              source.character(at: range.location) == 126,
              source.character(at: range.location + 1) == 126,
              source.character(at: end - 1) == 126,
              source.character(at: end - 2) == 126 else {
            add(range, .body, into: &runs)
            return
        }
        let content = NSRange(location: range.location + 2, length: range.length - 4)
        addDelimited(content, in: range, style: .strikethrough, into: &runs)
    }

    private static func addCodeSpan(
        _ range: NSRange,
        source: NSString,
        into runs: inout [Run]
    ) {
        let end = NSMaxRange(range)
        var run = 0
        while range.location + run < end, source.character(at: range.location + run) == 96 {
            run += 1
        }
        guard run > 0, range.length >= run * 2 else {
            add(range, .body, into: &runs)
            return
        }
        for offset in 0..<run where source.character(at: end - run + offset) != 96 {
            add(range, .body, into: &runs)
            return
        }
        let content = NSRange(location: range.location + run, length: range.length - run * 2)
        addDelimited(content, in: range, style: .code, into: &runs)
    }

    private static func addLink(
        _ range: NSRange,
        image: Bool,
        source: NSString,
        into runs: inout [Run]
    ) {
        let end = NSMaxRange(range)
        let bracket = range.location + (image ? 1 : 0)
        guard bracket < end, source.character(at: bracket) == 91 else {
            add(range, .body, into: &runs)
            return
        }
        let searchStart = bracket + 1
        let search = NSRange(location: searchStart, length: end - searchStart)
        let close = source.range(of: "](", options: [], range: search)
        guard close.location != NSNotFound else {
            add(range, .body, into: &runs)
            return
        }
        let content = NSRange(location: searchStart, length: close.location - searchStart)
        add(NSRange(location: range.location, length: searchStart - range.location), .hidden, into: &runs)
        add(content, image ? .image : .link, into: &runs)
        add(
            NSRange(location: close.location, length: end - close.location),
            .hidden,
            into: &runs
        )
    }

    private static func addDelimited(
        _ content: NSRange,
        in range: NSRange,
        style: Style,
        into runs: inout [Run]
    ) {
        add(NSRange(location: range.location, length: content.location - range.location), .hidden, into: &runs)
        add(content, style, into: &runs)
        let contentEnd = NSMaxRange(content)
        add(
            NSRange(location: contentEnd, length: NSMaxRange(range) - contentEnd),
            .hidden,
            into: &runs
        )
    }

    // MARK: - Normalisation

    private static func add(_ range: NSRange, _ style: Style, into runs: inout [Run]) {
        guard range.location >= 0, range.length > 0 else { return }
        runs.append(Run(range: range, style: style))
    }

    private static func normalised(_ runs: [Run]) -> [Run] {
        let sorted = runs.sorted {
            if $0.range.location == $1.range.location {
                return $0.range.length < $1.range.length
            }
            return $0.range.location < $1.range.location
        }
        var result: [Run] = []
        var previousEnd = 0
        for run in sorted {
            guard run.range.location >= 0, run.range.length > 0 else { continue }
            if run.range.location < previousEnd {
                let end = NSMaxRange(run.range)
                guard end > previousEnd else { continue }
                result.append(Run(
                    range: NSRange(location: previousEnd, length: end - previousEnd),
                    style: run.style
                ))
                previousEnd = end
            } else {
                result.append(run)
                previousEnd = NSMaxRange(run.range)
            }
        }
        return result
    }
}
