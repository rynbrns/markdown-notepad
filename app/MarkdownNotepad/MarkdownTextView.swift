import AppKit
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

        let textView = NSTextView(frame: .zero, textContainer: container)
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

        context.coordinator.textView = textView

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
        }
        let desiredFont = NSFont.monospacedSystemFont(ofSize: session.fontSize, weight: .regular)
        if textView.font != desiredFont {
            textView.font = desiredFont
        }
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
    private unowned let session: DocumentSession

    init(session: DocumentSession) {
        self.session = session
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        session.userEdited(textView.string)
    }
}
