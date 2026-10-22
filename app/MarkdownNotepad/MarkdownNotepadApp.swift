import AppKit
import SwiftUI

@main
struct MarkdownNotepadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Markdown Notepad") {
            ContentView()
                .frame(minWidth: 640, minHeight: 420)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New") {
                    DocumentSession.shared.newDocument()
                }
                .keyboardShortcut("n")

                Button("Open…") {
                    DocumentSession.shared.openDocument()
                }
                .keyboardShortcut("o")
            }

            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    DocumentSession.shared.save()
                }
                .keyboardShortcut("s")

                Button("Save As…") {
                    DocumentSession.shared.saveAs()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Divider()

                Button("Move to Trash") {
                    DocumentSession.shared.moveToTrash()
                }
                .keyboardShortcut(.delete, modifiers: [.command])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        DocumentSession.shared.prepareForTermination() ? .terminateNow : .terminateCancel
    }
}
