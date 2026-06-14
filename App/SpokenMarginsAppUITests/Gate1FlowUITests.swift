import XCTest

final class Gate1FlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
    }

    func testSeededGate1FlowHasVisibleFeedbackPlaybackExportAndSettings() throws {
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Spoken Margins"].exists)

        let reset = app.buttons["reset.samples.button"]
        XCTAssertTrue(reset.waitForExistence(timeout: 4))
        reset.tap()
        XCTAssertTrue(app.staticTexts["Listening queue ready."].waitForExistence(timeout: 4))

        let seededStart = app.buttons["queue.start.item-pill"]
        XCTAssertTrue(seededStart.waitForExistence(timeout: 4))
        seededStart.tap()

        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 4))
        XCTAssertTrue(element("timeline.section").waitForExistence(timeout: 4))
        XCTAssertTrue(element("conversation.section").waitForExistence(timeout: 4))

        app.buttons["playback.forward.button"].tap()
        XCTAssertTrue(app.staticTexts["Skipped forward."].waitForExistence(timeout: 4))
        app.buttons["playback.back.button"].tap()
        XCTAssertTrue(app.staticTexts["Skipped back."].waitForExistence(timeout: 4))

        app.buttons["playback.export.button"].tap()
        XCTAssertTrue(element("export.screen").waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Built session export."].waitForExistence(timeout: 4))
        XCTAssertTrue(element("export.preview").waitForExistence(timeout: 4))

        app.buttons["export.home.button"].tap()
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 4))
        app.buttons["home.settings.button"].tap()

        XCTAssertTrue(element("settings.screen").waitForExistence(timeout: 4))
        XCTAssertTrue(app.textFields["provider.baseURL.field"].exists)
        XCTAssertTrue(app.textFields["provider.model.field"].exists)
        XCTAssertTrue(app.secureTextFields["provider.apiKey.field"].exists)
        XCTAssertTrue(app.buttons["provider.save.button"].exists)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }
}
