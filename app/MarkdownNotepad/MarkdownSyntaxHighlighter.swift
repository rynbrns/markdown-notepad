import AppKit
import MarkdownCore

/// Applies semantic colours to the TextKit 2 editor without touching the
/// document's characters.
///
/// Parsing happens off the main thread in a line-oriented incremental index:
/// an edit only rescans the changed line and, when scanner state allows it, the
/// untouched suffix is reused. Rich presentation (the optional WYSIWYG mode)
/// uses the same text storage and only assigns visual attributes, so switching
/// modes can never rewrite the Markdown.
final class MarkdownSyntaxHighlighter {
    enum PresentationMode: Equatable {
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
    private var generation = 0
    private var mode: PresentationMode = .source
    private var fontSize: CGFloat = 14

    private let debounceInterval: TimeInterval = 0.03
    private let fullPassDelay: TimeInterval = 0.06
    private let chunkSize = 400

    func configure(mode: PresentationMode, fontSize: CGFloat) {
        guard mode != self.mode || fontSize != self.fontSize else { return }
        self.mode = mode
        self.fontSize = fontSize
        index = MarkdownSyntaxIndex()
        if let textView {
            rehighlight(textView.string, hint: nil)
        }
    }

    func attach(to textView: NSTextView) {
        self.textView = textView
        rehighlight(textView.string, hint: nil)
    }

    func detach() {
        debounceWork?.cancel()
        debounceWork = nil
        textView = nil
        generation += 1
    }

    /// Compatibility entry point for callers that do not have a selection hint.
    func textDidChange(_ text: String) {
        rehighlight(text, hint: nil)
    }

    /// Called by the editor delegate after every text change. `hint` is the
    /// current selection offset, which lets the index rescan only the edited
    /// tail instead of the whole document.
    func textDidChange(_ text: String, hint: Int?) {
        rehighlight(text, hint: hint)
    }

