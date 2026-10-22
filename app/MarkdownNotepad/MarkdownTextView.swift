import AppKit
import MarkdownCore
import SwiftUI

/// A TextKit 2 backed plain-text editor hosted in SwiftUI.
///
/// The app uses `NSTextView` rather than SwiftUI's `TextEditor` so the find
/// bar, word wrap, zoom, undo, and later M3 highlighting can attach to the
/// real text engine.
struct MarkdownTextView: NSViewRepresentable {
    @ObservedObject var session: DocumentSession

    func makeCoordinator() -> MarkdownTextController {
        MarkdownTextController(session: session)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)

        let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        container.widthTracksTextView = true
        layoutManager.textContainer = container

        let textView = MarkdownEditorTextView(frame: .zero, textContainer: container)
        textView.delegate = context.coordinator
        textView.string = session.text
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: session.fontSize, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 18, height: 18)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = !session.wordWrap
        textView.autoresizingMask = [.width]
        textView.setAccessibilityIdentifier("editor")
        textView.setAccessibilityLabel("Markdown editor")
        textView.setAccessibilityHelp("Type Markdown or plain text. Press Shift Command P to toggle the rendered preview.")

        context.coordinator.configure(mode: session.editorMode, fontSize: session.fontSize)
        context.coordinator.attach(textView: textView)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !session.wordWrap
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        session.registerTextController(context.coordinator)
        applyWordWrap(to: textView, scrollView: scrollView)

        DispatchQueue.main.async {
            if textView.window == nil {
                DispatchQueue.main.async {
                    textView.window?.makeFirstResponder(textView)
                }
            } else {
                textView.window?.makeFirstResponder(textView)
            }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.textView = textView

        if textView.string != session.text {
            textView.string = session.text
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            context.coordinator.reapplyCurrentPresentation()
        }
        context.coordinator.applyEditorMode(
            session.editorMode,
            fontSize: session.fontSize
        )
        applyWordWrap(to: textView, scrollView: scrollView)
    }

    private func applyWordWrap(to textView: NSTextView, scrollView: NSScrollView) {
        let wraps = session.wordWrap
        textView.isHorizontallyResizable = !wraps
        scrollView.hasHorizontalScroller = !wraps
        if wraps {
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.containerSize = NSSize(
                width: scrollView.contentSize.width,
                height: CGFloat.greatestFiniteMagnitude
            )
        } else {
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
    }
}

final class MarkdownTextController: NSObject, NSTextViewDelegate {
    weak var textView: NSTextView?
    let highlighter = MarkdownSyntaxHighlighter()
    private let richStyler = MarkdownRichStyler()
    private(set) var editorMode: EditorMode = .panels
    private(set) var fontSize: CGFloat = 14
    private unowned let session: DocumentSession

    init(session: DocumentSession) {
        self.session = session
    }

    func configure(mode: EditorMode, fontSize: CGFloat) {
        editorMode = mode
        self.fontSize = fontSize
        textView?.font = baseFont(for: mode, size: fontSize)
    }

    /// Switches between source and rich presentation while keeping the same
    /// text storage, selection, and (approximately) vertical scroll position.
    func applyEditorMode(_ mode: EditorMode, fontSize: CGFloat) {
        guard mode != editorMode || fontSize != self.fontSize else { return }
        let scrollFraction = currentScrollFraction()
        editorMode = mode
        self.fontSize = fontSize
        textView?.font = baseFont(for: mode, size: fontSize)
        if let textView {
            if mode == .wysiwyg {
                highlighter.detach()
                richStyler.apply(textView: textView, fontSize: fontSize, clearRenderings: true)
            } else {
                richStyler.removeStyles(from: textView, fontSize: fontSize)
                highlighter.attach(to: textView)
            }
        }
        resetTypingAttributes()
        restoreScrollFraction(scrollFraction)
    }

    func attach(textView: NSTextView) {
        self.textView = textView
        textView.font = baseFont(for: editorMode, size: fontSize)
        if editorMode == .wysiwyg {
            highlighter.detach()
            richStyler.apply(textView: textView, fontSize: fontSize, clearRenderings: true)
        } else {
            highlighter.attach(to: textView)
        }
        resetTypingAttributes()
        if let editor = textView as? MarkdownEditorTextView {
            editor.tabHandler = { [weak self] outdent in
                self?.handleTab(outdent: outdent) ?? false
            }
        }
    }

    func detach() {
        (textView as? MarkdownEditorTextView)?.tabHandler = nil
        highlighter.detach()
        richStyler.cancel()
        textView = nil
    }

    func reapplyCurrentPresentation() {
        guard let textView else { return }
        if editorMode == .wysiwyg {
            richStyler.apply(textView: textView, fontSize: fontSize, clearRenderings: true)
        } else {
            highlighter.textDidChange(textView.string, hint: nil)
        }
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        session.userEdited(textView.string)
        if editorMode == .wysiwyg {
            resetTypingAttributes()
            richStyler.scheduleApply(textView: textView)
        } else {
            highlighter.textDidChange(textView.string, hint: textView.selectedRange().location)
        }
    }

    // MARK: - Presentation helpers

    private func baseFont(for mode: EditorMode, size: CGFloat) -> NSFont {
        switch mode {
        case .plainText, .panels:
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        case .wysiwyg:
            return .systemFont(ofSize: size)
        }
    }

    /// Hidden markers use a near-zero font. Reset typing attributes so newly
    /// typed characters never inherit that invisible style.
    private func resetTypingAttributes() {
        guard let textView else { return }
        textView.typingAttributes = [
            .font: baseFont(for: editorMode, size: fontSize),
            .foregroundColor: NSColor.textColor
        ]
    }

    private func currentScrollFraction() -> CGFloat? {
        guard let textView, let scrollView = textView.enclosingScrollView else { return nil }
        let clipView = scrollView.contentView
        let maximum = max(0, textView.frame.height - clipView.bounds.height)
        guard maximum > 0 else { return 0 }
        return min(1, max(0, clipView.bounds.origin.y / maximum))
    }

    private func restoreScrollFraction(_ fraction: CGFloat?) {
        guard let fraction else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let textView = self.textView,
                  let scrollView = textView.enclosingScrollView else { return }
            textView.layoutSubtreeIfNeeded()
            scrollView.layoutSubtreeIfNeeded()
            let clipView = scrollView.contentView
            let maximum = max(0, textView.frame.height - clipView.bounds.height)
            let origin = NSPoint(
                x: clipView.bounds.origin.x,
                y: min(maximum, max(0, fraction * maximum))
            )
            clipView.scroll(to: origin)
            scrollView.reflectScrolledClipView(clipView)
        }
    }
}
