import Foundation

/// A semantic span of Markdown source found by ``MarkdownSyntax``.
///
/// Ranges are UTF-16 indices into the string that produced them, which makes
/// them directly usable as `NSRange` values in AppKit.
public struct MarkdownSyntaxSpan: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case heading(level: Int)
        case emphasis
        case strong
        case strikethrough
        case listMarker
        case taskMarker
        case link
        case image
        case codeSpan
        case codeBlock
        case tableHeader
        case tableDelimiter
        case tableRow
        case blockQuote
    }

    public let range: NSRange
    public let kind: Kind

    public init(range: NSRange, kind: Kind) {
        self.range = range
        self.kind = kind
    }
}

/// A small, dependency-free Markdown scanner used by the editor highlighter.
///
/// It is deliberately not a parser: it recognises the block and inline shapes
/// needed for colouring while never changing the underlying source text. It
/// runs in linear time over the UTF-16 buffer so a 1 MB document stays fast,
/// and it is Foundation-only so the range logic is unit-tested on Linux.
public enum MarkdownSyntax {
    public static func spans(in text: String) -> [MarkdownSyntaxSpan] {
        guard !text.isEmpty else { return [] }
        let source = text as NSString
        var spans: [MarkdownSyntaxSpan] = []

        var location = 0
        var fence: Fence?
        var tableMode = false
        var previousLine: Line?

        while location < source.length {
            let line = Line(source: source, location: location)
            location = line.after

            if let activeFence = fence {
                spans.append(MarkdownSyntaxSpan(range: line.fullRange, kind: .codeBlock))
                tableMode = false
                previousLine = nil
                if isClosingFence(line.content, marker: activeFence.marker, minimum: activeFence.length) {
                    fence = nil
                }
                continue
            }

            if let opened = openingFence(line.content) {
                fence = opened
                spans.append(MarkdownSyntaxSpan(range: line.fullRange, kind: .codeBlock))
                tableMode = false
                previousLine = nil
                continue
            }

            let indent = leadingSpaces(line.content)
            let body = line.content.dropFirst(indent)

            if body.isEmpty {
                tableMode = false
                previousLine = nil
                continue
            }

            if isTableDelimiter(line.content) {
                if let header = previousLine, header.content.contains("|") {
                    spans.append(MarkdownSyntaxSpan(range: header.fullRange, kind: .tableHeader))
                }
                spans.append(MarkdownSyntaxSpan(range: line.fullRange, kind: .tableDelimiter))
                tableMode = true
                previousLine = line
                continue
            }

            if tableMode, line.content.contains("|") {
                spans.append(MarkdownSyntaxSpan(range: line.fullRange, kind: .tableRow))
                previousLine = line
                continue
            }

            tableMode = false

            if let heading = heading(in: line.content, indent: indent) {
                spans.append(MarkdownSyntaxSpan(range: line.fullRange, kind: .heading(level: heading)))
                previousLine = line
                continue
            }

            if body.first == ">" {
                spans.append(MarkdownSyntaxSpan(range: line.fullRange, kind: .blockQuote))
                previousLine = line
                continue
            }

            scanListMarker(line: line, indent: indent, into: &spans)
            scanInline(source: source, in: line, into: &spans)
            previousLine = line
        }

        return coalesced(spans)
    }

    // MARK: - Blocks

    private struct Fence {
        let marker: unichar
        let length: Int
    }

    private struct Line {
        let range: NSRange
        let fullRange: NSRange
        let content: String
        let after: Int

        init(source: NSString, location: Int) {
            let full = source.lineRange(for: NSRange(location: location, length: 0))
            var contentEnd = full.location + full.length
            while contentEnd > full.location {
                let character = source.character(at: contentEnd - 1)
                guard character == 10 || character == 13 else { break }
                contentEnd -= 1
            }
            self.range = NSRange(location: full.location, length: contentEnd - full.location)
            self.fullRange = full
            self.content = source.substring(with: range)
            self.after = full.location + full.length
        }
    }

    private static func leadingSpaces(_ content: String) -> Int {
        var count = 0
        for character in content {
            guard character == " " else { break }
            count += 1
            if count > 3 { break }
        }
        return count
    }

