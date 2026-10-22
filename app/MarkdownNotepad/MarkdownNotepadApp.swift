import SwiftUI

@main
struct MarkdownNotepadApp: App {
    var body: some Scene {
        WindowGroup("Markdown Notepad") {
            ContentView()
                .frame(minWidth: 640, minHeight: 420)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New") {}
                    .keyboardShortcut("n")
                    .disabled(true)
                Button("Open…") {}
                    .keyboardShortcut("o")
                    .disabled(true)
            }

            CommandGroup(replacing: .saveItem) {
                Button("Save") {}
                    .keyboardShortcut("s")
                    .disabled(true)
                Button("Save As…") {}
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(true)
            }
        }
    }
}
