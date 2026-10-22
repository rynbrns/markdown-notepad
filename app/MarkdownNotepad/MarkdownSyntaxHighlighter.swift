import AppKit
import MarkdownCore

/// Applies semantic styling to the TextKit 2 editor without changing the
/// document's characters.
///
/// In source mode (Plain Text and Panels) it applies semantic colours as
/// rendering attributes, parsed off the main thread in a line-oriented
/// incremental index, so the find bar's background highlights stay composable.
///
/// In rich mode (WYSIWYG) it writes presentation-only text attributes: bold,
/// italic, headings, inline code, and near-zero-width transparent Markdown
/// markers. Characters are never inserted or removed, so the saved Markdown is
/// byte-identical and selection ranges stay valid across mode switches.
final class MarkdownSyntaxHighlighter {
    enum PresentationMode {
        case source
        case rich
    }

    private weak var textView: NSTextView?

    private let parseQueue = DispatchQueue(
        label: "com.ryanpaperclip.markdownnotepad.highlighter",
        qos: .userInitiated
    )
    private var index = MarkdownSyntaxIndex()
    private var debounceWork: DispatchWorkItem?
    private var richWork: DispatchWorkItem?
    private var generation = 0
    private var richGeneration = 0

    private var mode: PresentationMode = .source
    private var fontSize: CGFloat = 14
    private var renderedMode: PresentationMode = .source

    private let debounceInterval: TimeInterval = 0.03
    private let fullPassDelay: TimeInterval = 0.06
    private let chunkSize = 400

    func attach(to textView: NSTextView) {
        self.textView = textView
        if mode == .rich {
            applyRichNow(to: textView, clearRenderings: true)
        } else {
            rehighlight(textView.string, hint: nil)
        }
    }

    func detach() {
        debounceWork?.cancel()
        debounceWork = nil
        richWork?.cancel()
        richWork = nil
        textView = nil
        generation += 1
        richGeneration += 1
    }

    /// Sets the presentation mode and base font size. A change re-renders the
    /// current document immediately so the switch feels instantaneous.
    func configure(mode: PresentationMode, fontSize: CGFloat) {
        let changed = mode != self.mode || fontSize != self.fontSize
        self.mode = mode
        self.fontSize = fontSize
        guard changed else { return }
        guard let textView else { return }
        debounceWork?.cancel()
        richWork?.cancel()
        if mode == .rich {
            applyRichNow(to: textView, clearRenderings: true)
        } else {
            applySourceNow(to: textView)
        }
    }

    /// Called by the editor delegate after every text change. `hint` is the
    /// current selection offset, which lets the index rescan only the edited
    /// tail instead of the whole document.
    func textDidChange(_ text: String, hint: Int?) {
        if mode == .rich {
            rehighlightRich(text)
        } else {
            rehighlight(text, hint: hint)
        }
    }

    /// Re-applies styling after the find bar changes background rendering
    /// attributes on the same ranges.
    func reapplyForeground() {
        guard let textView else { return }
        if mode == .rich {
            applyRichNow(to: textView, clearRenderings: false)
            return
        }
        let text = textView.string
        let visible = visibleCharacterRange(in: textView)
        let passGeneration = generation
        parseQueue.async { [weak self] in
            guard let self else { return }
            let spans = self.index.spans(in: visible)
            DispatchQueue.main.async {
                guard passGeneration == self.generation,
                      self.textView?.string == text else { return }
                self.applyVisible(spans, textView: textView, visible: visible)
            }
        }
    }

    // MARK: - Source parsing