    private static func openingFence(_ content: String) -> Fence? {
        let indent = leadingSpaces(content)
        guard indent <= 3 else { return nil }
        let body = Substring(content).dropFirst(indent)
        guard let first = body.first, first == "`" || first == "~" else { return nil }
        let marker = first == "`" ? unichar(96) : unichar(126)
        let run = body.prefix { $0 == first }.count
        guard run >= 3 else { return nil }
        if first == "`", body.dropFirst(run).contains("`") { return nil }
        return Fence(marker: marker, length: run)
    }

    private static func isClosingFence(_ content: String, marker: unichar, minimum: Int) -> Bool {
        let indent = leadingSpaces(content)
        guard indent <= 3 else { return false }
        let body = Substring(content).dropFirst(indent)
        guard let first = body.first else { return false }
        let expected: Character = marker == 96 ? "`" : "~"
        guard first == expected else { return false }
        let run = body.prefix { $0 == first }.count
        guard run >= minimum else { return false }
        return body.dropFirst(run).allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func heading(in content: String, indent: Int) -> Int? {
        guard indent <= 3 else { return nil }
        let body = Substring(content).dropFirst(indent)
        guard let first = body.first, first == "#" else { return nil }
        let level = body.prefix { $0 == "#" }.count
        guard level >= 1, level <= 6 else { return nil }
        let remainder = body.dropFirst(level)
        guard remainder.isEmpty || remainder.first == " " || remainder.first == "\t" else { return nil }
        return level
    }

    private static func scanListMarker(
        line: Line,
        indent: Int,
        into spans: inout [MarkdownSyntaxSpan]
    ) {
        guard indent <= 3 else { return }
        let content = line.content as NSString
        let index = indent
        guard index < content.length else { return }

        var markerLength = 0
        let first = content.character(at: index)
        if first == 45 || first == 42 || first == 43 {
            markerLength = 1
        } else if first >= 48, first <= 57 {
            var digits = 0
            while index + digits < content.length {
                let character = content.character(at: index + digits)
                guard character >= 48, character <= 57 else { break }
                digits += 1
                if digits > 9 { return }
            }
            guard digits > 0, index + digits < content.length else { return }
            let punctuation = content.character(at: index + digits)
            guard punctuation == 46 || punctuation == 41 else { return }
            markerLength = digits + 1
        } else {
            return
        }

        let afterMarker = index + markerLength
        guard afterMarker < content.length else { return }
        let separator = content.character(at: afterMarker)
        guard separator == 32 || separator == 9 else { return }

        spans.append(MarkdownSyntaxSpan(
            range: NSRange(location: line.range.location + index, length: markerLength),
            kind: .listMarker
        ))

        var cursor = afterMarker
        while cursor < content.length, content.character(at: cursor) == 32 {
            cursor += 1
        }
        if cursor + 2 < content.length,
           content.character(at: cursor) == 91,
           content.character(at: cursor + 2) == 93 {
            let state = content.character(at: cursor + 1)
            if state == 32 || state == 120 || state == 88 {
                spans.append(MarkdownSyntaxSpan(
                    range: NSRange(location: line.range.location + cursor, length: 3),
                    kind: .taskMarker
                ))
            }
        }
    }

    private static func isTableDelimiter(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-") else { return false }
        var cells = 0
        for cell in trimmed.split(separator: "|", omittingEmptySubsequences: true) {
            let cellText = cell.trimmingCharacters(in: .whitespaces)
            guard !cellText.isEmpty else { return false }
            var dashes = 0
            for character in cellText {
                if character == "-" {
                    dashes += 1
                } else if character == ":" {
                    continue
                } else {
                    return false
                }
            }
            guard dashes >= 1 else { return false }
            cells += 1
        }
        return cells >= 1 && trimmed.contains("|")
    }

    // MARK: - Inline

    private static func scanInline(
        source: NSString,
        in line: Line,
        into spans: inout [MarkdownSyntaxSpan]
    ) {
        let content = line.content as NSString
        let start = line.range.location
        let end = line.range.location + content.length
        var index = 0

        while index < content.length {
            let character = content.character(at: index)

            if character == 92 {
                index += 2
                continue
            }

            if character == 96 {
                let run = countRun(content, at: index, character: 96)
                if let closing = findRun(content, from: index + run, character: 96, length: run) {
                    let range = NSRange(location: start + index, length: closing + run - index)
                    spans.append(MarkdownSyntaxSpan(range: range, kind: .codeSpan))
                    index = closing + run
                    continue
                }
                index += run
                continue
            }

            if character == 33 || character == 91 {
                let isImage = character == 33
                let bracket = isImage ? index + 1 : index
                if bracket < content.length, content.character(at: bracket) == 91,
                   let link = findLinkDestination(content, from: bracket) {
                    let range = NSRange(location: start + index, length: link - index)
                    spans.append(MarkdownSyntaxSpan(range: range, kind: isImage ? .image : .link))
                    index = link
                    continue
                }
                index += 1
                continue
            }

            if character == 126 {
                let run = countRun(content, at: index, character: 126)
                if run >= 2,
                   let closing = findRun(content, from: index + 2, character: 126, length: 2) {
                    let range = NSRange(location: start + index, length: closing + 2 - index)
                    spans.append(MarkdownSyntaxSpan(range: range, kind: .strikethrough))
                    index = closing + 2
                    continue
                }
                index += run
                continue
            }

            if character == 42 || character == 95 {
                let run = countRun(content, at: index, character: character)
                let length = run >= 2 ? 2 : 1
                if let closing = findRun(content, from: index + length, character: character, length: length) {
                    let range = NSRange(location: start + index, length: closing + length - index)
                    spans.append(MarkdownSyntaxSpan(range: range, kind: length == 2 ? .strong : .emphasis))
                    index = closing + length
                    continue
                }
                index += run
                continue
            }

            index += 1
        }

        _ = end
    }

    private static func countRun(_ content: NSString, at index: Int, character: unichar) -> Int {
        var cursor = index
        while cursor < content.length, content.character(at: cursor) == character {
            cursor += 1
        }
        return cursor - index
    }

    private static func findRun(
        _ content: NSString,
        from index: Int,
        character: unichar,
        length: Int
    ) -> Int? {
        var cursor = index
        while cursor + length <= content.length {
            if content.character(at: cursor) == 92 {
                cursor += 2
                continue
            }
            if content.character(at: cursor) == character {
                let run = countRun(content, at: cursor, character: character)
                if run == length {
                    return cursor
                }
                cursor += run
                continue
            }
            cursor += 1
        }
        return nil
    }

    private static func findLinkDestination(_ content: NSString, from bracket: Int) -> Int? {
        var depth = 0
        var cursor = bracket
        var closeBracket: Int?
        while cursor < content.length {
            let character = content.character(at: cursor)
            if character == 92 {
                cursor += 2
                continue
            }
            if character == 91 {
                depth += 1
            } else if character == 93 {
                depth -= 1
                if depth == 0 {
                    closeBracket = cursor
                    break
                }
            }
            cursor += 1
        }
        guard let closeBracket,
              closeBracket + 1 < content.length,
              content.character(at: closeBracket + 1) == 40 else { return nil }

        var parenDepth = 0
        cursor = closeBracket + 1
        while cursor < content.length {
            let character = content.character(at: cursor)
            if character == 92 {
                cursor += 2
                continue
            }
            if character == 40 {
                parenDepth += 1
            } else if character == 41 {
                parenDepth -= 1
                if parenDepth == 0 {
                    return cursor + 1
                }
            }
            cursor += 1
        }
        return nil
    }

    // MARK: - Normalisation

    private static func coalesced(_ spans: [MarkdownSyntaxSpan]) -> [MarkdownSyntaxSpan] {
        guard spans.count > 1 else { return spans }
        let sorted = spans.sorted {
            if $0.range.location == $1.range.location {
                return $0.range.length < $1.range.length
            }
            return $0.range.location < $1.range.location
        }
        var result: [MarkdownSyntaxSpan] = []
        for span in sorted {
            if let last = result.last,
               last.kind == span.kind,
               span.range.location <= last.range.location + last.range.length + 1 {
                let end = max(last.range.location + last.range.length,
                              span.range.location + span.range.length)
                result[result.count - 1] = MarkdownSyntaxSpan(
                    range: NSRange(location: last.range.location, length: end - last.range.location),
                    kind: last.kind
                )
            } else {
                result.append(span)
            }
        }
        return result
    }
}
