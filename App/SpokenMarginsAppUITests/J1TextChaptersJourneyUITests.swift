import XCTest

// J1 step 4: read the text of a chaptered article, move to another chapter and back
// without leaving the reader, with playback unchanged (#1579).
// Uses the bundled fixture article (three chapters); no audio is judged.
final class J1TextChaptersJourneyUITests: XCTestCase {
    private var app: XCUIApplication!
    private var pausedPosition = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing",
            "-libraryContentTypeFilter", "all", "-libraryListeningStateFilter", "unfinished",
            "-libraryOfflineStateFilter", "all", "-librarySort", "recently_added",
            "-libraryUnfinishedDefaultApplied", "YES"]
        app.launchEnvironment["SPOKEN_MARGINS_UI_TESTING"] = "1"
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testStepToAnotherChapterAndBackInTheTextReader() throws {
        XCTContext.runActivity(named: "J1 step 4a: Start the chaptered article and open its text") { _ in
            app.launch()
            let start = app.buttons["queue.start.item-pill"]
            XCTAssertTrue(start.waitForExistence(timeout: 8), "The fixture article's start control is missing")
            start.tap()
            XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8), "Now Playing did not open")
            // Pause first, so "playback is unchanged" is a position that holds, not a clock that keeps moving.
            let playPause = app.buttons["playback.play.button"]
            XCTAssertTrue(playPause.waitForExistence(timeout: 8), "Playback control is missing")
            let started = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label == %@ AND enabled == true", "Pause"), object: playPause)
            XCTAssertEqual(XCTWaiter().wait(for: [started], timeout: 10), .completed, "Article never started playing")
            playPause.tap()
            let paused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Play"), object: playPause)
            XCTAssertEqual(XCTWaiter().wait(for: [paused], timeout: 5), .completed, "Article did not pause")
            pausedPosition = element("playback.progress.label").label
            let options = element("playback.options.button")
            XCTAssertTrue(options.waitForExistence(timeout: 5), "The More control is missing")
            options.tap()
            let text = app.buttons["playback.sourceText.button"]
            XCTAssertTrue(text.waitForExistence(timeout: 5), "More has no Text button for the article")
            text.tap()
            XCTAssertTrue(element("nativeText.peek.sheet").waitForExistence(timeout: 5), "The text reader did not open")
        }

        XCTContext.runActivity(named: "J1 step 4b: Step to the neighbouring chapter and back without leaving the reader") { _ in
            let chapter = element("nativeText.peek.chapter")
            XCTAssertTrue(chapter.waitForExistence(timeout: 5), "The reader shows no chapter title")
            let opening = chapter.label
            let next = element("nativeText.peek.next")
            let previous = element("nativeText.peek.previous")
            XCTAssertTrue(next.waitForExistence(timeout: 5) && previous.waitForExistence(timeout: 5),
                          "A chaptered article's reader has no chapter controls")
            let forward = next.isEnabled
            (forward ? next : previous).tap()
            let moved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", opening), object: chapter)
            XCTAssertEqual(XCTWaiter().wait(for: [moved], timeout: 5), .completed, "Stepping did not change the chapter")
            XCTAssertTrue(element("nativeText.peek.sheet").exists, "Stepping left the reader")
            XCTAssertTrue(element("nativeText.peek.playing").waitForExistence(timeout: 3),
                          "There is no way back to the playing chapter once away from it")
            (forward ? previous : next).tap()
            let returned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", opening), object: chapter)
            XCTAssertEqual(XCTWaiter().wait(for: [returned], timeout: 5), .completed,
                           "Stepping back did not return to the first chapter")
            XCTAssertFalse(element("nativeText.peek.playing").exists, "Back at the playing chapter, the return control stays")
            screenshot("J1 text reader back at the playing chapter")
        }

        XCTContext.runActivity(named: "J1 step 4c: The playing-chapter control returns from further away") { _ in
            let chapter = element("nativeText.peek.chapter")
            let opening = chapter.label
            let next = element("nativeText.peek.next")
            let previous = element("nativeText.peek.previous")
            let step = next.isEnabled ? next : previous
            step.tap()
            let moved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", opening), object: chapter)
            XCTAssertEqual(XCTWaiter().wait(for: [moved], timeout: 5), .completed, "Stepping did not change the chapter")
            element("nativeText.peek.playing").tap()
            let returned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", opening), object: chapter)
            XCTAssertEqual(XCTWaiter().wait(for: [returned], timeout: 5), .completed,
                           "The playing-chapter control did not return to the first chapter")
        }

        XCTContext.runActivity(named: "J1 step 4d: Closing the reader leaves Now Playing as it was") { _ in
            app.buttons["Close"].tap()
            XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 5), "Close did not return to Now Playing")
            XCTAssertEqual(app.buttons["playback.play.button"].label, "Play", "Browsing the text resumed playback")
            XCTAssertEqual(element("playback.progress.label").label, pausedPosition,
                           "Browsing chapters in the reader moved the playback position")
        }
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