    private func rehighlight(_ text: String, hint: Int?) {
        debounceWork?.cancel()
        generation += 1
        let parseGeneration = generation
        let snapshot = text

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let update = self.index.update(text: snapshot, changedOffsetHint: hint)
            guard !update.didRebuildEntireDocument || !update.spans.isEmpty || update.affectedRange.length > 0 else {
                return
            }
            DispatchQueue.main.async {
                guard parseGeneration == self.generation,
                      let textView = self.textView,
                      textView.string == snapshot else { return }
                self.apply(update, textView: textView)
            }
        }
        debounceWork = work
        parseQueue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    /// Full source refresh used when leaving WYSIWYG, where incremental ranges
    /// no longer describe the text storage's base attributes.
    private func applySourceNow(to textView: NSTextView) {
        generation += 1
        let text = textView.string
        resetStorage(to: sourceBaseAttributes, textView: textView, clearRenderings: false)
        renderedMode = .source
        let spans = MarkdownSyntax.spans(in: text)
        let visible = visibleCharacterRange(in: textView)
        guard let layoutManager = textView.textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage else { return }
        applySpans(
            spans.filter { NSIntersectionRange($0.range, visible).length > 0 },
            contentStorage: contentStorage,
            layoutManager: layoutManager
        )
        let passGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + fullPassDelay) { [weak self] in
            guard let self, passGeneration == self.generation else { return }
            self.applyInChunks(
                spans,
                index: 0,
                generation: passGeneration,
                contentStorage: contentStorage,
                layoutManager: layoutManager,
                textView: textView
            )
        }
    }

    // MARK: - Source applying

    private func apply(_ update: MarkdownSyntaxUpdate, textView: NSTextView) {
        guard let layoutManager = textView.textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage else { return }

        if renderedMode != .source {
            resetStorage(to: sourceBaseAttributes, textView: textView, clearRenderings: false)
            renderedMode = .source
        }

        if update.affectedRange.length > 0 {
            clearForeground(
                range: update.affectedRange,
                contentStorage: contentStorage,
                layoutManager: layoutManager
            )
        }

        let visible = visibleCharacterRange(in: textView)
        let immediate = update.spans.filter { NSIntersectionRange($0.range, visible).length > 0 }
        applySpans(immediate, contentStorage: contentStorage, layoutManager: layoutManager)

        let passGeneration = generation
        let remaining = update.spans
        DispatchQueue.main.asyncAfter(deadline: .now() + fullPassDelay) { [weak self] in
            guard let self, passGeneration == self.generation else { return }
            self.applyInChunks(
                remaining,
                index: 0,
                generation: passGeneration,
                contentStorage: contentStorage,
                layoutManager: layoutManager,
                textView: textView
            )
        }
    }

    /// Applies the remainder of the changed spans in small main-thread slices
    /// so a large file never blocks the run loop for one long pass.
    private func applyInChunks(
        _ spans: [MarkdownSyntaxSpan],
        index: Int,
        generation passGeneration: Int,
        contentStorage: NSTextContentStorage,
        layoutManager: NSTextLayoutManager,
        textView: NSTextView
    ) {
        guard passGeneration == generation else { return }
        let end = min(index + chunkSize, spans.count)
        if index < end {
            applySpans(Array(spans[index..<end]), contentStorage: contentStorage, layoutManager: layoutManager)
        }
        if end < spans.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.002) { [weak self] in
                self?.applyInChunks(
                    spans,
                    index: end,
                    generation: passGeneration,
                    contentStorage: contentStorage,
                    layoutManager: layoutManager,
                    textView: textView
                )
            }
        } else {
            textView.needsDisplay = true
        }
    }

    private func applyVisible(
        _ spans: [MarkdownSyntaxSpan],
        textView: NSTextView,
        visible: NSRange
    ) {
        guard let layoutManager = textView.textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage else { return }
        clearForeground(range: visible, contentStorage: contentStorage, layoutManager: layoutManager)
        applySpans(
            spans.filter { NSIntersectionRange($0.range, visible).length > 0 },
            contentStorage: contentStorage,
            layoutManager: layoutManager
        )
    }

    private func applySpans(
        _ spans: [MarkdownSyntaxSpan],
        contentStorage: NSTextContentStorage,
        layoutManager: NSTextLayoutManager
    ) {
        for span in spans {
            setColor(
                color(for: span.kind),
                range: span.range,
                contentStorage: contentStorage,
                layoutManager: layoutManager
            )
        }
    }

    private func clearForeground(
        range: NSRange,
        contentStorage: NSTextContentStorage,
        layoutManager: NSTextLayoutManager
    ) {
        guard range.length > 0 else { return }
        setColor(
            .textColor,
            range: range,
            contentStorage: contentStorage,
            layoutManager: layoutManager
        )
    }

    private func setColor(
        _ color: NSColor,
        range: NSRange,
        contentStorage: NSTextContentStorage,
        layoutManager: NSTextLayoutManager
    ) {
        guard range.length > 0,
              let start = contentStorage.location(contentStorage.documentRange.location, offsetBy: range.location),
              let end = contentStorage.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return }
        layoutManager.setRenderingAttributes([.foregroundColor: color], for: textRange)
        layoutManager.invalidateLayout(for: textRange)
    }

    // MARK: - Rich parsing and applying

    private func rehighlightRich(_ text: String) {
        richWork?.cancel()
        richGeneration += 1
        let parseGeneration = richGeneration
        let snapshot = text
        let work = DispatchWorkItem { [weak self] in
            let runs = MarkdownPresentation.runs(in: snapshot)
            DispatchQueue.main.async {
                guard let self,
                      parseGeneration == self.richGeneration,
                      let textView = self.textView,
                      textView.string == snapshot else { return }
                self.applyRich(runs, to: textView, clearRenderings: false)
            }
        }
        richWork = work
        parseQueue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func applyRichNow(to textView: NSTextView, clearRenderings: Bool) {
        let runs = MarkdownPresentation.runs(in: textView.string)
        applyRich(runs, to: textView, clearRenderings: clearRenderings)
    }

    private func applyRich(
        _ runs: [MarkdownPresentation.Run],
        to textView: NSTextView,
        clearRenderings: Bool
    ) {
        guard let storage = textView.textStorage else { return }
        resetStorage(to: richBaseAttributes, textView: textView, clearRenderings: clearRenderings)
        renderedMode = .rich

        let visible = visibleCharacterRange(in: textView)
        let immediate = runs.filter { NSIntersectionRange($0.range, visible).length > 0 }
        applyRichRuns(immediate, to: textView)

        let passGeneration = richGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + fullPassDelay) { [weak self] in
            guard let self, passGeneration == self.richGeneration else { return }
            self.applyRichInChunks(
                runs,
                index: 0,
                generation: passGeneration,
                textView: textView
            )
        }
    }

    private func applyRichInChunks(
        _ runs: [MarkdownPresentation.Run],
        index: Int,
        generation passGeneration: Int,
        textView: NSTextView
    ) {
        guard passGeneration == richGeneration else { return }
        let end = min(index + chunkSize, runs.count)
        if index < end {
            applyRichRuns(Array(runs[index..<end]), to: textView)
        }
        if end < runs.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.002) { [weak self] in
                self?.applyRichInChunks(
                    runs,
                    index: end,
                    generation: passGeneration,
                    textView: textView
                )
            }
        } else {
            textView.needsDisplay = true
        }
    }

    private func applyRichRuns(_ runs: [MarkdownPresentation.Run], to textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let length = storage.length
        let undoManager = textView.undoManager
        undoManager?.disableUndoRegistration()
        defer { undoManager?.enableUndoRegistration() }
        storage.beginEditing()
        for run in runs {
            guard run.range.location >= 0,
                  run.range.location + run.range.length <= length,
                  run.range.length > 0 else { continue }
            let attributes = richAttributes(for: run.style)
            guard !attributes.isEmpty else { continue }
            storage.addAttributes(attributes, range: run.range)
        }
        storage.endEditing()
    }

    private func resetStorage(
        to attributes: [NSAttributedString.Key: Any],
        textView: NSTextView,
        clearRenderings: Bool
    ) {
        guard let storage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        let undoManager = textView.undoManager
        undoManager?.disableUndoRegistration()
        storage.beginEditing()
        storage.setAttributes(attributes, range: full)
        storage.endEditing()
        undoManager?.enableUndoRegistration()
        if clearRenderings,
           let layoutManager = textView.textLayoutManager,
           let contentStorage = layoutManager.textContentManager as? NSTextContentStorage,
           full.length > 0,
           let start = contentStorage.location(contentStorage.documentRange.location, offsetBy: 0),
           let end = contentStorage.location(start, offsetBy: full.length),
           let range = NSTextRange(location: start, end: end) {
            layoutManager.setRenderingAttributes([:], for: range)
            layoutManager.invalidateLayout(for: range)
        }
    }

    private var sourceBaseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor.textColor
        ]
    }

    private var richBaseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor.textColor
        ]
    }

    private func richAttributes(for style: MarkdownPresentation.Style) -> [NSAttributedString.Key: Any] {
        switch style {
        case .body:
            return [:]
        case .hidden:
            return [
                .font: NSFont.systemFont(ofSize: 0.1),
                .foregroundColor: NSColor.clear
            ]
        case .heading(let level):
            let size = fontSize + CGFloat(max(0, 7 - level) * 2)
            return [.font: NSFont.systemFont(ofSize: size, weight: .bold)]
        case .strong:
            return [.font: NSFont.systemFont(ofSize: fontSize, weight: .bold)]
        case .emphasis:
            return [.font: NSFontManager.shared.convert(
                NSFont.systemFont(ofSize: fontSize),
                toHaveTrait: .italicFontMask
            )]
        case .strikethrough:
            return [.strikethroughStyle: NSUnderlineStyle.single.rawValue]
        case .code:
            return [
                .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                .backgroundColor: NSColor.labelColor.withAlphaComponent(0.08)
            ]
        case .link:
            return [
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
        case .image:
            return [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFontManager.shared.convert(
                    NSFont.systemFont(ofSize: fontSize),
                    toHaveTrait: .italicFontMask
                )
            ]
        case .blockQuote:
            let paragraph = NSMutableParagraphStyle()
            paragraph.headIndent = 14
            paragraph.firstLineHeadIndent = 14
            return [
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph
            ]
        case .listMarker, .taskMarker:
            return [.foregroundColor: NSColor.secondaryLabelColor]
        case .tableHeader:
            return [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold)]
        case .codeBlock:
            return [
                .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                .backgroundColor: NSColor.labelColor.withAlphaComponent(0.08)
            ]
        }
    }

    private func visibleCharacterRange(in textView: NSTextView) -> NSRange {
        let rect = textView.visibleRect
        let length = (textView.string as NSString).length
        guard rect.height > 0, length > 0 else { return NSRange(location: 0, length: 0) }

        let x = textView.textContainerInset.width + 1
        let top = textView.characterIndexForInsertion(at: NSPoint(x: x, y: rect.minY))
        let bottom = textView.characterIndexForInsertion(at: NSPoint(x: x, y: rect.maxY))
        let start = max(0, min(top, bottom) - 200)
        let end = min(length, max(top, bottom) + 200)
        guard end > start else { return NSRange(location: 0, length: 0) }
        return NSRange(location: start, length: end - start)
    }

    private func color(for kind: MarkdownSyntaxSpan.Kind) -> NSColor {
        MarkdownSyntaxPalette.color(for: kind)
    }
}
