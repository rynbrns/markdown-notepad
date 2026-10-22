import AppKit
import MarkdownCore
import SwiftUI

/// One Markdown formatting command from the Editor menu or a keyboard shortcut.
enum MarkdownFormattingAction {
    case bold
    case italic
    case strikethrough
    case inlineCode
    case codeBlock
    case link
    case unorderedList
    case orderedList
    case blockquote
    case heading(Int)
    case indentList
    case outdentList
}

/// The Editor menu. Every item carries the same shortcut that the text view
/// responds to, so the glyphs are discoverable from the menu bar.
struct MarkdownFormattingCommands: Commands {
    @FocusedValue(\.documentSession) private var session

    var body: some Commands {
        CommandMenu("Editor") {
            Button("Bold") {
                session?.applyFormatting(.bold)
            }
            .keyboardShortcut("b")
            .disabled(session == nil)

            Button("Italic") {
                session?.applyFormatting(.italic)
            }
            .keyboardShortcut("i")
            .disabled(session == nil)

            Button("Strikethrough") {
                session?.applyFormatting(.strikethrough)
            }
            .keyboardShortcut("x", modifiers: [.command, .shift])
            .disabled(session == nil)

            Button("Inline Code") {
                session?.applyFormatting(.inlineCode)
            }
            .keyboardShortcut("`")
            .disabled(session == nil)

            Button("Code Block") {
                session?.applyFormatting(.codeBlock)
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(session == nil)

            Divider()

            Menu("Heading") {
                ForEach(1...6, id: \.self) { level in
                    Button("Heading \(level)") {
                        session?.applyFormatting(.heading(level))
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(level)")), modifiers: .command)
                    .disabled(session == nil)
                }
            }

            Divider()

            Button("Unordered List") {
                session?.applyFormatting(.unorderedList)
            }
            .keyboardShortcut("8", modifiers: [.command, .shift])
            .disabled(session == nil)

            Button("Ordered List") {
                session?.applyFormatting(.orderedList)
            }
            .keyboardShortcut("7", modifiers: [.command, .shift])
            .disabled(session == nil)

            Button("Increase List Indent") {
                session?.applyFormatting(.indentList)
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(session == nil)

            Button("Decrease List Indent") {
                session?.applyFormatting(.outdentList)
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(session == nil)

            Button("Blockquote") {
                session?.applyFormatting(.blockquote)
            }
            .keyboardShortcut("q", modifiers: [.command, .option])
            .disabled(session == nil)

            Divider()

            Button("Insert Link") {
                session?.applyFormatting(.link)
            }
            .keyboardShortcut("k")
            .disabled(session == nil)
        }
    }
}

/// An `NSTextView` that lets Tab and Shift-Tab nest list items while keeping
/// the standard text view behaviour everywhere else.
final class MarkdownEditorTextView: NSTextView {
    var tabHandler: ((Bool) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48,
           event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
           tabHandler?(event.modifierFlags.contains(.shift)) == true {
            return
        }
        super.keyDown(with: event)
    }
}

extension MarkdownTextController {
    func apply(_ action: MarkdownFormattingAction) {
        guard let textView else { return }
        let selection = textView.selectedRange()
        let text = textView.string

        let result: MarkdownFormatResult?
        switch action {
        case .bold:
            result = MarkdownFormatting.toggleInline(.bold, in: text, selection: selection)
        case .italic:
            result = MarkdownFormatting.toggleInline(.italic, in: text, selection: selection)
        case .strikethrough:
            result = MarkdownFormatting.toggleInline(.strikethrough, in: text, selection: selection)
        case .inlineCode:
            result = MarkdownFormatting.toggleInline(.code, in: text, selection: selection)
        case .codeBlock:
            result = MarkdownFormatting.toggleLine(.codeBlock, in: text, selection: selection)
        case .link:
            result = MarkdownFormatting.insertLink(
                in: text,
                selection: selection,
                url: Self.linkURLFromPasteboard()
            )
        case .unorderedList:
            result = MarkdownFormatting.toggleLine(.unorderedList, in: text, selection: selection)
        case .orderedList:
            result = MarkdownFormatting.toggleLine(.orderedList, in: text, selection: selection)
        case .blockquote:
            result = MarkdownFormatting.toggleLine(.blockquote, in: text, selection: selection)
        case .heading(let level):
            result = MarkdownFormatting.toggleLine(.heading(level: level), in: text, selection: selection)
        case .indentList:
            result = MarkdownFormatting.adjustListIndent(in: text, selection: selection, outdent: false)
        case .outdentList:
            result = MarkdownFormatting.adjustListIndent(in: text, selection: selection, outdent: true)
        }

        guard let result else { return }
        guard result.didChange else {
            NSSound.beep()
            return
        }
        replaceText(in: textView, with: result)
    }

    func handleTab(outdent: Bool) -> Bool {
        guard let textView else { return false }
        guard let result = MarkdownFormatting.adjustListIndent(
            in: textView.string,
            selection: textView.selectedRange(),
            outdent: outdent
        ) else { return false }
        if result.didChange {
            replaceText(in: textView, with: result)
        }
        return true
    }

    /// Replaces only the changed middle of the buffer so undo, scroll position,
    /// and the syntax highlighter behave like a normal edit.
    private func replaceText(in textView: NSTextView, with result: MarkdownFormatResult) {
        let old = textView.string as NSString
        let new = result.text as NSString
        let limit = min(old.length, new.length)

        var prefix = 0
        while prefix < limit,
              old.character(at: prefix) == new.character(at: prefix) {
            prefix += 1
        }
        var suffix = 0
        while suffix < limit - prefix,
              old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) {
            suffix += 1
        }

        let range = NSRange(location: prefix, length: old.length - prefix - suffix)
        let replacement = new.substring(with: NSRange(
            location: prefix,
            length: new.length - prefix - suffix
        ))

        textView.insertText(replacement, replacementRange: range)
        textView.setSelectedRange(result.selection)
    }

    private static func linkURLFromPasteboard() -> String? {
        guard let value = NSPasteboard.general.string(forType: .string) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: { $0.isWhitespace }),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else { return nil }
        return trimmed
    }
}
