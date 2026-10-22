import Foundation

/// Inline Markdown styles that can be toggled around a selection.
public enum MarkdownInlineStyle: Sendable {
    case bold
    case italic
    case strikethrough
    case code
}

/// Block-level Markdown styles that can be toggled on the selected lines.
public enum MarkdownLineStyle: Equatable, Sendable {
    case heading(level: Int)
    case unorderedList
    case orderedList
    case blockquote
    case codeBlock
}

/// The text and selection produced by a formatting command.
///
/// Ranges are UTF-16 indices, matching `NSRange` and `NSTextView`. A command
/// that does not apply returns the input unchanged with `didChange == false`.
public struct MarkdownFormatResult: Equatable, Sendable {
    public let text: String
    public let selection: NSRange
    public let didChange: Bool

    public init(text: String, selection: NSRange, didChange: Bool) {
        self.text = text
        self.selection = selection
        self.didChange = didChange
    }
}

/// Pure text transforms behind the editor's Markdown formatting commands.
///
/// Every transform is a function of `(text, selection)` only, so it is
/// unit-testable without AppKit and can be applied to any text buffer. The
/// caller is responsible for registering undo and for writing the result back
/// into its document.
public enum MarkdownFormatting {
    // MARK: - Inline styles

    public static func toggleInline(
        _ style: MarkdownInlineStyle,
        in text: String,
        selection: NSRange
    ) -> MarkdownFormatResult {
        let ns = text as NSString
        let selected = clamped(selection, length: ns.length)

        let insertionUnit: Int
        let removalUnit: Int
        let markerCharacters: Set<unichar>
        let opening: String
        let closing: String

        switch style {
        case .bold:
            insertionUnit = 2
            removalUnit = 2
            markerCharacters = [42, 95]
            opening = "**"
            closing = "**"
        case .italic:
            insertionUnit = 1
            removalUnit = 1
            markerCharacters = [42, 95]
            opening = "*"
            closing = "*"
        case .strikethrough:
            insertionUnit = 2
            removalUnit = 2
            markerCharacters = [126]
            opening = "~~"
            closing = "~~"
        case .code:
            insertionUnit = 1
            removalUnit = 1
            markerCharacters = [96]
            opening = "`"
            closing = "`"
        }

        let selectedText = ns.substring(with: selected)

        if selected.length > 0,
           let unwrapped = unwrapSelection(
               selectedText,
               style: style,
               markerCharacters: markerCharacters,
               removalUnit: removalUnit
           ) {
            let replacement = ns.replacingCharacters(in: selected, with: unwrapped.text)
            return MarkdownFormatResult(
                text: replacement,
                selection: NSRange(location: selected.location, length: unwrapped.text.utf16.count),
                didChange: replacement != text
            )
        }

        if selected.length > 0,
           let outside = markerRun(endingAt: selected.location, in: ns, characters: markerCharacters),
           let after = markerRun(startingAt: NSMaxRange(selected), in: ns, characters: markerCharacters),
           outside.character == after.character,
           shouldRemove(run: outside.length, style: style),
           shouldRemove(run: after.length, style: style) {
            let removed = style == .code
                ? min(outside.length, after.length)
                : removalUnit
            let range = NSRange(
                location: selected.location - removed,
                length: selected.length + removed * 2
            )
            let replacement = ns.replacingCharacters(in: range, with: selectedText)
            return MarkdownFormatResult(
                text: replacement,
                selection: NSRange(location: selected.location - removed, length: selected.length),
                didChange: replacement != text
            )
        }

        if selected.length == 0,
           let before = markerRun(endingAt: selected.location, in: ns, characters: markerCharacters),
           let after = markerRun(startingAt: selected.location, in: ns, characters: markerCharacters),
           before.character == after.character,
           shouldRemove(run: before.length, style: style),
           shouldRemove(run: after.length, style: style) {
            let removed = style == .code
                ? min(before.length, after.length)
                : removalUnit
            let range = NSRange(location: selected.location - removed, length: removed * 2)
            let replacement = ns.replacingCharacters(in: range, with: "")
            return MarkdownFormatResult(
                text: replacement,
                selection: NSRange(location: selected.location - removed, length: 0),
                didChange: replacement != text
            )
        }

        let replacement = ns.replacingCharacters(in: selected, with: opening + selectedText + closing)
        return MarkdownFormatResult(
            text: replacement,
            selection: NSRange(location: selected.location + insertionUnit, length: selected.length),
            didChange: replacement != text
        )
    }

