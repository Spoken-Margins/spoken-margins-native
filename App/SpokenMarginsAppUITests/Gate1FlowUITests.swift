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
        XCTAssertTrue(scrollToElement("settings.ai.processing").exists)
        XCTAssertTrue(scrollToElement("settings.ai.releaseBoundary").exists)
        XCTAssertFalse(element("provider.name").exists)
        XCTAssertFalse(element("provider.apiKey.field").exists)
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
        configureFullSessionExport()
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
        configureFullSessionExport()
        let secondExport = element("export.preview").label

        XCTAssertFalse(secondExport.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(firstExport.contains("bytes"))
        XCTAssertEqual(secondExport, firstExport, "The second session export accumulated data from the first session")
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

    func testNativeTextPublishesVisibleSimulatorSystemPlaybackControls() throws {
        let title = "Now Playing Simulator Probe"
        app.terminate()
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_TITLE"] = title
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_TEXT"] = String(
            repeating: "This native text playback probe must remain long enough to inspect the system media controls. ",
            count: 200
        )
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_URL"] = "https://example.com/now-playing-probe"
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SUPERTONIC"] = "1"
        app.launch()

        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8))
        let start = app.buttons["queue.start.item-ui-text-regression"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 5))
        let playPause = app.buttons["playback.play.button"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 8))
        XCTAssertEqual(playPause.label, "Pause")
        let compactChapter = element("gate2.compact.chapter")
        XCTAssertTrue(compactChapter.waitForExistence(timeout: 4))
        let nativePlaybackConfirmed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "playing"),
            object: compactChapter
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [nativePlaybackConfirmed], timeout: 60),
            .completed,
            "Native text playback never advanced from starting to playing."
        )
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 5))
        let topCenter = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.01))
        let notificationCenter = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.72))
        topCenter.press(forDuration: 0.1, thenDragTo: notificationCenter)

        // On current simulator runtimes the lock-screen playback card is hosted
        // by MediaRemoteUI rather than SpringBoard. Query both because the host
        // process changed across supported iOS versions.
        let mediaRemoteUI = XCUIApplication(bundleIdentifier: "com.apple.MediaRemoteUI")
        _ = mediaRemoteUI.wait(for: .runningForeground, timeout: 5)
        let playbackTitlePredicate = NSPredicate(format: "label CONTAINS[c] %@", title)
        let systemPlaybackTitleExists = springboard.descendants(matching: .any)
            .matching(playbackTitlePredicate).firstMatch.waitForExistence(timeout: 8)
            || mediaRemoteUI.descendants(matching: .any)
                .matching(playbackTitlePredicate).firstMatch.waitForExistence(timeout: 8)
        XCTAssertTrue(
            systemPlaybackTitleExists,
            "Native text playback did not become visible on the Simulator system playback surface.\nSPRINGBOARD:\n\(springboard.debugDescription)\nMEDIA REMOTE UI:\n\(mediaRemoteUI.debugDescription)"
        )
        let pauseButtonPredicate = NSPredicate(format: "label CONTAINS[c] %@", "pause")
        let systemPauseControlExists = springboard.buttons.matching(pauseButtonPredicate).firstMatch.exists
            || mediaRemoteUI.buttons.matching(pauseButtonPredicate).firstMatch.exists
        XCTAssertTrue(
            systemPauseControlExists,
            "The Simulator system playback surface did not expose a pause control for active native text playback.\nSPRINGBOARD:\n\(springboard.debugDescription)\nMEDIA REMOTE UI:\n\(mediaRemoteUI.debugDescription)"
        )
    }

    func testFailedLocalSummaryShowsPersistentRetryAndRetryCompletes() throws {
        app.terminate()
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_TITLE"] = "Summary Retry Probe"
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_TEXT"] = String(
            repeating: "A bounded source sentence provides context for the listener note. ",
            count: 20
        )
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_URL"] = "https://example.com/summary-retry"
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_INTERJECTION"] = "The app should condense one interjection into its substantive claims instead of lightly cleaning up the transcript."
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_LOCAL_SUMMARY"] = "fail_once"
        app.launch()

        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8))
        let start = app.buttons["queue.start.item-ui-text-regression"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 5))

        let summarize = scrollToElement("playback.summary.button")
        XCTAssertTrue(summarize.isEnabled)
        summarize.tap()

        let failure = element("app.feedback.banner")
        XCTAssertTrue(failure.waitForExistence(timeout: 8))
        XCTAssertTrue(failure.label.contains("On-device summary failed"))
        XCTAssertTrue(failure.label.contains("Retry Summary"))

        XCTAssertTrue(summarize.waitForExistence(timeout: 4))
        XCTAssertEqual(summarize.label, "Retry summary")
        XCTAssertTrue(summarize.isEnabled)
        summarize.tap()

        XCTAssertTrue(
            scrollToStaticText(containing: "Each interjection should be condensed into its substantive claims instead of receiving a cleaned transcript.")
                .waitForExistence(timeout: 8)
        )
        XCTAssertEqual(summarize.label, "Summarize interjections")
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

    func testAddSourcePresentsPodcastBeforePlainText() throws {
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8))
        app.buttons["home.addSource.button"].tap()

        let podcast = element("addSource.podcast.heading")
        let plainText = element("addSource.plainText.heading")
        XCTAssertTrue(podcast.waitForExistence(timeout: 4))
        XCTAssertTrue(plainText.waitForExistence(timeout: 4))
        XCTAssertLessThan(podcast.frame.midY, plainText.frame.midY)
    }

    func testAmbiguousPodcastImportImmediatelyReplacesAddSourceWithEpisodePicker() throws {
        app.terminate()
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_AMBIGUOUS_SOURCE_LINK"] = "1"
        app.launch()

        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8))
        app.buttons["home.addSource.button"].tap()
        let link = element("sourceLink.url.field")
        XCTAssertTrue(link.waitForExistence(timeout: 4))
        link.tap()
        link.typeText("https://open.spotify.com/episode/ambiguous-ui-test")
        app.buttons["sourceLink.import.button"].tap()

        XCTAssertTrue(
            element("sourceLink.candidateReview.sheet").waitForExistence(timeout: 4),
            "The episode picker did not replace Add Source when the first import required review."
        )
        XCTAssertTrue(app.buttons["sourceLink.candidate.0"].exists)
        XCTAssertTrue(app.buttons["sourceLink.candidate.1"].exists)

        app.buttons["Cancel"].tap()
        XCTAssertTrue(element("sourceLink.url.field").waitForExistence(timeout: 4))
        app.buttons["Close"].tap()
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 4))

        let seededStart = app.buttons["queue.start.item-pill"]
        XCTAssertTrue(seededStart.waitForExistence(timeout: 4))
        seededStart.tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 4))
        app.buttons["playback.home.button"].tap()

        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 4))
        let miniPlayer = element("miniPlayer.bar")
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 4))
        XCTAssertEqual(app.keyboards.count, 0, "The source-link field kept keyboard focus after the picker closed.")

        let window = app.windows.firstMatch
        XCTAssertTrue(window.exists)
        let bottomGap = window.frame.maxY - miniPlayer.frame.maxY
        XCTAssertLessThan(
            bottomGap,
            96,
            "The mini-player remained displaced by a stale keyboard safe-area (bottom gap: \(bottomGap))."
        )
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

    private func scrollToStaticText(containing text: String) -> XCUIElement {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let candidate = app.staticTexts.matching(predicate).firstMatch
        for _ in 0..<6 where !candidate.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(candidate.waitForExistence(timeout: 4), "Missing static text containing \(text)")
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

    private func configureFullSessionExport() {
        let fullSession = app.buttons["Full Session"]
        XCTAssertTrue(fullSession.waitForExistence(timeout: 4))
        if !fullSession.isSelected {
            fullSession.tap()
        }

        let includeTurns = scrollToElement("export.includeTurns.toggle")
        if includeTurns.value as? String == "0" {
            includeTurns.tap()
        }
        XCTAssertEqual(includeTurns.value as? String, "1")
    }

    private static let manualListeningMapJSON = """
    {"schemaVersion":"listening-map.v1","overview":"Manual validation map.","chapters":[{"id":"manual-opening","title":"Manual Opening","description":"The item grants distrust.","anchor":"Opening distrust is reasonable."},{"id":"manual-process","title":"Manual Process","description":"The item shifts the inspection target.","anchor":"The paper trail around the medicine is what can be inspected."}]}
    """
}
