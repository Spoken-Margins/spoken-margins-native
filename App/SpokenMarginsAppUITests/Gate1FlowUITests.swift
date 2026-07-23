import XCTest

final class Gate1FlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["SPOKEN_MARGINS_UI_TESTING"] = "1"
        app.launch()
    }

    func testSeededGate1FlowHasPlaybackMiniPlayerExportAndSettings() throws {
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Spoken Margins"].exists)

        let seededStart = app.buttons["queue.start.item-pill"]
        XCTAssertTrue(seededStart.waitForExistence(timeout: 4))
        seededStart.tap()

        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 4))
        XCTAssertTrue(element("timeline.section").waitForExistence(timeout: 4))
        XCTAssertTrue(element("conversation.section").waitForExistence(timeout: 4))

        app.buttons["playback.forward.button"].tap()
        app.buttons["playback.back.button"].tap()

        app.buttons["playback.export.button"].tap()
        XCTAssertTrue(element("export.screen").waitForExistence(timeout: 4))
        XCTAssertTrue(element("export.preview").waitForExistence(timeout: 4))

        app.buttons["export.home.button"].tap()
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 4))
        XCTAssertTrue(element("miniPlayer.bar").waitForExistence(timeout: 4))
        XCTAssertTrue(element("miniPlayer.close.button").exists)
        XCTAssertTrue(element("miniPlayer.interject.button").exists)
        XCTAssertTrue(element("miniPlayer.playPause.button").exists)
        app.buttons["home.settings.button"].tap()

        XCTAssertTrue(element("settings.screen").waitForExistence(timeout: 4))
        XCTAssertTrue(element("provider.name").waitForExistence(timeout: 4))
        XCTAssertTrue(scrollToElement("provider.apiKey.field").exists)
        XCTAssertTrue(scrollToElement("provider.save.button").exists)
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

        XCTAssertTrue(scrollToElement("chapter.jump.manual-process").exists)
    }

    func testGeneratedTurnTimelineRowsAreLabeledAndTappable() throws {
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8))
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
        XCTAssertTrue(element("playback.title").waitForExistence(timeout: 4))

        let aiChapter = scrollToButton(containingLabel: "Timeline Navigation")
        aiChapter.tap()
        XCTAssertTrue(app.staticTexts["Timeline Navigation"].waitForExistence(timeout: 4))
    }

    func testExportAfterTwoSessionsStaysSessionIsolated() throws {
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8))
        let seededStart = app.buttons["queue.start.item-pill"]
        XCTAssertTrue(seededStart.waitForExistence(timeout: 4))
        seededStart.tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 4))
        app.buttons["playback.export.button"].tap()
        XCTAssertTrue(element("export.screen").waitForExistence(timeout: 4))
        let firstExport = element("export.preview").label
        XCTAssertFalse(firstExport.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        app.buttons["export.home.button"].tap()
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 4))
        let seededItem = app.buttons["queue.row.item-pill"]
        XCTAssertTrue(seededItem.waitForExistence(timeout: 4))
        seededItem.tap()
        XCTAssertTrue(element("item.screen").waitForExistence(timeout: 4))
        let startNew = scrollToElement("item.startNew.button")
        startNew.tap()
        let confirmStartNew = app.sheets.buttons["Start New Session"].firstMatch
        XCTAssertTrue(confirmStartNew.waitForExistence(timeout: 4))
        confirmStartNew.tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 4))
        app.buttons["playback.export.button"].tap()
        XCTAssertTrue(element("export.screen").waitForExistence(timeout: 4))
        let secondExport = element("export.preview").label

        XCTAssertFalse(secondExport.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertEqual(firstExport.components(separatedBy: "Can you respond to my interjection?").count - 1, 1)
        XCTAssertEqual(secondExport.components(separatedBy: "Can you respond to my interjection?").count - 1, 1)
    }

    func testGate2CompactValidationControlsDelegateTransportCommands() throws {
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8))
        let seededStart = app.buttons["queue.start.item-pill"]
        XCTAssertTrue(seededStart.waitForExistence(timeout: 4))
        seededStart.tap()

        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Compact Controls"].waitForExistence(timeout: 4))
        XCTAssertFalse(element("gate2.compact.chapter").label.isEmpty)

        app.buttons["gate2.compact.playPause.button"].tap()
        XCTAssertTrue(element("playback.play.button").waitForExistence(timeout: 4))

        app.buttons["gate2.compact.forward.button"].tap()
        XCTAssertTrue(element("gate2.compact.chapter").waitForExistence(timeout: 4))
    }

    func testPermanentDeleteDoesNotRestoreRecentlyDeletedItem() throws {
        let itemTitle = "Permanent Delete \(UUID().uuidString.prefix(8))"
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8))
        app.buttons["home.addSource.button"].tap()
        let title = element("create.title.field")
        XCTAssertTrue(title.waitForExistence(timeout: 4))
        title.tap()
        title.typeText(itemTitle)
        let text = element("create.text.editor")
        text.tap()
        text.typeText("This item exists only to verify permanent deletion.")
        scrollToElement("create.start.button").tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 4))
        app.buttons["playback.home.button"].tap()
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 4))

        scrollToButton(containingLabel: "Move \(itemTitle) to Recently Deleted").tap()
        app.buttons["Move to Recently Deleted"].tap()

        app.buttons["home.settings.button"].tap()
        let delete = scrollToButton(containingLabel: "Delete \(itemTitle) Permanently")
        delete.tap()
        let confirmation = app.alerts["Delete Permanently?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 2))
        confirmation.buttons["Delete Permanently"].tap()

        XCTAssertTrue(waitForDisappearance(app.buttons["Restore \(itemTitle)"], timeout: 2))
        XCTAssertFalse(app.staticTexts[itemTitle].exists)
    }

    func testDiagnosticsCopyShowsLocalConfirmation() throws {
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8))
        app.buttons["home.settings.button"].tap()
        let copy = scrollToElement("settings.copyDiagnostics.button")

        copy.tap()

        XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: 2))
        XCTAssertTrue(element("app.feedback.banner").waitForExistence(timeout: 2))
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

    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private static let manualListeningMapJSON = """
    {"schemaVersion":"listening-map.v1","overview":"Manual validation map.","chapters":[{"id":"manual-opening","title":"Manual Opening","description":"The item grants distrust.","anchor":"Opening distrust is reasonable."},{"id":"manual-process","title":"Manual Process","description":"The item shifts the inspection target.","anchor":"The paper trail around the medicine is what can be inspected."}]}
    """
}