    // MARK: - Link

    public static func insertLink(
        in text: String,
        selection: NSRange,
        url: String?
    ) -> MarkdownFormatResult {
        let ns = text as NSString
        let selected = clamped(selection, length: ns.length)
        let selectedText = ns.substring(with: selected)
        let supplied = url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let destination = supplied.isEmpty ? "url" : supplied

        if selected.length == 0 {
            let label = "text"
            let insertion = "[\(label)](\(destination))"
            let replacement = ns.replacingCharacters(in: selected, with: insertion)
            return MarkdownFormatResult(
                text: replacement,
                selection: NSRange(location: selected.location + 1, length: label.utf16.count),
                didChange: replacement != text
            )
        }

        let insertion = "[\(selectedText)](\(destination))"
        let replacement = ns.replacingCharacters(in: selected, with: insertion)
        let selectionAfter: NSRange
        if supplied.isEmpty {
            let urlStart = selected.location + 1 + selectedText.utf16.count + 2
            selectionAfter = NSRange(location: urlStart, length: destination.utf16.count)
        } else {
            selectionAfter = NSRange(location: selected.location + insertion.utf16.count, length: 0)
        }
        return MarkdownFormatResult(
            text: replacement,
            selection: selectionAfter,
            didChange: replacement != text
        )
    }

    // MARK: - Line styles

    public static func toggleLine(
        _ style: MarkdownLineStyle,
        in text: String,
        selection: NSRange
    ) -> MarkdownFormatResult {
        let ns = text as NSString
        let selected = clamped(selection, length: ns.length)
        let lines = selectedLines(in: ns, selection: selected)

        switch style {
        case .heading(let level):
            return toggleHeading(level: min(max(level, 1), 6), lines: lines, text: text, selection: selected)
        case .unorderedList:
            return toggleUnorderedList(lines: lines, text: text, selection: selected)
        case .orderedList:
            return toggleOrderedList(lines: lines, in: ns, text: text, selection: selected)
        case .blockquote:
            return toggleBlockquote(lines: lines, text: text, selection: selected)
        case .codeBlock:
            return toggleCodeBlock(lines: lines, in: ns, text: text, selection: selected)
        }
    }

    // MARK: - List nesting

    /// Indents or outdents selected list items by two spaces.
    ///
    /// Returns `nil` when the selection is not entirely made of list items,
    /// which lets the caller fall back to the text view's normal Tab handling.
    /// A non-nil result with `didChange == false` means Tab was consumed but
    /// no text changed (for example, outdenting at column zero).
    public static func adjustListIndent(
        in text: String,
        selection: NSRange,
        outdent: Bool
    ) -> MarkdownFormatResult? {
        let ns = text as NSString
        let selected = clamped(selection, length: ns.length)
        let lines = selectedLines(in: ns, selection: selected)
        let nonBlank = lines.filter { !isBlank($0.content) }
        guard !nonBlank.isEmpty else { return nil }
        guard nonBlank.allSatisfy({ listParts($0.content) != nil }) else { return nil }

        var replacements: [LineReplacement] = []
        for line in lines where !isBlank(line.content) {
            if outdent {
                let indent = leadingWhitespace(line.content)
                guard !indent.isEmpty else { continue }
                var removed = 0
                var updatedIndent = indent
                if updatedIndent.hasPrefix("\t") {
                    updatedIndent.removeFirst()
                    removed = 1
                } else {
                    while removed < 2, updatedIndent.hasPrefix(" ") {
                        updatedIndent.removeFirst()
                        removed += 1
                    }
                }
                guard removed > 0 else { continue }
                let body = String(line.content.dropFirst(indent.count))
                replacements.append(LineReplacement(
                    range: line.contentRange,
                    text: updatedIndent + body,
                    leadingInsertion: updatedIndent.utf16.count
                ))
            } else {
                let indent = leadingWhitespace(line.content)
                let body = String(line.content.dropFirst(indent.count))
                replacements.append(LineReplacement(
                    range: line.contentRange,
                    text: indent + "  " + body,
                    leadingInsertion: indent.utf16.count + 2
                ))
            }
        }

        guard !replacements.isEmpty else {
            return MarkdownFormatResult(text: text, selection: selected, didChange: false)
        }
        return applying(replacements, to: text, selection: selected)
    }

