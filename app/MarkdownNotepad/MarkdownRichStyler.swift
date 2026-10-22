import AppKit
import MarkdownCore

/// Applies the rich (WYSIWYG) presentation to the shared `NSTextView`.
///
/// This is deliberately separate from `MarkdownSyntaxHighlighter`: source mode
/// uses rendering attributes and an incremental index, while rich mode writes
/// presentation-only text attributes (font, colour, hidden markers). Keeping
/// the two paths separate means switching modes never mixes their state.
///
/// Characters are never inserted, removed, or rewritten. Hidden Markdown
/// markers are only given a near-zero font and a clear colour, so the text
/// storage still contains exactly the bytes that will be saved.
final class MarkdownRichStyler {
    private let parseQueue = DispatchQueue(
        label: "com.ryanpaperclip.markdownnotepad.rich-styler",
        qos: .userInitiated
    )
    private var work: DispatchWorkItem?
    private var generation = 0
    private weak var textView: NSTextView?
    private var fontSize: CGFloat = 14

    private let debounceInterval: TimeInterval = 0.03
    private let fullPassDelay: TimeInterval = 0.06
    private let chunkSize = 400

    /// Applies rich styling immediately. Used on attach, mode switches, and
    /// font-size changes, where waiting for a debounce would flash the source.
    func apply(textView: NSTextView, fontSize: CGFloat, clearRenderings: Bool) {
        self.textView = textView
        self.fontSize = fontSize
        generation += 1
        work?.cancel()
        let runs = MarkdownPresentation.runs(in: textView.string)
        apply(runs, to: textView, clearRenderings: clearRenderings)
    }

    /// Re-renders after an edit without blocking typing on the whole document.
    func scheduleApply(textView: NSTextView) {
        self.textView = textView
        generation += 1
        let parseGeneration = generation
        let snapshot = textView.string
        work?.cancel()
        let task = DispatchWorkItem { [weak self] in
            let runs = MarkdownPresentation.runs(in: snapshot)
            DispatchQueue.main.async {
                guard let self,
                      parseGeneration == self.generation,
                      let textView = self.textView,
                      textView.string == snapshot else { return }
                self.apply(runs, to: textView, clearRenderings: false)
            }
        }
        work = task
        parseQueue.asyncAfter(deadline: .now() + debounceInterval, execute: task)
    }

    /// Restores the plain source presentation before the syntax highlighter
    /// takes over again.
    func removeStyles(from textView: NSTextView, fontSize: CGFloat) {
        cancel()
        self.fontSize = fontSize
        resetStorage(
            to: [
                .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: NSColor.textColor
            ],
            textView: textView,
            clearRenderings: false
        )
    }

    func cancel() {
        work?.cancel()
        work = nil
        generation += 1
    }

    // MARK: - Applying

    private func apply(
        _ runs: [MarkdownPresentation.Run],
        to textView: NSTextView,
        clearRenderings: Bool
    ) {
        guard textView.textStorage != nil else { return }
        resetStorage(to: baseAttributes, textView: textView, clearRenderings: clearRenderings)

        let visible = visibleCharacterRange(in: textView)
        applyRuns(
            runs.filter { NSIntersectionRange($0.range, visible).length > 0 },
            to: textView
        )

        let passGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + fullPassDelay) { [weak self] in
            guard let self, passGeneration == self.generation else { return }
            self.applyInChunks(runs, index: 0, generation: passGeneration, textView: textView)
        }
    }

    private func applyInChunks(
        _ runs: [MarkdownPresentation.Run],
        index: Int,
        generation passGeneration: Int,
        textView: NSTextView
    ) {
        guard passGeneration == generation else { return }
        let end = min(index + chunkSize, runs.count)
        if index < end {
            applyRuns(Array(runs[index..<end]), to: textView)
        }
        if end < runs.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.002) { [weak self] in
                self?.applyInChunks(
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

    private func applyRuns(_ runs: [MarkdownPresentation.Run], to textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let length = storage.length
        let undoManager = textView.undoManager
        undoManager?.disableUndoRegistration()
        defer { undoManager?.enableUndoRegistration() }
        storage.beginEditing()
        for run in runs {
            guard run.range.location >= 0,
                  run.range.length > 0,
                  run.range.location + run.range.length <= length else { continue }
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

        guard clearRenderings,
              full.length > 0,
              let layoutManager = textView.textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage,
              let start = contentStorage.location(contentStorage.documentRange.location, offsetBy: 0),
              let end = contentStorage.location(start, offsetBy: full.length),
              let range = NSTextRange(location: start, end: end) else { return }
        layoutManager.setRenderingAttributes([:], for: range)
        layoutManager.invalidateLayout(for: range)
    }

    private var baseAttributes: [NSAttributedString.Key: Any] {
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
}
