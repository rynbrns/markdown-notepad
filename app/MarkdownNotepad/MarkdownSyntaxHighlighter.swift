import AppKit
import MarkdownCore

/// Applies semantic colours to the TextKit 2 editor without touching the
/// document's characters.
///
/// Highlighting is debounced, parsing happens off the main thread, and the
/// visible spans are applied first so typing never waits on the whole file. A
/// full-document pass follows shortly after the last keystroke. Only
/// `foregroundColor` rendering attributes are written here so the find bar's
/// background highlights remain composable.
final class MarkdownSyntaxHighlighter {
    private weak var textView: NSTextView?

    private var debounceWork: DispatchWorkItem?
    private var fullPassWork: DispatchWorkItem?
    private var appliedSpans: [MarkdownSyntaxSpan] = []
    private var generation = 0

    private let debounceInterval: TimeInterval = 0.06
    private let fullPassDelay: TimeInterval = 0.15

    func attach(to textView: NSTextView) {
        self.textView = textView
        rehighlight(textView.string)
    }

    func detach() {
        debounceWork?.cancel()
        fullPassWork?.cancel()
        debounceWork = nil
        fullPassWork = nil
        textView = nil
        appliedSpans = []
    }

    func textDidChange(_ text: String) {
        rehighlight(text)
    }

    /// Re-applies foreground attributes over the cached spans. The find bar
    /// calls this after it changes background rendering attributes.
    func reapplyForeground() {
        guard let textView else { return }
        let snapshot = textView.string
        rehighlight(snapshot)
    }

    private func rehighlight(_ text: String) {
        debounceWork?.cancel()
        fullPassWork?.cancel()
        generation += 1
        let parseGeneration = generation
        let snapshot = text

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let spans = MarkdownSyntax.spans(in: snapshot)
            DispatchQueue.main.async {
                guard parseGeneration == self.generation else { return }
                self.apply(spans, text: snapshot)
            }
        }
        debounceWork = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + debounceInterval,
            execute: work
        )
    }

    private func apply(_ spans: [MarkdownSyntaxSpan], text: String) {
        guard let textView,
              textView.string == text,
              let layoutManager = textView.textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage else { return }

        let stored = appliedSpans
        appliedSpans = spans
        let liveKeys = Set(spans)
        for stale in stored where !liveKeys.contains(stale) {
            setColor(.textColor, range: stale.range, contentStorage: contentStorage, layoutManager: layoutManager)
        }

        let visible = visibleCharacterRange(in: textView)
        let visibleSpans = visible.length == 0
            ? spans
            : spans.filter { NSIntersectionRange($0.range, visible).length > 0 }
        for span in visibleSpans {
            setColor(color(for: span.kind), range: span.range, contentStorage: contentStorage, layoutManager: layoutManager)
        }

        let passGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, passGeneration == self.generation else { return }
            self.applyFullPass(
                spans,
                generation: passGeneration,
                contentStorage: contentStorage,
                layoutManager: layoutManager,
                textView: textView
            )
        }
        fullPassWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + fullPassDelay, execute: work)
    }

    /// Applies the remainder of the document in small main-thread slices so a
    /// large file never blocks the run loop for one long pass.
    private func applyFullPass(
        _ spans: [MarkdownSyntaxSpan],
        generation passGeneration: Int,
        contentStorage: NSTextContentStorage,
        layoutManager: NSTextLayoutManager,
        textView: NSTextView
    ) {
        var index = 0
        let chunkSize = 400
        func applyChunk() {
            guard passGeneration == self.generation else { return }
            let end = min(index + chunkSize, spans.count)
            if index < end {
                for span in spans[index..<end] {
                    self.setColor(
                        self.color(for: span.kind),
                        range: span.range,
                        contentStorage: contentStorage,
                        layoutManager: layoutManager
                    )
                }
                index = end
            }
            if index < spans.count {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.002, execute: applyChunk)
            } else {
                textView.needsDisplay = true
            }
        }
        applyChunk()
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
        switch kind {
        case .heading:
            return .controlAccentColor
        case .emphasis:
            return .systemPurple
        case .strong:
            return .systemRed
        case .strikethrough:
            return .secondaryLabelColor
        case .listMarker:
            return .systemTeal
        case .taskMarker:
            return .systemGreen
        case .link, .image:
            return .linkColor
        case .codeSpan, .codeBlock:
            return .systemPink
        case .tableHeader, .tableDelimiter, .tableRow:
            return .systemIndigo
        case .blockQuote:
            return .secondaryLabelColor
        }
    }
}