    // MARK: - Heading

    private static func toggleHeading(
        level: Int,
        lines: [SelectedLine],
        text: String,
        selection: NSRange
    ) -> MarkdownFormatResult {
        let nonBlank = lines.filter { !isBlank($0.content) }
        let allAtLevel = !nonBlank.isEmpty && nonBlank.allSatisfy {
            headingParts($0.content)?.level == level
        }
        let marker = String(repeating: "#", count: level) + " "

        var replacements: [LineReplacement] = []
        for line in lines {
            if isBlank(line.content) {
                guard lines.count == 1 else { continue }
                let indent = leadingWhitespace(line.content)
                replacements.append(LineReplacement(
                    range: line.contentRange,
                    text: indent + marker,
                    leadingInsertion: indent.utf16.count + marker.utf16.count
                ))
                continue
            }

            let parts = headingParts(line.content)
            let indent = parts?.indent ?? leadingWhitespace(line.content)
            let body = parts?.body ?? String(line.content.dropFirst(indent.count))
            if allAtLevel {
                replacements.append(LineReplacement(
                    range: line.contentRange,
                    text: indent + body,
                    leadingInsertion: indent.utf16.count
                ))
            } else {
                replacements.append(LineReplacement(
                    range: line.contentRange,
                    text: indent + marker + body,
                    leadingInsertion: indent.utf16.count + marker.utf16.count
                ))
            }
        }

        return applying(replacements, to: text, selection: selection)
    }

    // MARK: - Lists

    private static func toggleUnorderedList(
        lines: [SelectedLine],
        text: String,
        selection: NSRange
    ) -> MarkdownFormatResult {
        let nonBlank = lines.filter { !isBlank($0.content) }
        let allUnordered = !nonBlank.isEmpty && nonBlank.allSatisfy {
            listParts($0.content)?.kind == .unordered
        }
        let marker = "- "

        var replacements: [LineReplacement] = []
        for line in lines {
            if isBlank(line.content) {
                guard lines.count == 1 else { continue }
                let indent = leadingWhitespace(line.content)
                replacements.append(LineReplacement(
                    range: line.contentRange,
                    text: indent + marker,
                    leadingInsertion: indent.utf16.count + marker.utf16.count
                ))
                continue
            }

            let parts = listParts(line.content)
            let indent = parts?.indent ?? leadingWhitespace(line.content)
            let body = parts?.body ?? String(line.content.dropFirst(indent.count))
            if allUnordered {
                replacements.append(LineReplacement(
                    range: line.contentRange,
                    text: indent + body,
                    leadingInsertion: indent.utf16.count
                ))
            } else {
                replacements.append(LineReplacement(
                    range: line.contentRange,
                    text: indent + marker + body,
                    leadingInsertion: indent.utf16.count + marker.utf16.count
                ))
            }
        }

        return applying(replacements, to: text, selection: selection)
    }

