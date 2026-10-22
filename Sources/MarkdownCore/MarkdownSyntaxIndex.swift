import Foundation

/// The result of feeding new text to ``MarkdownSyntaxIndex``.
public struct MarkdownSyntaxUpdate: Sendable {
    /// Spans that were (re)computed by this update.
    public let spans: [MarkdownSyntaxSpan]
    /// The UTF-16 range those spans replace. Colours inside this range must be
    /// cleared before the new spans are applied; outside it nothing changed.
    public let affectedRange: NSRange
    /// True when the whole document was rescanned.
    public let didRebuildEntireDocument: Bool

    public init(spans: [MarkdownSyntaxSpan], affectedRange: NSRange, didRebuildEntireDocument: Bool) {
        self.spans = spans
        self.affectedRange = affectedRange
        self.didRebuildEntireDocument = didRebuildEntireDocument
    }

    public static let unchanged = MarkdownSyntaxUpdate(
        spans: [],
        affectedRange: NSRange(location: 0, length: 0),
        didRebuildEntireDocument: false
    )
}

/// Line-oriented incremental cache for ``MarkdownSyntax``.
///
/// A full scan of a 1 MB document is hundreds of milliseconds in a debug
/// build. Editors need better than that per keystroke, so this type remembers
/// the scanned spans and the fence/table state for every line and only rescans
/// from the edited line onwards. When an edit does not change the line count or
/// later scanner state, the untouched suffix is reused with an O(1) splice.
///
/// The cache is not thread-safe; the highlighter owns one instance on a single
/// serial queue.
public struct MarkdownSyntaxIndex: Sendable {
    private var text = ""
    private var contentLength = 0
    private var lines: [MarkdownSyntax.ScannedLine] = []
    private var cacheIsValid = false

    public init() {}

    /// All current spans, coalesced. Computed on demand; used by tests and the
    /// one-shot `MarkdownSyntax.spans(in:)` entry point.
    public func allSpans() -> [MarkdownSyntaxSpan] {
        MarkdownSyntax.coalesced(lines.flatMap(\.spans))
    }

    /// Spans that intersect `range`, without coalescing. Used to repaint the
    /// visible editor region after find highlights change.
    public func spans(in range: NSRange) -> [MarkdownSyntaxSpan] {
        guard range.length > 0, !lines.isEmpty else { return [] }
        let end = NSMaxRange(range)

        var low = 0
        var high = lines.count - 1
        var first = lines.count
        while low <= high {
            let middle = (low + high) / 2
            let line = lines[middle]
            if line.start + line.fullLength > range.location {
                first = middle
                high = middle - 1
            } else {
                low = middle + 1
            }
        }

        var result: [MarkdownSyntaxSpan] = []
        var index = first
        while index < lines.count, lines[index].start < end {
            for span in lines[index].spans where NSIntersectionRange(span.range, range).length > 0 {
                result.append(span)
            }
            index += 1
        }
        return result
    }

    /// Rebuilds the cache for `newText` and returns all spans.
    @discardableResult
    public mutating func rebuild(with newText: String) -> [MarkdownSyntaxSpan] {
        let source = newText as NSString
        text = newText
        contentLength = source.length

        var scannedLines: [MarkdownSyntax.ScannedLine] = []
        var state = MarkdownSyntax.ScanState.initial
        var previousContent: String?
        var location = 0

        while location < source.length {
            let (line, after) = MarkdownSyntax.readLine(source, at: location)
            var lineState = state
            let result = MarkdownSyntax.scanLine(
                start: line.start,
                content: line.content,
                fullLength: line.fullLength,
                state: &lineState,
                previousContent: previousContent
            )
            let scanned = MarkdownSyntax.ScannedLine(
                start: line.start,
                fullLength: line.fullLength,
                content: line.content,
                spans: result.spans,
                stateAfter: lineState
            )
            if result.headerForPrevious, let previous = scannedLines.last {
                scannedLines[scannedLines.count - 1].spans.removeAll { span in
                    if case .tableHeader = span.kind { return true }
                    return false
                }
                scannedLines[scannedLines.count - 1].spans.append(
                    MarkdownSyntaxSpan(range: previous.fullRange, kind: .tableHeader)
                )
            }
            scannedLines.append(scanned)
            state = lineState
            previousContent = line.content
            location = after
        }

        lines = scannedLines
        cacheIsValid = true
        return allSpans()
    }

