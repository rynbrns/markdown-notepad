import AppKit
import XCTest

final class MarkdownNotepadUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Launch

    func test00ColdLaunchOpensOneBlankWindowWithEditorFocus() throws {
        let app = launchApp()
        addTeardownBlock { app.terminate() }

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "Cold launch should present a window")

        let editor = app.textViews["editor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "Cold launch should present an editor")
        XCTAssertEqual(app.windows.count, 1, "Cold launch should create exactly one window")
        XCTAssertEqual(app.staticTexts["documentName"].firstMatch.value as? String, "Untitled",
                       "The launch window should be untitled")
        XCTAssertEqual(editor.value as? String, "", "The launch window should be empty")

        app.typeText("Cold launch focus")
        XCTAssertTrue((editor.value as? String)?.contains("Cold launch focus") == true,
                      "The new window should start with keyboard focus in the editor")

        app.typeKey("w", modifierFlags: .command)
        let prompt = waitForUnsavedPrompt(app)
        prompt.buttons["Don’t Save"].click()
        app.terminate()
    }

    func test00bReopenWithNoWindowsOpensOneBlankWindow() throws {
        let app = launchApp()
        addTeardownBlock { app.terminate() }
        let editor = app.textViews["editor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "Cold launch should present an editor")

        // The blank untitled window is clean, so ⌘W closes it without a prompt.
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitForWindowCount(0, in: app, timeout: 10),
                      "Closing the only clean window should leave the app running with no windows")

        // Dock click / re-open while the app is running with no windows.
        reopenRunningApp()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10),
                      "Reopening with no windows should present a blank window")
        XCTAssertEqual(app.windows.count, 1, "Reopening should create exactly one window")
        XCTAssertTrue(app.textViews["editor"].firstMatch.waitForExistence(timeout: 10),
                      "The reopened window should be an editor")
        XCTAssertEqual(app.staticTexts["documentName"].firstMatch.value as? String, "Untitled",
                       "The reopened window should be a new untitled document")
        app.terminate()
    }

    func test00cLaunchingWithFileOpensOnlyThatFile() throws {
        // CI creates this fixture in a shared location; XCUITest's sandbox
        // cannot write to /tmp and the app cannot read the runner container.
        let file = URL(fileURLWithPath: "/tmp/markdown-notepad-rya16/opened.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                      "Missing UI-test fixture: \(file.path)")

        let app = launchApp(openingFile: file)
        addTeardownBlock { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10),
                      "Launching with a file should present a window")
        XCTAssertEqual(app.windows.count, 1,
                       "Launching with a file should not leave an extra blank window")

        let name = app.staticTexts["documentName"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 10), "The opened file should be shown")
        let loaded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "opened"),
            object: name
        )
        XCTAssertEqual(XCTWaiter().wait(for: [loaded], timeout: 10), .completed,
                       "Launching with a file should load it")

        let editor = app.textViews["editor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "The file window should contain an editor")
        XCTAssertTrue((editor.value as? String)?.contains("Opened from Finder") == true,
                      "The opened file content should be visible in the editor")
        app.terminate()
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
        app.typeKey("p", modifierFlags: [.command, .shift])
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

        app.typeKey("p", modifierFlags: [.command, .shift])
        let marker = app.staticTexts["previewVisible"]
        XCTAssertTrue(marker.waitForExistence(timeout: 10), "⇧⌘P should open the preview pane")
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

        let titleBarName = app.descendants(matching: .any)
            .matching(identifier: "titleBarNameField").firstMatch
        XCTAssertTrue(titleBarName.waitForExistence(timeout: 5),
                      "The title bar should expose a document name field")

        titleBarName.doubleClick()
        let editingField = app.textFields.matching(identifier: "titleBarNameField").firstMatch
        XCTAssertTrue(editingField.waitForExistence(timeout: 5),
                      "Double-clicking the title should make the name editable")
        editingField.typeKey("a", modifierFlags: .command)
        editingField.typeText("Renamed")
        captureScreen(name: "12-title-bar-rename")
        app.typeKey(.return, modifierFlags: [])

        let window = app.windows.firstMatch
        let renamed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "title CONTAINS %@", "Renamed"),
            object: window
        )
        XCTAssertEqual(XCTWaiter().wait(for: [renamed], timeout: 5), .completed,
                       "Committing the rename should update the window title")

        let titleBarAgain = app.descendants(matching: .any)
            .matching(identifier: "titleBarNameField").firstMatch
        titleBarAgain.doubleClick()
        let secondEdit = app.textFields.matching(identifier: "titleBarNameField").firstMatch
        XCTAssertTrue(secondEdit.waitForExistence(timeout: 5))
        secondEdit.typeKey("a", modifierFlags: .command)
        secondEdit.typeText("Never committed")
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(window.title.contains("Renamed"),
                      "Escape should discard the in-progress rename")
        XCTAssertFalse(window.title.contains("Never committed"),
                       "Escape must not commit the edited name")

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
        editor.click()

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

    // MARK: - Helpers

    private func launchApp(
        dark: Bool = false,
        supportDirectory: URL? = nil,
        openingFile: URL? = nil
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
        if let openingFile {
            app.launchEnvironment["MARKDOWN_NOTEPAD_UI_TEST_OPEN_FILE"] = openingFile.path
        }
        app.launch()
        return app
    }

    private func waitForMode(_ app: XCUIApplication, _ title: String, timeout: TimeInterval = 5) -> Bool {
        guard let rawValue = modeRawValue(for: title) else {
            XCTFail("Unknown editor mode \(title)")
            return false
        }
        let marker = app.descendants(matching: .any)["activeMode-\(rawValue)"].firstMatch
        return marker.waitForExistence(timeout: timeout)
    }

    private func modeRawValue(for title: String) -> String? {
        switch title {
        case "Plain Text":
            return "plainText"
        case "Panels":
            return "panels"
        case "WYSIWYG":
            return "wysiwyg"
        default:
            return nil
        }
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

    /// The app bundle launched by the test run, as registered with Launch
    /// Services. The UI-test runner is sandboxed, so the checkout path in an
    /// environment variable is not reliable; Launch Services knows the bundle.
    private func appUnderTestURL() -> URL? {
        NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.ryanpaperclip.markdownnotepad"
        )
    }

    /// Sends the same Launch Services re-open event as a Dock click or opening
    /// the app again while it is running. `XCUIApplication.activate()` alone
    /// does not deliver `applicationShouldHandleReopen`.
    private func reopenRunningApp() {
        guard let appURL = appUnderTestURL() else {
            XCTFail("Could not find the app bundle under test in Launch Services")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let opened = expectation(description: "reopen the running app")
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if let error { print("REOPEN ERROR: \(error)") }
            opened.fulfill()
        }
        wait(for: [opened], timeout: 10)
    }

    private func waitForWindowCount(_ count: Int, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.windows.count == count { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return app.windows.count == count
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