    private static func toggleOrderedList(
        lines: [SelectedLine],
        in ns: NSString,
        text: String,
        selection: NSRange
    ) -> MarkdownFormatResult {
        let nonBlank = lines.filter { !isBlank($0.content) }
        let allOrdered = !nonBlank.isEmpty && nonBlank.allSatisfy {
            listParts($0.content)?.kind == .ordered
        }
        var number = startingOrderedNumber(for: nonBlank.first, in: ns)

        var replacements: [LineReplacement] = []
        for line in lines {
            if isBlank(line.content) {
                guard lines.count == 1 else { continue }
                let indent = leadingWhitespace(line.content)
                let marker = "1. "
                replacements.append(LineReplacement(
                    range: line.contentRange,
                    text: indent + marker,
                    leadingInsertion: indent.utf16.count + marker.utf16.count
                ))
                continue
            }

            let parts = listParts(line.content)
            let indent = parts?.indent ?? leadingWhitespace(line.content)
            let body = parts?.body ?? String(line.content.dropFirst(indent.count))
            if allOrdered {
                replacements.append(LineReplacement(
                    range: line.contentRange,
                    text: indent + body,
                    leadingInsertion: indent.utf16.count
                ))
            } else {
                let marker = "\(number). "
                number += 1
                replacements.append(LineReplacement(
                    range: line.contentRange,
                    text: indent + marker + body,
                    leadingInsertion: indent.utf16.count + marker.utf16.count
                ))
            }
        }

        return applying(replacements, to: text, selection: selection)
    }

    private static func startingOrderedNumber(
        for first: SelectedLine?,
        in ns: NSString
    ) -> Int {
        guard let first, first.contentRange.location > 0 else { return 1 }
        let previousRange = ns.lineRange(for: NSRange(location: first.contentRange.location - 1, length: 0))
        let previousContent = content(of: previousRange, in: ns)
        guard let previous = listParts(previousContent),
              previous.kind == .ordered,
              previous.indent == leadingWhitespace(first.content),
              let number = previous.number else { return 1 }
        return number + 1
    }

    // MARK: - Blockquote

    private static func toggleBlockquote(
        lines: [SelectedLine],
        text: String,
        selection: NSRange
    ) -> MarkdownFormatResult {
        let nonBlank = lines.filter { !isBlank($0.content) }
        let allQuoted = !nonBlank.isEmpty && nonBlank.allSatisfy { quoteParts($0.content) != nil }
        let marker = "> "

        var replacements: [LineReplacement] = []
        for line in lines {
            if isBlank(line.content) {
                guard lines.count == 1 else { continue }
                let indent = leadingWhitespace(line.content)
                replacements.append(LineReplacement(
                    range: line.contentRange,
                    text: indent + marker,
                    leadingInsertion: indent.utf16.count + marker.utf16.count
                ))
                continue
            }

            let parts = quoteParts(line.content)
            let indent = parts?.indent ?? leadingWhitespace(line.content)
            let body = parts?.body ?? String(line.content.dropFirst(indent.count))
            if allQuoted {
                replacements.append(LineReplacement(
                    range: line.contentRange,
                    text: indent + body,
                    leadingInsertion: indent.utf16.count
                ))
            } else {
                replacements.append(LineReplacement(
                    range: line.contentRange,
                    text: indent + marker + body,
                    leadingInsertion: indent.utf16.count + marker.utf16.count
                ))
            }
        }

        return applying(replacements, to: text, selection: selection)
    }

    // MARK: - Code block