    /// Re-applies foreground attributes after the find bar changes background
    /// rendering attributes on the same ranges.
    func reapplyForeground() {
        guard let textView else { return }
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

    // MARK: - Parsing

    private func rehighlight(_ text: String, hint: Int?) {
        debounceWork?.cancel()
        generation += 1
        let parseGeneration = generation
        let snapshot = text
        let currentMode = mode
        let currentFontSize = fontSize

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let update = self.index.update(text: snapshot, changedOffsetHint: hint)
            let runs = currentMode == .rich
                ? MarkdownPresentation.runs(in: snapshot, spans: self.index.allSpans())
                : []
            DispatchQueue.main.async {
                guard parseGeneration == self.generation,
                      let textView = self.textView,
                      textView.string == snapshot else { return }
                self.apply(update, runs: runs, mode: currentMode, fontSize: currentFontSize, textView: textView)
            }
        }
        debounceWork = work
        parseQueue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    // MARK: - Applying

    private func apply(
        _ update: MarkdownSyntaxUpdate,
        runs: [MarkdownPresentation.Run],
        mode: PresentationMode,
        fontSize: CGFloat,
        textView: NSTextView
    ) {
        guard let layoutManager = textView.textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage else { return }

        let affected = update.affectedRange
        if affected.length > 0 {
            if update.didRebuildEntireDocument {
                resetAttributes(
                    range: affected,
                    mode: mode,
                    fontSize: fontSize,
                    textView: textView,
                    contentStorage: contentStorage,
                    layoutManager: layoutManager
                )
            } else {
                clearForeground(range: affected, contentStorage: contentStorage, layoutManager: layoutManager)
            }
        }

        let visible = visibleCharacterRange(in: textView)
        if mode == .rich {
            let immediate = runs.filter { NSIntersectionRange($0.range, visible).length > 0 }
            applyRuns(immediate, fontSize: fontSize, contentStorage: contentStorage, layoutManager: layoutManager)
            let passGeneration = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + fullPassDelay) { [weak self] in
                guard let self, passGeneration == self.generation else { return }
                self.applyRunsInChunks(
                    runs,
                    index: 0,
                    generation: passGeneration,
                    fontSize: fontSize,
                    contentStorage: contentStorage,
                    layoutManager: layoutManager,
                    textView: textView
                )
            }
            return
        }

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

    private func applyRunsInChunks(
        _ runs: [MarkdownPresentation.Run],
        index: Int,
        generation passGeneration: Int,
        fontSize: CGFloat,
        contentStorage: NSTextContentStorage,
        layoutManager: NSTextLayoutManager,
        textView: NSTextView
    ) {
        guard passGeneration == generation else { return }
        let end = min(index + chunkSize, runs.count)
        if index < end {
            applyRuns(Array(runs[index..<end]), fontSize: fontSize, contentStorage: contentStorage, layoutManager: layoutManager)
        }
        if end < runs.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.002) { [weak self] in
                self?.applyRunsInChunks(
                    runs,
                    index: end,
                    generation: passGeneration,
                    fontSize: fontSize,
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
            setAttributes(
                [.foregroundColor: MarkdownSyntaxPalette.color(for: span.kind)],
                range: span.range,
                contentStorage: contentStorage,
                layoutManager: layoutManager
            )
        }
    }

    private func applyRuns(
        _ runs: [MarkdownPresentation.Run],
        fontSize: CGFloat,
        contentStorage: NSTextContentStorage,
        layoutManager: NSTextLayoutManager
    ) {
        let baseFont = NSFont.systemFont(ofSize: fontSize)
        for run in runs {
            var attributes: [NSAttributedString.Key: Any] = [:]
            switch run.style {
            case .body:
                attributes[.font] = baseFont
                attributes[.foregroundColor] = NSColor.textColor
            case .heading(let level):
                attributes[.font] = NSFont.boldSystemFont(ofSize: headingSize(level: level, base: fontSize))
                attributes[.foregroundColor] = NSColor.textColor
            case .strong:
                attributes[.font] = NSFont.boldSystemFont(ofSize: fontSize)
            case .emphasis:
                attributes[.font] = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
            case .strikethrough:
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            case .code, .codeBlock:
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: fontSize * 0.94, weight: .regular)
                attributes[.foregroundColor] = MarkdownSyntaxPalette.color(for: .codeSpan)
            case .link:
                attributes[.foregroundColor] = MarkdownSyntaxPalette.color(for: .link)
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            case .image:
                attributes[.foregroundColor] = MarkdownSyntaxPalette.color(for: .image)
            case .blockQuote:
                attributes[.foregroundColor] = MarkdownSyntaxPalette.color(for: .blockQuote)
                attributes[.font] = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
            case .listMarker:
                attributes[.foregroundColor] = MarkdownSyntaxPalette.color(for: .listMarker)
            case .taskMarker:
                attributes[.foregroundColor] = MarkdownSyntaxPalette.color(for: .taskMarker)
            case .tableHeader:
                attributes[.font] = NSFont.boldSystemFont(ofSize: fontSize)
                attributes[.foregroundColor] = MarkdownSyntaxPalette.color(for: .tableHeader)
            case .hidden:
                attributes[.font] = NSFont.systemFont(ofSize: 0.1)
                attributes[.foregroundColor] = NSColor.clear
            }
            setAttributes(attributes, range: run.range, contentStorage: contentStorage, layoutManager: layoutManager)
        }
    }

    private func headingSize(level: Int, base: CGFloat) -> CGFloat {
        switch level {
        case 1: return base * 1.6
        case 2: return base * 1.4
        case 3: return base * 1.25
        case 4: return base * 1.12
        case 5: return base * 1.04
        default: return base
        }
    }

    private func resetAttributes(
        range: NSRange,
        mode: PresentationMode,
        fontSize: CGFloat,
        textView: NSTextView,
        contentStorage: NSTextContentStorage,
        layoutManager: NSTextLayoutManager
    ) {
        guard range.length > 0 else { return }
        textView.font = mode == .rich
            ? NSFont.systemFont(ofSize: fontSize)
            : NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        setAttributes(
            [.foregroundColor: NSColor.textColor],
            range: range,
            contentStorage: contentStorage,
            layoutManager: layoutManager
        )
    }

    private func clearForeground(
        range: NSRange,
        contentStorage: NSTextContentStorage,
        layoutManager: NSTextLayoutManager
    ) {
        guard range.length > 0 else { return }
        setAttributes(
            [.foregroundColor: NSColor.textColor],
            range: range,
            contentStorage: contentStorage,
            layoutManager: layoutManager
        )
    }

    private func setAttributes(
        _ attributes: [NSAttributedString.Key: Any],
        range: NSRange,
        contentStorage: NSTextContentStorage,
        layoutManager: NSTextLayoutManager
    ) {
        guard range.length > 0,
              let start = contentStorage.location(contentStorage.documentRange.location, offsetBy: range.location),
              let end = contentStorage.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return }
        layoutManager.setRenderingAttributes(attributes, for: textRange)
        layoutManager.invalidateLayout(for: textRange)
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
}
