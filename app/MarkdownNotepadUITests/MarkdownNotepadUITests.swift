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
        capture(app.windows.firstMatch, name: "01-unsaved-prompt")
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
        let count = app.staticTexts["findMatchCount"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertEqual(count.label, "1 of 2", "Case-insensitive default should find both matches")
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

        // Tabs: a second window should merge into the first as a tab
        app.typeKey("n", modifierFlags: .command)
        let secondEditor = app.textViews["editor"].firstMatch
        XCTAssertTrue(secondEditor.waitForExistence(timeout: 5))
        capture(app.windows.firstMatch, name: "07-tabs")

        // Unsaved prompt from the second tab
        secondEditor.click()
        secondEditor.typeText("Unsaved tab")
        app.typeKey("w", modifierFlags: .command)
        let prompt = waitForUnsavedPrompt(app)
        capture(app.windows.firstMatch, name: "08-unsaved-prompt")
        prompt.buttons["Don’t Save"].click()
        app.terminate()
    }

    // MARK: - Dark mode

    func test03DarkModeScreenshot() throws {
        let app = launchApp(dark: true)
        let editor = newWindowAndFocusEditor(app)
        editor.typeText("# Dark mode\n\nSemantic colours follow the system appearance.")
        capture(app.windows.firstMatch, name: "09-dark-mode")
        app.typeKey("w", modifierFlags: .command)
        let prompt = waitForUnsavedPrompt(app)
        prompt.buttons["Don’t Save"].click()
        app.terminate()
    }

    // MARK: - Helpers

    private func launchApp(dark: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MARKDOWN_NOTEPAD_UI_TESTING"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        if dark {
            app.launchArguments += ["-AppleInterfaceStyle", "Dark"]
        }
        app.launch()
        return app
    }

    private func newWindowAndFocusEditor(_ app: XCUIApplication) -> XCUIElement {
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
        try? screenshot.pngRepresentation.write(to: url)
    }

    private var screenshotDirectory: URL {
        let path = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] ?? NSTemporaryDirectory()
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