    private static func toggleCodeBlock(
        lines: [SelectedLine],
        in ns: NSString,
        text: String,
        selection: NSRange
    ) -> MarkdownFormatResult {
        guard let first = lines.first, let last = lines.last else {
            return MarkdownFormatResult(text: text, selection: selection, didChange: false)
        }

        if lines.count >= 2,
           isFenceOpening(first.content),
           isFenceClosing(last.content) {
            let replacements = [
                LineReplacement(range: first.fullRange, text: ""),
                LineReplacement(range: last.fullRange, text: "")
            ]
            return applying(replacements, to: text, selection: selection)
        }

        let start = first.contentRange.location
        let end = NSMaxRange(last.contentRange)
        let previousFence = start > 0
            ? ns.lineRange(for: NSRange(location: start - 1, length: 0))
            : nil
        let followingLocation = NSMaxRange(last.fullRange)
        let followingFence = followingLocation < ns.length
            ? ns.lineRange(for: NSRange(location: followingLocation, length: 0))
            : nil

        if let previousFence,
           let followingFence,
           isFenceOpening(content(of: previousFence, in: ns)),
           isFenceClosing(content(of: followingFence, in: ns)) {
            let replacements = [
                LineReplacement(range: previousFence, text: ""),
                LineReplacement(range: followingFence, text: "")
            ]
            return applying(replacements, to: text, selection: selection)
        }

        let blockRange = NSRange(location: start, length: end - start)
        let blockContent = ns.substring(with: blockRange)
        if blockContent.isEmpty {
            let replacement = ns.replacingCharacters(in: blockRange, with: "```\n\n```")
            return MarkdownFormatResult(
                text: replacement,
                selection: NSRange(location: start + 4, length: 0),
                didChange: replacement != text
            )
        }

        let replacements = [
            LineReplacement(range: NSRange(location: start, length: 0), text: "```\n", leadingInsertion: 4),
            LineReplacement(range: NSRange(location: end, length: 0), text: "\n```", leadingInsertion: 0)
        ]
        return applying(replacements, to: text, selection: selection)
    }

    // MARK: - Selection markers

    private struct MarkerRun {
        let length: Int
        let character: unichar
    }

    private static func markerRun(
        endingAt index: Int,
        in ns: NSString,
        characters: Set<unichar>
    ) -> MarkerRun? {
        guard index > 0, index <= ns.length else { return nil }
        let character = ns.character(at: index - 1)
        guard characters.contains(character) else { return nil }
        var cursor = index - 1
        while cursor > 0, ns.character(at: cursor - 1) == character {
            cursor -= 1
        }
        return MarkerRun(length: index - cursor, character: character)
    }

    private static func markerRun(
        startingAt index: Int,
        in ns: NSString,
        characters: Set<unichar>
    ) -> MarkerRun? {
        guard index >= 0, index < ns.length else { return nil }
        let character = ns.character(at: index)
        guard characters.contains(character) else { return nil }
        var cursor = index
        while cursor < ns.length, ns.character(at: cursor) == character {
            cursor += 1
        }
        return MarkerRun(length: cursor - index, character: character)
    }

    private static func shouldRemove(run: Int, style: MarkdownInlineStyle) -> Bool {
        switch style {
        case .bold, .strikethrough:
            return run >= 2
        case .italic:
            return run % 2 == 1
        case .code:
            return run >= 1
        }
    }

    private static func unwrapSelection(
        _ selected: String,
        style: MarkdownInlineStyle,
        markerCharacters: Set<unichar>,
        removalUnit: Int
    ) -> (text: String, leading: Int)? {
        let ns = selected as NSString
        guard ns.length >= removalUnit * 2 else { return nil }
        guard markerCharacters.contains(ns.character(at: 0)) else { return nil }
        let character = ns.character(at: 0)
        guard ns.character(at: ns.length - 1) == character else { return nil }

        let leadingRun = markerRun(startingAt: 0, in: ns, characters: markerCharacters)
        let trailingRun = markerRun(endingAt: ns.length, in: ns, characters: markerCharacters)
        guard let leadingRun, let trailingRun,
              leadingRun.character == trailingRun.character,
              shouldRemove(run: leadingRun.length, style: style),
              shouldRemove(run: trailingRun.length, style: style) else { return nil }

        let removed = style == .code
            ? min(leadingRun.length, trailingRun.length)
            : removalUnit
        guard ns.length >= removed * 2 else { return nil }
        let inner = ns.substring(with: NSRange(location: removed, length: ns.length - removed * 2))
        return (inner, removed)
    }

