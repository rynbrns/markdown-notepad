import AppKit
import Foundation
import MarkdownCore

/// Drives the custom find bar and highlights matches inside the TextKit 2
/// editor. Matching itself lives in `FindEngine` so it is testable on Linux.
final class FindController: ObservableObject {
    @Published var query = "" {
        didSet { refresh() }
    }
    @Published var isRegex = false {
        didSet { refresh() }
    }
    @Published var isCaseSensitive = false {
        didSet { refresh() }
    }
    @Published var replaceText = ""
    @Published var isVisible = false {
        didSet {
            if !isVisible { clearHighlights() }
        }
    }
    @Published var showReplace = false

    @Published private(set) var matches: [FindMatch] = []
    @Published private(set) var currentIndex = 0
    @Published private(set) var errorMessage: String?

    private weak var textView: NSTextView?

    /// Called after find backgrounds change so the syntax highlighter can
    /// restore its foreground colours on the same ranges.
    var onHighlightsChanged: (() -> Void)?

    var matchCount: Int { matches.count }

    func attachIfNeeded(to textView: NSTextView?) {
        guard let textView, self.textView !== textView else { return }
        self.textView = textView
        refresh()
    }

    func detach() {
        clearHighlights()
        textView = nil
        matches = []
        currentIndex = 0
    }

    /// Called by the editor delegate after text changes.
    func textDidChange() {
        refresh(selectionOverride: nil)
    }

    // MARK: - Navigation

    func next() {
        guard !matches.isEmpty else { return }
        currentIndex = (currentIndex + 1) % matches.count
        revealCurrentMatch()
    }

    func previous() {
        guard !matches.isEmpty else { return }
        currentIndex = (currentIndex - 1 + matches.count) % matches.count
        revealCurrentMatch()
    }

    func goToLine(_ line: Int) {
        guard let textView else { return }
        let text = textView.string as NSString
        var currentLine = 1
        var location = 0
        while currentLine < line, location < text.length {
            let found = text.range(of: "\n", options: [], range: NSRange(location: location, length: text.length - location))
            guard found.location != NSNotFound else { break }
            location = found.location + 1
            currentLine += 1
        }
        let end = text.range(of: "\n", options: [], range: NSRange(location: location, length: text.length - location))
        let lineRange = NSRange(location: location, length: (end.location == NSNotFound ? text.length : end.location) - location)
        textView.setSelectedRange(lineRange)
        textView.scrollRangeToVisible(lineRange)
        textView.window?.makeFirstResponder(textView)
    }

    // MARK: - Replace

    func replaceCurrent() {
        guard let textView, matches.indices.contains(currentIndex) else { return }
        let match = matches[currentIndex]
        let range = match.range
        guard textView.shouldChangeText(in: range, replacementString: replaceText) else { return }
        textView.replaceCharacters(in: range, with: replaceText)
        textView.didChangeText()
        refresh(selectionOverride: range.location + (replaceText as NSString).length)
    }

    func replaceAll() {
        guard let textView else { return }
        let options = FindOptions(caseSensitive: isCaseSensitive, usesRegularExpression: isRegex)
        let replacement: String
        do {
            replacement = try FindEngine.replacingAll(
                in: textView.string,
                query: query,
                replacement: replaceText,
                options: options
            )
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }
        guard replacement != textView.string else { return }
        let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
        guard textView.shouldChangeText(in: fullRange, replacementString: replacement) else { return }
        textView.replaceCharacters(in: fullRange, with: replacement)
        textView.didChangeText()
        refresh(selectionOverride: 0)
    }

    // MARK: - Matching

    private func refresh(selectionOverride: Int? = nil) {
        guard let textView else {
            matches = []
            currentIndex = 0
            errorMessage = nil
            return
        }
        let options = FindOptions(caseSensitive: isCaseSensitive, usesRegularExpression: isRegex)
        do {
            let found = try FindEngine.matches(of: query, in: textView.string, options: options)
            matches = found
            errorMessage = nil
            let anchor = selectionOverride ?? textView.selectedRange().location
            currentIndex = FindEngine.matchIndex(nearest: anchor, in: found) ?? 0
            applyHighlights()
            if !found.isEmpty, isVisible {
                revealCurrentMatch(selectText: false)
            }
        } catch {
            matches = []
            currentIndex = 0
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            clearHighlights()
        }
    }

    private func revealCurrentMatch(selectText: Bool = true) {
        guard let textView, matches.indices.contains(currentIndex) else { return }
        let range = matches[currentIndex].range
        if selectText {
            textView.setSelectedRange(range)
        }
        textView.scrollRangeToVisible(range)
        textView.showFindIndicator(for: range)
        applyHighlights()
    }

    // MARK: - Highlights

    private func applyHighlights() {
        guard let textView,
              let layoutManager = textView.textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage else { return }

        layoutManager.setRenderingAttributes([:], for: contentStorage.documentRange)
        guard isVisible else { return }

        for (index, match) in matches.enumerated() {
            guard let start = contentStorage.location(
                    contentStorage.documentRange.location,
                    offsetBy: match.range.location
                  ),
                  let end = contentStorage.location(start, offsetBy: match.range.length),
                  let textRange = NSTextRange(location: start, end: end) else { continue }
            let color = index == currentIndex
                ? NSColor.findHighlightColor
                : NSColor.findHighlightColor.withAlphaComponent(0.5)
            layoutManager.setRenderingAttributes([.backgroundColor: color], for: textRange)
            layoutManager.invalidateLayout(for: textRange)
        }
        textView.needsDisplay = true
        onHighlightsChanged?()
    }

    func clearHighlights() {
        guard let textView,
              let layoutManager = textView.textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage else { return }
        layoutManager.setRenderingAttributes([:], for: contentStorage.documentRange)
        onHighlightsChanged?()
    }
}