    /// Applies an edit.
    ///
    /// - Parameters:
    ///   - newText: The complete new document text.
    ///   - changedOffsetHint: UTF-16 offset near the edit (usually the cursor).
    ///     A wrong hint only costs extra work; it cannot produce stale spans,
    ///     because the cache is verified against the text before reuse and a
    ///     failed verification falls back to a full rebuild.
    public mutating func update(text newText: String, changedOffsetHint: Int?) -> MarkdownSyntaxUpdate {
        if cacheIsValid, newText == text {
            return .unchanged
        }
        guard cacheIsValid, !lines.isEmpty, !newText.isEmpty, let changedOffsetHint else {
            let spans = rebuild(with: newText)
            return MarkdownSyntaxUpdate(
                spans: spans,
                affectedRange: NSRange(location: 0, length: (newText as NSString).length),
                didRebuildEntireDocument: true
            )
        }

        let source = newText as NSString
        guard let rescanIndex = rescanStart(for: source, hint: changedOffsetHint) else {
            let spans = rebuild(with: newText)
            return MarkdownSyntaxUpdate(
                spans: spans,
                affectedRange: NSRange(location: 0, length: source.length),
                didRebuildEntireDocument: true
            )
        }

        let baseStart: Int
        if rescanIndex < lines.count {
            baseStart = lines[rescanIndex].start
        } else {
            baseStart = contentLength
        }
        let affectedStart = rescanIndex > 0 ? lines[rescanIndex - 1].start : 0

        var newLines = Array(lines[0..<rescanIndex])
        if rescanIndex > 0 {
            newLines[newLines.count - 1].spans.removeAll { span in
                if case .tableHeader = span.kind { return true }
                return false
            }
        }
        var state = rescanIndex > 0 ? lines[rescanIndex - 1].stateAfter : .initial
        var previousContent = rescanIndex > 0 ? lines[rescanIndex - 1].content : nil
        var location = baseStart
        var oldIndex = rescanIndex
        var affectedEnd = source.length

        while location < source.length {
            let (line, after) = MarkdownSyntax.readLine(source, at: location)
            let startDelta = oldIndex < lines.count ? location - lines[oldIndex].start : 0
            let canReuse = oldIndex > rescanIndex
                && startDelta == 0
                && oldIndex < lines.count
                && line.content == lines[oldIndex].content
                && state == lines[oldIndex].stateAfter
                && !reuseWouldNeedRetroactiveHeader(line: line, previous: newLines.last)

            if canReuse {
                newLines.append(contentsOf: lines[oldIndex...])
                affectedEnd = location
                break
            }

            var lineState = state
            let result = MarkdownSyntax.scanLine(
                start: line.start,
                content: line.content,
                fullLength: line.fullLength,
                state: &lineState,
                previousContent: previousContent
            )
            if result.headerForPrevious, let previous = newLines.last {
                newLines[newLines.count - 1].spans.removeAll { span in
                    if case .tableHeader = span.kind { return true }
                    return false
                }
                newLines[newLines.count - 1].spans.append(
                    MarkdownSyntaxSpan(range: previous.fullRange, kind: .tableHeader)
                )
            }
            newLines.append(MarkdownSyntax.ScannedLine(
                start: line.start,
                fullLength: line.fullLength,
                content: line.content,
                spans: result.spans,
                stateAfter: lineState
            ))
            state = lineState
            previousContent = line.content
            location = after
            oldIndex += 1
        }

        text = newText
        contentLength = source.length
        lines = newLines
        cacheIsValid = true

        let startIndex = max(0, rescanIndex - 1)
        let spans = newLines[startIndex...].flatMap { line in
            line.spans.filter { NSMaxRange($0.range) <= affectedEnd }
        }
        return MarkdownSyntaxUpdate(
            spans: spans,
            affectedRange: NSRange(location: affectedStart, length: max(0, affectedEnd - affectedStart)),
            didRebuildEntireDocument: false
        )
    }

    // MARK: - Verification

    /// Returns the line index to start rescanning from, or `nil` when the hint
    /// cannot be trusted and the document must be rebuilt.
    private func rescanStart(for source: NSString, hint: Int) -> Int? {
        let clamped = min(max(hint, 0), max(contentLength - 1, 0))
        var candidate = lineIndex(forOffset: clamped)
        if candidate >= lines.count {
            candidate = lines.count - 1
        }

        var verified = candidate
        var attempts = 0
        while verified >= 0 {
            if lineContent(source, at: lines[verified].start) == lines[verified].content {
                return verified + 1
            }
            verified -= 1
            attempts += 1
            if attempts > 64 {
                return nil
            }
        }
        return nil
    }

    private func lineIndex(forOffset offset: Int) -> Int {
        var low = 0
        var high = lines.count - 1
        var result = 0
        while low <= high {
            let middle = (low + high) / 2
            if lines[middle].start <= offset {
                result = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return result
    }

    private func lineContent(_ source: NSString, at location: Int) -> String? {
        guard location >= 0, location < source.length else { return nil }
        let full = source.lineRange(for: NSRange(location: location, length: 0))
        var end = full.location + full.length
        while end > full.location {
            let character = source.character(at: end - 1)
            guard character == 10 || character == 13 else { break }
            end -= 1
        }
        return source.substring(with: NSRange(location: full.location, length: end - full.location))
    }

    /// A reused line that is a table delimiter needs its header flag applied to
    /// the line we just rescanned, so that case must not take the fast path.
    private func reuseWouldNeedRetroactiveHeader(
        line: MarkdownSyntax.ScannedLine,
        previous: MarkdownSyntax.ScannedLine?
    ) -> Bool {
        guard let previous else { return false }
        return MarkdownSyntax.isTableDelimiter(line.content) && previous.content.contains("|")
    }
}
