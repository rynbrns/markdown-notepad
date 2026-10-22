import MarkdownCore
import SwiftUI

struct ContentView: View {
    @State private var text = ""

    private var document: MarkdownDocument {
        MarkdownDocument(text: text)
    }

    var body: some View {
        VStack(spacing: 0) {
            MarkdownTextView(text: $text)
            Divider()
            HStack {
                Text("\(document.wordCount) words")
                Text("·")
                Text("\(document.lineCount) lines")
                Spacer()
                Text("M0 skeleton — file operations arrive in M1")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .navigationTitle("Untitled")
    }
}
