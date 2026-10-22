import MarkdownCore
import SwiftUI

struct ContentView: View {
    @ObservedObject private var session = DocumentSession.shared

    private var document: MarkdownDocument {
        MarkdownDocument(text: session.text)
    }

    private var editorText: Binding<String> {
        Binding(
            get: { session.text },
            set: { session.userEdited($0) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if session.recoveredFromCrash {
                recoveredBanner
                Divider()
            }

            MarkdownTextView(text: editorText)

            Divider()

            HStack(spacing: 12) {
                Text("\(document.wordCount) words")
                Text("·")
                Text("\(document.lineCount) lines")
                Text("·")
                Text(session.formatLabel)
                Spacer()
                if session.isDirty {
                    Text("Edited")
                        .foregroundStyle(.orange)
                }
                Text(session.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .navigationTitle(session.windowTitle)
        .alert(
            "File changed on disk",
            isPresented: Binding(
                get: { session.conflictPrompt != nil },
                set: { isPresented in
                    if !isPresented { session.conflictPrompt = nil }
                }
            ),
            presenting: session.conflictPrompt
        ) { _ in
            Button("Reload") {
                session.conflictPrompt = nil
                session.reloadFromDisk()
            }
            Button("Overwrite") {
                session.conflictPrompt = nil
                session.overwriteWithCurrentText()
            }
            Button("Save As…") {
                session.conflictPrompt = nil
                session.saveAs()
            }
            Button("Cancel", role: .cancel) {
                session.conflictPrompt = nil
            }
        } message: { _ in
            Text("“\(session.displayName)” was changed by another app after you opened it. Choose how to continue.")
        }
    }

    private var recoveredBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.counterclockwise.circle")
            Text("Recovered unsaved text after an unexpected quit.")
            Spacer()
            Button("Dismiss") {
                session.acknowledgeRecovery()
            }
            .buttonStyle(.link)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.yellow.opacity(0.15))
    }
}