    // MARK: - Line parsing

    private struct SelectedLine {
        let contentRange: NSRange
        let fullRange: NSRange
        let content: String
    }

    private struct HeadingParts {
        let indent: String
        let level: Int
        let body: String
    }

    private struct ListParts {
        enum Kind {
            case unordered
            case ordered
        }
        let indent: String
        let kind: Kind
        let number: Int?
        let body: String
    }

    private struct QuoteParts {
        let indent: String
        let body: String
    }

    private static func selectedLines(in ns: NSString, selection: NSRange) -> [SelectedLine] {
        let length = ns.length
        let start = min(max(selection.location, 0), length)
        let rawEnd = selection.length > 0 ? NSMaxRange(selection) : start
        let end = min(max(rawEnd, start), length)
        let lastProbe = end > start ? end - 1 : start

        var lines: [SelectedLine] = []
        var location = ns.lineRange(for: NSRange(location: start, length: 0)).location
        var guardCount = 0
        repeat {
            let full = ns.lineRange(for: NSRange(location: location, length: 0))
            lines.append(SelectedLine(
                contentRange: contentRange(of: full, in: ns),
                fullRange: full,
                content: content(of: full, in: ns)
            ))
            let next = full.location + full.length
            if next <= location { break }
            location = next
            guardCount += 1
        } while location <= lastProbe && guardCount < 100_000

        return lines
    }

    private static func contentRange(of fullRange: NSRange, in ns: NSString) -> NSRange {
        var end = fullRange.location + fullRange.length
        while end > fullRange.location {
            let character = ns.character(at: end - 1)
            guard character == 10 || character == 13 else { break }
            end -= 1
        }
        return NSRange(location: fullRange.location, length: end - fullRange.location)
    }

    private static func content(of fullRange: NSRange, in ns: NSString) -> String {
        ns.substring(with: contentRange(of: fullRange, in: ns))
    }

    private static func leadingWhitespace(_ content: String) -> String {
        var indent = ""
        for character in content {
            guard character == " " || character == "\t" else { break }
            indent.append(character)
        }
        return indent
    }

