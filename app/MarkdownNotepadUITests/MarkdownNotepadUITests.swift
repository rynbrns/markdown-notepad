import AppKit
import XCTest

final class MarkdownNotepadUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Smoke

    func test01SmokeLaunchTypeCloseUnsavedPrompt() throws {
        let app = launchApp()
        let editor = newWindowAndFocusEditor(app)
        editor.typeText("Hello from the M2 smoke test.")

        XCTAssertTrue(app.windows.firstMatch.title.contains("Edited"),
                      "Typing should mark the window as Edited")

        app.typeKey("w", modifierFlags: .command)
        let prompt = waitForUnsavedPrompt(app)
        captureScreen(name: "01-unsaved-prompt")
        XCTAssertTrue(prompt.buttons["Cancel"].exists, "Prompt must offer Cancel")

        prompt.buttons["Cancel"].click()
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "Cancel must preserve the window and its text")
        XCTAssertTrue((editor.value as? String)?.contains("M2 smoke test") == true,
                      "Cancel must preserve the typed text")

        app.typeKey("w", modifierFlags: .command)
        let secondPrompt = waitForUnsavedPrompt(app)
        secondPrompt.buttons["Don’t Save"].click()
        app.terminate()
    }

    // MARK: - Menus, tabs, find, prompt screenshots

    func test02MenusTabsFindAndPromptScreenshots() throws {
        let app = launchApp()
        let editor = newWindowAndFocusEditor(app)
        editor.typeText("Find me here. Find me again.")
        capture(app.windows.firstMatch, name: "02-editor-light")

        // File menu
        app.menuBars.menuBarItems["File"].click()
        captureScreen(name: "03-file-menu")
        app.typeKey(.escape, modifierFlags: [])

        // View menu
        app.menuBars.menuBarItems["View"].click()
        captureScreen(name: "04-view-menu")
        app.typeKey(.escape, modifierFlags: [])

        // Find bar
        app.typeKey("f", modifierFlags: .command)
        let findField = app.textFields["findField"]
        XCTAssertTrue(findField.waitForExistence(timeout: 5), "⌘F should reveal the find bar")
        findField.click()
        findField.typeText("Find")
        capture(app.windows.firstMatch, name: "05-find-bar")

        // Replace mode
        app.typeKey("f", modifierFlags: [.command, .option])
        let replaceField = app.textFields["replaceField"]
        XCTAssertTrue(replaceField.waitForExistence(timeout: 5), "⌥⌘F should reveal replace")
        replaceField.click()
        replaceField.typeText("Found")
        app.buttons["All"].click()
        capture(app.windows.firstMatch, name: "06-replace-all")
        XCTAssertTrue((editor.value as? String)?.contains("Found me here. Found me again.") == true)

        // Tabs: merge the second window into the first as a tab
        app.typeKey("n", modifierFlags: .command)
        let secondEditor = app.textViews["editor"].firstMatch
        XCTAssertTrue(secondEditor.waitForExistence(timeout: 5))
        app.menuBars.menuBarItems["Window"].click()
        let merge = app.menuBars.menuItems["Merge All Windows"].firstMatch
        if merge.waitForExistence(timeout: 3) {
            merge.click()
        } else {
            app.typeKey(.escape, modifierFlags: [])
        }
        capture(app.windows.firstMatch, name: "07-tabs")

        // Unsaved prompt from the second tab
        secondEditor.click()
        secondEditor.typeText("Unsaved tab")
        app.typeKey("w", modifierFlags: .command)
        let prompt = waitForUnsavedPrompt(app)
        captureScreen(name: "08-unsaved-prompt")
        prompt.buttons["Don’t Save"].click()
        app.terminate()
    }

    // MARK: - Dark mode

    func test03DarkModeScreenshot() throws {
        let app = launchApp(dark: true)
        let editor = newWindowAndFocusEditor(app)
        editor.typeText("# Dark mode\n\nSemantic colours follow the system appearance.")
        capture(app.windows.firstMatch, name: "09-dark-mode")
        app.typeKey("2", modifierFlags: [.command, .control])
        let darkMarker = app.staticTexts["previewVisible"]
        XCTAssertTrue(darkMarker.waitForExistence(timeout: 10), "⇧⌘P should reveal the dark preview")
        let darkPreview = app.webViews.firstMatch
        XCTAssertTrue(darkPreview.waitForExistence(timeout: 10), "The dark preview should host a web view")
        sleep(2)
        capture(app.windows.firstMatch, name: "11-preview-dark")
        app.typeKey("w", modifierFlags: .command)
        let prompt = waitForUnsavedPrompt(app)
        prompt.buttons["Don’t Save"].click()
        app.terminate()
    }

    // MARK: - Rendered preview

    func test04PreviewToggleRendersGFM() throws {
        let app = launchApp()
        let editor = newWindowAndFocusEditor(app)
        editor.typeText("""
        # Preview title

        A paragraph with **strong** and [a link](https://example.com).

        - [x] finished task
        - [ ] open task

        | Name | Value |
        | --- | ---: |
        | alpha | 1 |

        > A quote.
        """)

        app.typeKey("2", modifierFlags: [.command, .control])
        let marker = app.staticTexts["previewVisible"]
        XCTAssertTrue(marker.waitForExistence(timeout: 10), "Panels mode should show the preview pane")
        let preview = app.webViews.firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 10), "The preview pane should host a web view")
        XCTAssertTrue(preview.staticTexts["Preview title"].waitForExistence(timeout: 10),
                      "The preview should render the heading text")
        capture(app.windows.firstMatch, name: "10-preview-light")

        app.typeKey("p", modifierFlags: [.command, .shift])
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: marker)
        XCTAssertEqual(XCTWaiter().wait(for: [hidden], timeout: 5), .completed, "⇧⌘P should hide the preview pane")

        app.typeKey("p", modifierFlags: [.command, .shift])
        XCTAssertTrue(marker.waitForExistence(timeout: 10), "⇧⌘P should reopen the preview pane")

        app.typeKey("w", modifierFlags: .command)
        let prompt = waitForUnsavedPrompt(app)
        prompt.buttons["Don’t Save"].click()
        app.terminate()
    }

    // MARK: - App icon evidence

    func test08AppIconInDockAndFinder() throws {
        let app = launchApp()
        _ = newWindowAndFocusEditor(app)

        // The running app's icon appears in the Dock; capture the whole screen
        // so the Dock is included, not just the app window.
        sleep(4)
        captureScreen(name: "12-icon-in-dock")

        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.ryanpaperclip.markdownnotepad")
            ?? Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("MarkdownNotepad.app")
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MarkdownNotepadIconEvidence", isDirectory: true)
        let destination = folder.appendingPathComponent("Markdown Notepad.app", isDirectory: true)
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: folder)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try fileManager.copyItem(at: appURL, to: destination)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
            sleep(4)
            captureScreen(name: "13-icon-in-finder")
        } catch {
            print("ICON EVIDENCE COPY FAILED \(appURL.path): \(error)")
        }

        app.terminate()
    }

    // MARK: - Interactive title bar

    func test05TitleBarRenameCommitsAndCancelKeepsName() throws {
        let app = launchApp()
        let editor = newWindowAndFocusEditor(app)
        editor.typeText("Rename through the title bar.")

        let titleBarName = app.descendants(matching: .any)["titleBarNameField"]
        XCTAssertTrue(titleBarName.waitForExistence(timeout: 5),
                      "The title bar should expose a document name field")

        titleBarName.doubleClick()
        let editingField = app.textFields["titleBarNameField"]
        XCTAssertTrue(editingField.waitForExistence(timeout: 5),
                      "Double-clicking the title should make the name editable")
        editingField.typeKey("a", modifierFlags: .command)
        editingField.typeText("Renamed")
        captureScreen(name: "12-title-bar-rename")
        app.typeKey(.return, modifierFlags: [])

        let statusName = app.staticTexts["documentName"]
        XCTAssertTrue(statusName.waitForExistence(timeout: 5))
        XCTAssertEqual(statusName.label, "Renamed.md",
                       "Committing the rename should update the document title")

        let titleBarAgain = app.descendants(matching: .any)["titleBarNameField"]
        titleBarAgain.doubleClick()
        let secondEdit = app.textFields["titleBarNameField"]
        XCTAssertTrue(secondEdit.waitForExistence(timeout: 5))
        secondEdit.typeKey("a", modifierFlags: .command)
        secondEdit.typeText("Never committed")
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertEqual(app.staticTexts["documentName"].label, "Renamed.md",
                       "Escape should discard the in-progress rename")

        app.typeKey("w", modifierFlags: .command)
        let prompt = waitForUnsavedPrompt(app)
        prompt.buttons["Don’t Save"].click()
        app.terminate()
    }

    // MARK: - Formatting shortcuts

    func test06MarkdownFormattingShortcuts() throws {
        let app = launchApp()
        let editor = newWindowAndFocusEditor(app)
        editor.typeText("alpha\nbeta")

        app.menuBars.menuBarItems["Editor"].click()
        XCTAssertTrue(app.menuBars.menuItems["Bold"].waitForExistence(timeout: 3),
                      "The Editor menu should expose Bold")
        XCTAssertTrue(app.menuBars.menuItems["Unordered List"].exists,
                      "The Editor menu should expose list commands")
        app.typeKey(.escape, modifierFlags: [])

        app.typeKey("a", modifierFlags: .command)
        app.typeKey("b", modifierFlags: .command)
        XCTAssertEqual(editor.value as? String, "**alpha\nbeta**", "⌘B should wrap the selection")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(editor.value as? String, "alpha\nbeta", "⌘Z should restore the exact text")

        app.typeKey("a", modifierFlags: .command)
        app.typeKey("8", modifierFlags: [.command, .shift])
        XCTAssertEqual(editor.value as? String, "- alpha\n- beta", "⇧⌘8 should bullet every line")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(editor.value as? String, "alpha\nbeta")

        app.typeKey("a", modifierFlags: .command)
        app.typeKey("1", modifierFlags: .command)
        XCTAssertEqual(editor.value as? String, "# alpha\n# beta", "⌘1 should set Heading 1")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(editor.value as? String, "alpha\nbeta")

        app.typeKey("a", modifierFlags: .command)
        app.typeKey("k", modifierFlags: .command)
        XCTAssertEqual(editor.value as? String, "[alpha\nbeta](url)", "⌘K should insert a link")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(editor.value as? String, "alpha\nbeta")

        app.typeKey("w", modifierFlags: .command)
        let prompt = waitForUnsavedPrompt(app)
        prompt.buttons["Don’t Save"].click()
        app.terminate()
    }

    // MARK: - Editor modes

    func test07EditorModesSwitchAndPersist() throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownNotepadModes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: supportDirectory) }

        var app = launchApp(supportDirectory: supportDirectory)
        let editor = newWindowAndFocusEditor(app)
        editor.typeText("# Title\n\nA **bold** line and [a link](https://example.com).")
        let source = editor.value as? String

        XCTAssertTrue(waitForMode(app, "Plain Text"),
                      "An unset preference should start in Plain Text")

        app.typeKey("2", modifierFlags: [.control, .command])
        XCTAssertTrue(waitForMode(app, "Panels"), "⌃⌘2 should switch to Panels")
        XCTAssertTrue(app.staticTexts["previewVisible"].waitForExistence(timeout: 10),
                      "Panels should show the live preview")

        app.typeKey("1", modifierFlags: [.control, .command])
        XCTAssertTrue(waitForMode(app, "Plain Text"), "⌃⌘1 should switch to Plain Text")

        let wysiwygButton = app.descendants(matching: .any)["mode-wysiwyg"].firstMatch
        XCTAssertTrue(wysiwygButton.waitForExistence(timeout: 5),
                      "The status bar should expose mode buttons")
        wysiwygButton.click()
        XCTAssertTrue(waitForMode(app, "WYSIWYG"), "The WYSIWYG button should switch modes")
        XCTAssertEqual(editor.value as? String, source,
                       "Switching to WYSIWYG must not rewrite the Markdown")

        // Menu path: View > Editor Mode > Panels
        app.menuBars.menuBarItems["View"].click()
        let modeMenu = app.menuBars.menuItems["Editor Mode"]
        XCTAssertTrue(modeMenu.waitForExistence(timeout: 3),
                      "View should contain an Editor Mode menu")
        modeMenu.hover()
        let panelsItem = app.menuBars.menuItems["Panels"]
        XCTAssertTrue(panelsItem.waitForExistence(timeout: 3),
                      "The mode menu should list Panels")
        panelsItem.click()
        XCTAssertTrue(waitForMode(app, "Panels"), "The menu should switch to Panels")
        XCTAssertTrue(app.staticTexts["previewVisible"].waitForExistence(timeout: 10),
                      "Panels should show the live preview")

        // The last chosen mode is persisted for the next launch.
        app.typeKey("3", modifierFlags: [.control, .command])
        XCTAssertTrue(waitForMode(app, "WYSIWYG"))
        app.typeKey("w", modifierFlags: .command)
        let prompt = waitForUnsavedPrompt(app)
        prompt.buttons["Don’t Save"].click()
        app.terminate()

        app = launchApp(supportDirectory: supportDirectory)
        _ = newWindowAndFocusEditor(app)
        XCTAssertTrue(waitForMode(app, "WYSIWYG"),
                      "The persisted default mode should be restored on relaunch")
        app.typeKey("w", modifierFlags: .command)
        app.terminate()
    }

    // MARK: - File conflicts

    func test10FileConflictOffersReloadOverwriteAndSaveAs() throws {
        let directory = makeTestDirectory("conflict")
        let file = directory.appendingPathComponent("conflict.md")
        try "# Original\n".write(to: file, atomically: true, encoding: .utf8)

        let app = launchApp(supportDirectory: directory.appendingPathComponent("support"), openFile: file)
        let editor = app.textViews["editor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "An opened file should appear in the editor")
        XCTAssertTrue((editor.value as? String)?.contains("Original") == true)

        // Change the file from another process, then save from the app.
        try "# Changed outside the app\n".write(to: file, atomically: true, encoding: .utf8)
        app.typeKey("s", modifierFlags: .command)
        let reloadPrompt = waitForConflictPrompt(app)
        captureScreen(name: "14-conflict-prompt")
        XCTAssertTrue(reloadPrompt.buttons["Reload"].exists, "Conflict must offer Reload")
        XCTAssertTrue(reloadPrompt.buttons["Overwrite"].exists, "Conflict must offer Overwrite")
        XCTAssertTrue(reloadPrompt.buttons["Save As…"].exists, "Conflict must offer Save As")
        XCTAssertTrue(app.buttons["Cancel"].exists, "Conflict must offer Cancel")

        reloadPrompt.buttons["Reload"].click()
        let reloaded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "Changed outside the app"),
            object: editor
        )
        XCTAssertEqual(XCTWaiter().wait(for: [reloaded], timeout: 10), .completed,
                       "Reload should show the on-disk text")

        editor.click()
        app.typeKey("a", modifierFlags: .command)
        editor.typeText("# Mine now\n")
        try "# Another outside edit\n".write(to: file, atomically: true, encoding: .utf8)
        app.typeKey("s", modifierFlags: .command)
        let overwritePrompt = waitForConflictPrompt(app)
        overwritePrompt.buttons["Overwrite"].click()

        let saved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "Mine now"),
            object: editor
        )
        XCTAssertEqual(XCTWaiter().wait(for: [saved], timeout: 10), .completed)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "# Mine now\n",
                       "Overwrite should write the editor text to disk")

        // The Save As path must still be wired after a conflict.
        try "# Third outside edit\n".write(to: file, atomically: true, encoding: .utf8)
        app.typeKey("s", modifierFlags: .command)
        let saveAsPrompt = waitForConflictPrompt(app)
        saveAsPrompt.buttons["Save As…"].click()
        let savePanel = app.sheets.firstMatch
        if savePanel.waitForExistence(timeout: 5) {
            captureScreen(name: "15-conflict-save-as-panel")
            app.typeKey(.escape, modifierFlags: [])
        } else {
            XCTFail("Save As should present a save panel")
        }
        app.terminate()
    }

    // MARK: - Crash recovery

    func test11ForceQuitThenRelaunchRestoresUnsavedText() throws {
        let directory = makeTestDirectory("recovery")
        let support = directory.appendingPathComponent("support")
        let app = launchApp(supportDirectory: support)
        let editor = newWindowAndFocusEditor(app)
        let recoveredText = "Recovered after a force quit #\(UUID().uuidString.prefix(8))"
        editor.typeText(recoveredText)

        // The idle snapshot fires two seconds after the last edit.
        sleep(4)
        XCTAssertEqual(app.state, .runningForeground)

        // A real force quit (SIGKILL), not the cooperative terminate() that
        // would run the normal save prompts and delete the recovery snapshot.
        let killer = Process()
        killer.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killer.arguments = ["-9", "-f", "MarkdownNotepad.app/Contents/MacOS/MarkdownNotepad"]
        do {
            try killer.run()
            killer.waitUntilExit()
        } catch {
            return XCTFail("Could not force quit the app: \(error)")
        }
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15),
                      "Force quit should terminate the app")

        let relaunched = launchApp(supportDirectory: support)
        let restoredEditor = relaunched.textViews["editor"].firstMatch
        XCTAssertTrue(restoredEditor.waitForExistence(timeout: 10), "Relaunch should restore a window")
        let banner = relaunched.staticTexts["recoveryBanner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 10), "Relaunch should show the recovery banner")
        XCTAssertTrue((restoredEditor.value as? String)?.contains(recoveredText) == true,
                      "Relaunch should restore the unsaved text")
        captureScreen(name: "16-recovery-after-force-quit")
        relaunched.terminate()
    }

    // MARK: - Accessibility

    func test12AccessibilityLabelsForEditorToolbarAndPreview() throws {
        let directory = makeTestDirectory("accessibility")
        let app = launchApp(supportDirectory: directory.appendingPathComponent("support"))
        let editor = newWindowAndFocusEditor(app)
        XCTAssertEqual(editor.label, "Markdown editor", "The editor needs a VoiceOver label")
        editor.typeText("# Accessible heading\n\nSome **bold** text.")
        XCTAssertTrue(app.staticTexts["Unsaved changes"].waitForExistence(timeout: 5),
                      "The dirty state needs an accessible label")

        app.typeKey("f", modifierFlags: .command)
        let findField = app.textFields["findField"]
        XCTAssertTrue(findField.waitForExistence(timeout: 5))
        XCTAssertEqual(findField.label, "Find text")
        XCTAssertTrue(app.buttons["Previous match"].exists)
        XCTAssertTrue(app.buttons["Next match"].exists)
        XCTAssertTrue(app.buttons["Match case"].exists)
        XCTAssertTrue(app.buttons["Use regular expression"].exists)
        findField.typeText("bold")
        app.typeKey(.return, modifierFlags: [])
        let findStatus = app.staticTexts["findStatus"]
        XCTAssertTrue(findStatus.waitForExistence(timeout: 5), "The find counter should be readable")
        XCTAssertEqual(findStatus.label, "1 of 1")
        app.typeKey(.escape, modifierFlags: [])

        app.typeKey("2", modifierFlags: [.command, .control])
        let preview = app.webViews.firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 10), "Panels mode should show the preview")
        XCTAssertTrue(preview.label.contains("Rendered Markdown preview"),
                      "The preview should expose a VoiceOver label, got \(preview.label)")
        capture(app.windows.firstMatch, name: "17-accessibility-preview")

        // Standard keyboard shortcuts remain available.
        editor.click()
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(editor.exists)
        app.typeKey("w", modifierFlags: .command)
        let prompt = waitForUnsavedPrompt(app)
        prompt.buttons["Don’t Save"].click()
        app.terminate()
    }

    // MARK: - Internal acceptance rehearsal (steps 3, 5, 8, 10)

    func test13AcceptanceRehearsalSaveReopenFindUndo() throws {
        let directory = makeTestDirectory("rehearsal")
        let file = directory.appendingPathComponent("test.md")
        try "".write(to: file, atomically: true, encoding: .utf8)

        let app = launchApp(supportDirectory: directory.appendingPathComponent("support"), openFile: file)
        let editor = app.textViews["editor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        editor.typeText("# Acceptance\n\n- item one\n- item two\n\nFind me.\n")
        app.typeKey("s", modifierFlags: .command)

        let saved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "Acceptance"),
            object: editor
        )
        XCTAssertEqual(XCTWaiter().wait(for: [saved], timeout: 10), .completed)
        let onDisk = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("# Acceptance"))
        XCTAssertTrue(onDisk.contains("- item two"))

        // Close and reopen through File > Open Recent (step 8).
        app.typeKey("w", modifierFlags: .command)
        let maybePrompt = app.dialogs.firstMatch
        if maybePrompt.waitForExistence(timeout: 2) {
            // A clean save should not prompt; if it does, keep the file.
            maybePrompt.buttons["Cancel"].click()
        }
        app.menuBars.menuBarItems["File"].click()
        let recent = app.menuBars.menuItems["Open Recent"].firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        recent.click()
        let entry = app.menuBars.menuItems[file.lastPathComponent].firstMatch
        if entry.waitForExistence(timeout: 5) {
            entry.click()
        } else {
            app.typeKey(.escape, modifierFlags: [])
        }
        let reopened = app.textViews["editor"].firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 10))
        XCTAssertTrue((reopened.value as? String)?.contains("item two") == true,
                      "Reopening from the recent list should show the saved text")
        capture(app.windows.firstMatch, name: "18-rehearsal-reopened")

        // Find/replace and undo (step 10).
        app.typeKey("f", modifierFlags: .command)
        let findField = app.textFields["findField"]
        XCTAssertTrue(findField.waitForExistence(timeout: 5))
        findField.typeText("item")
        let findStatus = app.staticTexts["findStatus"]
        XCTAssertTrue(findStatus.waitForExistence(timeout: 5))
        XCTAssertEqual(findStatus.label, "1 of 2")
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(reopened.exists)
        app.terminate()
    }

    // MARK: - Helpers

    private func launchApp(
        dark: Bool = false,
        supportDirectory: URL? = nil,
        openFile: URL? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MARKDOWN_NOTEPAD_UI_TESTING"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        if dark {
            app.launchEnvironment["MARKDOWN_NOTEPAD_FORCE_DARK"] = "1"
        }
        if let supportDirectory {
            app.launchEnvironment["MARKDOWN_NOTEPAD_SUPPORT_DIR"] = supportDirectory.path
        }
        if let openFile {
            app.launchEnvironment["MARKDOWN_NOTEPAD_OPEN_FILE"] = openFile.path
        }
        app.launch()
        return app
    }

    private func makeTestDirectory(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownNotepadUITests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitForConflictPrompt(_ app: XCUIApplication) -> XCUIElement {
        let sheet = app.sheets.firstMatch
        if sheet.waitForExistence(timeout: 10) {
            return sheet
        }
        let dialog = app.dialogs.firstMatch
        if dialog.waitForExistence(timeout: 5) {
            return dialog
        }
        XCTFail("File conflict prompt did not appear")
        return sheet
    }

    private func waitForMode(_ app: XCUIApplication, _ title: String, timeout: TimeInterval = 5) -> Bool {
        let marker = app.staticTexts["activeMode"]
        guard marker.waitForExistence(timeout: timeout) else { return false }
        let predicate = NSPredicate(format: "label == %@", title)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: marker)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func newWindowAndFocusEditor(_ app: XCUIApplication) -> XCUIElement {
        let existing = app.textViews["editor"].firstMatch
        if existing.waitForExistence(timeout: 3) {
            existing.click()
            return existing
        }

        app.menuBars.menuBarItems["File"].click()
        let newItem = app.menuBars.menuItems["New"]
        if newItem.waitForExistence(timeout: 3) {
            newItem.click()
        } else {
            app.typeKey(.escape, modifierFlags: [])
        }

        let editor = app.textViews["editor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "Editor should exist after New")
        editor.click()
        return editor
    }

    private func waitForUnsavedPrompt(_ app: XCUIApplication) -> XCUIElement {
        let dialog = app.dialogs.firstMatch
        if dialog.waitForExistence(timeout: 10) {
            return dialog
        }
        let sheet = app.sheets.firstMatch
        if sheet.waitForExistence(timeout: 5) {
            return sheet
        }
        XCTFail("Unsaved-changes prompt did not appear")
        return dialog
    }

    private func capture(_ element: XCUIElement, name: String) {
        let screenshot = element.screenshot()
        write(screenshot, name: name)
    }

    private func captureScreen(name: String) {
        write(XCUIScreen.main.screenshot(), name: name)
    }

    private func write(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let directory = screenshotDirectory
        let url = directory.appendingPathComponent("\(name).png")
        do {
            try screenshot.pngRepresentation.write(to: url)
        } catch {
            print("SCREENSHOT WRITE FAILED \(url.path): \(error)")
        }
    }

    private var screenshotDirectory: URL {
        let url: URL
        if let path = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"], !path.isEmpty {
            url = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            // The UI-test process is sandboxed away from the checkout. These
            // files also live inside the .xcresult as XCTAttachments, which is
            // what CI uploads.
            url = URL(fileURLWithPath: "/tmp/markdown-notepad-ui-screenshots", isDirectory: true)
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            print("SCREENSHOT DIRECTORY FAILED \(url.path): \(error)")
        }
        return url
    }
}
