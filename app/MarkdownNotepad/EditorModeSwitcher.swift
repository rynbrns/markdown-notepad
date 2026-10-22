import MarkdownCore
import SwiftUI

/// Compact, unobtrusive mode control that lives in the editor's status bar.
///
/// The three buttons mirror the View > Editor Mode menu and the ⌃⌘1/2/3
/// shortcuts. The active mode is tinted and also named in the status bar.
struct EditorModeSwitcher: View {
    @ObservedObject var session: DocumentSession

    var body: some View {
        HStack(spacing: 1) {
            ForEach(EditorMode.allCases, id: \.self) { mode in
                Button {
                    session.setEditorMode(mode)
                } label: {
                    Image(systemName: symbol(for: mode))
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 24, height: 17)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(session.editorMode == mode
                                      ? Color.accentColor.opacity(0.18)
                                      : Color.clear)
                        )
                }
                .buttonStyle(.borderless)
                .foregroundStyle(session.editorMode == mode ? Color.accentColor : Color.secondary)
                .help("\(mode.title) — \(mode.summary) (\(shortcut(for: mode)))")
                .accessibilityLabel(mode.title)
                .accessibilityValue(session.editorMode == mode ? "selected" : "")
                .accessibilityIdentifier(
                    session.editorMode == mode
                        ? "activeMode-\(mode.rawValue)"
                        : "mode-\(mode.rawValue)"
                )
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
        .accessibilityIdentifier("modeSwitcher")
    }

    private func symbol(for mode: EditorMode) -> String {
        switch mode {
        case .plainText:
            return "text.alignleft"
        case .panels:
            return "rectangle.split.2x1"
        case .wysiwyg:
            return "textformat"
        }
    }

    private func shortcut(for mode: EditorMode) -> String {
        switch mode {
        case .plainText:
            return "⌃⌘1"
        case .panels:
            return "⌃⌘2"
        case .wysiwyg:
            return "⌃⌘3"
        }
    }
}