    private static func isBlank(_ content: String) -> Bool {
        content.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func headingParts(_ content: String) -> HeadingParts? {
        let indent = leadingWhitespace(content)
        let body = content.dropFirst(indent.count)
        var level = 0
        var index = body.startIndex
        while index < body.endIndex, body[index] == "#", level < 7 {
            level += 1
            index = body.index(after: index)
        }
        guard level >= 1, level <= 6 else { return nil }
        if index < body.endIndex {
            guard body[index] == " " || body[index] == "\t" else { return nil }
        }
        var rest = body[index...]
        while let first = rest.first, first == " " || first == "\t" {
            rest = rest.dropFirst()
        }
        return HeadingParts(indent: indent, level: level, body: String(rest))
    }

    private static func listParts(_ content: String) -> ListParts? {
        let indent = leadingWhitespace(content)
        let body = content.dropFirst(indent.count)
        guard let first = body.first else { return nil }

        if first == "-" || first == "*" || first == "+" {
            let afterMarker = body.dropFirst()
            guard let separator = afterMarker.first, separator == " " || separator == "\t" else { return nil }
            return ListParts(indent: indent, kind: .unordered, number: nil, body: trimmedBody(afterMarker))
        }

        var index = body.startIndex
        var digits = 0
        while index < body.endIndex, body[index].isASCII, body[index].isNumber {
            digits += 1
            index = body.index(after: index)
            if digits > 9 { return nil }
        }
        guard digits > 0, index < body.endIndex else { return nil }
        let punctuation = body[index]
        guard punctuation == "." || punctuation == ")" else { return nil }
        let afterPunctuation = body.index(after: index)
        guard afterPunctuation < body.endIndex else { return nil }
        let separator = body[afterPunctuation]
        guard separator == " " || separator == "\t" else { return nil }
        guard let number = Int(body.prefix(digits)) else { return nil }
        return ListParts(
            indent: indent,
            kind: .ordered,
            number: number,
            body: trimmedBody(body[afterPunctuation...])
        )
    }

    private static func trimmedBody<S: StringProtocol>(_ body: S) -> String {
        var rest = body[...]
        while let first = rest.first, first == " " || first == "\t" {
            rest = rest.dropFirst()
        }
        return String(rest)
    }

    private static func quoteParts(_ content: String) -> QuoteParts? {
        let indent = leadingWhitespace(content)
        let body = content.dropFirst(indent.count)
        guard body.first == ">" else { return nil }
        let afterMarker = body.dropFirst()
        var rest = afterMarker[...]
        if let first = rest.first, first == " " {
            rest = rest.dropFirst()
        }
        return QuoteParts(indent: indent, body: String(rest))
    }

    private static func isFenceOpening(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        return trimmed.prefix(while: { $0 == "`" }).count >= 3
    }

    private static func isFenceClosing(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        let run = trimmed.prefix(while: { $0 == "`" }).count
        guard run >= 3 else { return false }
        return trimmed.dropFirst(run).allSatisfy { $0 == " " || $0 == "\t" }
    }

    // MARK: - Applying edits

    private struct LineReplacement {
        let range: NSRange
        let text: String
        let leadingInsertion: Int

        init(range: NSRange, text: String, leadingInsertion: Int = 0) {
            self.range = range
            self.text = text
            self.leadingInsertion = leadingInsertion
        }
    }

    private static func applying(
        _ replacements: [LineReplacement],
        to text: String,
        selection: NSRange
    ) -> MarkdownFormatResult {
        let ns = text as NSString
        let ordered = replacements.enumerated().sorted { lhs, rhs in
            if lhs.element.range.location == rhs.element.range.location {
                return lhs.offset < rhs.offset
            }
            return lhs.element.range.location < rhs.element.range.location
        }.map(\.element)

        var output = ""
        var cursor = 0
        var table: [(oldStart: Int, oldLength: Int, newStart: Int, newLength: Int, leading: Int)] = []
        var delta = 0

        for replacement in ordered {
            if replacement.range.location > cursor {
                output += ns.substring(with: NSRange(
                    location: cursor,
                    length: replacement.range.location - cursor
                ))
            }
            let newStart = replacement.range.location + delta
            table.append((
                replacement.range.location,
                replacement.range.length,
                newStart,
                replacement.text.utf16.count,
                replacement.leadingInsertion
            ))
            output += replacement.text
            delta += replacement.text.utf16.count - replacement.range.length
            cursor = NSMaxRange(replacement.range)
        }
        if cursor < ns.length {
            output += ns.substring(from: cursor)
        }

        func map(_ position: Int, caret: Bool) -> Int {
            var shift = 0
            for entry in table {
                let oldEnd = entry.oldStart + entry.oldLength
                if position < entry.oldStart { return position + shift }
                if position <= oldEnd {
                    let offset = position - entry.oldStart
                    if offset == 0 {
                        let shiftIntoPrefix = caret || entry.oldLength == 0
                        return entry.newStart + (shiftIntoPrefix ? entry.leading : 0)
                    }
                    let mapped = offset + (entry.newLength - entry.oldLength)
                    return entry.newStart + max(0, min(mapped, entry.newLength))
                }
                shift += entry.newLength - entry.oldLength
            }
            return position + shift
        }

        let caret = selection.length == 0
        let start = map(selection.location, caret: caret)
        let end = map(NSMaxRange(selection), caret: caret)
        return MarkdownFormatResult(
            text: output,
            selection: NSRange(location: start, length: max(0, end - start)),
            didChange: output != text
        )
    }

    private static func clamped(_ range: NSRange, length: Int) -> NSRange {
        let location = min(max(range.location, 0), length)
        let upper = min(max(NSMaxRange(range), location), length)
        return NSRange(location: location, length: upper - location)
    }
}
