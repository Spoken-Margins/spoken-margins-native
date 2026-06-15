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
        XCTAssertTrue(app.textFields["provider.mapModel.field"].exists)
        XCTAssertTrue(app.textFields["provider.summaryModel.field"].exists)
        XCTAssertTrue(app.textFields["provider.conversationModel.field"].exists)
        XCTAssertTrue(app.secureTextFields["provider.apiKey.field"].exists)
        XCTAssertTrue(app.buttons["provider.save.button"].exists)
    }

    func testManualListeningMapJSONCanBeAppliedFromItemScreen() throws {
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8))

        let seededItem = app.buttons["queue.row.item-pill"]
        XCTAssertTrue(seededItem.waitForExistence(timeout: 4))
        seededItem.tap()
        XCTAssertTrue(element("item.screen").waitForExistence(timeout: 4))

        let showManualJSON = scrollToElement("item.toggleMapJSON.button")
        showManualJSON.tap()

        let editor = scrollToElement("item.mapJSON.editor")
        editor.tap()
        editor.typeText(Self.manualListeningMapJSON)

        let apply = scrollToElement("item.applyMap.button")
        apply.tap()

        XCTAssertTrue(app.staticTexts["Applied Listening Map."].waitForExistence(timeout: 4))
        XCTAssertTrue(scrollToElement("chapter.jump.manual-process").exists)
    }

    func testGeneratedTurnTimelineRowsAreLabeledAndTappable() throws {
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8))
        let reset = app.buttons["reset.samples.button"]
        XCTAssertTrue(reset.waitForExistence(timeout: 4))
        reset.tap()

        let seededStart = app.buttons["queue.start.item-pill"]
        XCTAssertTrue(seededStart.waitForExistence(timeout: 4))
        seededStart.tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 4))

        XCTAssertTrue(scrollToStaticText("Can you respond to my interjection?").exists)
        XCTAssertTrue(app.staticTexts["YOU"].exists)
        XCTAssertTrue(scrollToStaticText("AI Response 1").exists)
        XCTAssertTrue(app.staticTexts["AI"].exists)
        XCTAssertFalse(app.staticTexts["Play full generated response"].exists)

        let aiResponse = scrollToButton(containingLabel: "Here is a quick response to your interjection.")
        aiResponse.tap()
        XCTAssertTrue(app.staticTexts["Playing AI response."].waitForExistence(timeout: 4))

        let aiChapter = scrollToButton(containingLabel: "Timeline Navigation")
        aiChapter.tap()
        XCTAssertTrue(app.staticTexts["Jumped to Timeline Navigation."].waitForExistence(timeout: 4))
    }

    func testExportAfterTwoSessionsStaysSessionIsolated() throws {
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8))
        let reset = app.buttons["reset.samples.button"]
        XCTAssertTrue(reset.waitForExistence(timeout: 4))
        reset.tap()

        let seededStart = app.buttons["queue.start.item-pill"]
        XCTAssertTrue(seededStart.waitForExistence(timeout: 4))
        seededStart.tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 4))
        app.buttons["playback.export.button"].tap()
        XCTAssertTrue(element("export.screen").waitForExistence(timeout: 4))
        let firstExport = element("export.preview").label
        XCTAssertTrue(firstExport.contains("\"session\""))

        app.buttons["export.home.button"].tap()
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 4))
        XCTAssertTrue(seededStart.waitForExistence(timeout: 4))
        seededStart.tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 4))
        app.buttons["playback.export.button"].tap()
        XCTAssertTrue(element("export.screen").waitForExistence(timeout: 4))
        let secondExport = element("export.preview").label

        XCTAssertTrue(secondExport.contains("\"session\""))
        XCTAssertNotEqual(firstExport, secondExport)
    }

    func testGate2CompactValidationControlsDelegateTransportCommands() throws {
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8))
        let reset = app.buttons["reset.samples.button"]
        XCTAssertTrue(reset.waitForExistence(timeout: 4))
        reset.tap()

        let seededStart = app.buttons["queue.start.item-pill"]
        XCTAssertTrue(seededStart.waitForExistence(timeout: 4))
        seededStart.tap()

        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Gate 2 Compact"].waitForExistence(timeout: 4))
        XCTAssertTrue(element("gate2.compact.chapter").label.contains("Reasonable distrust"))

        app.buttons["gate2.compact.playPause.button"].tap()
        XCTAssertTrue(app.staticTexts["Compact control togglePlayPause delegated."].waitForExistence(timeout: 4))

        app.buttons["gate2.compact.forward.button"].tap()
        XCTAssertTrue(app.staticTexts["Compact control skipForward delegated."].waitForExistence(timeout: 4))
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func scrollToElement(_ identifier: String) -> XCUIElement {
        let candidate = element(identifier)
        for _ in 0..<6 where !candidate.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(candidate.waitForExistence(timeout: 4), "Missing \(identifier)")
        return candidate
    }

    private func scrollToStaticText(_ text: String) -> XCUIElement {
        let candidate = app.staticTexts[text]
        for _ in 0..<6 where !candidate.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(candidate.waitForExistence(timeout: 4), "Missing \(text)")
        return candidate
    }

    private func scrollToButton(containingLabel text: String) -> XCUIElement {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let candidate = app.buttons.matching(predicate).firstMatch
        for _ in 0..<6 where !candidate.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(candidate.waitForExistence(timeout: 4), "Missing button containing \(text)")
        return candidate
    }

    private static let manualListeningMapJSON = """
    {"schemaVersion":"listening-map.v1","overview":"Manual validation map.","chapters":[{"id":"manual-opening","title":"Manual Opening","description":"The item grants distrust.","anchor":"Opening distrust is reasonable."},{"id":"manual-process","title":"Manual Process","description":"The item shifts the inspection target.","anchor":"The paper trail around the medicine is what can be inspected."}]}
    """
}
