import XCTest

// J1: seed an article offline, start listening, then pause in the foreground.
// URL/Safari intake stays with the agent run: existing seed hooks bypass fetching.
// Audible speech, Lock Screen resume at the same sentence, and Bluetooth stay
// with the owner on a device. Advancing position alone does not prove audio.
final class J1ListenToAnArticleJourneyUITests: XCTestCase {
    private var app: XCUIApplication!
    private let articleTitle = "J1: A short walk"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing",
            "-libraryContentTypeFilter", "all", "-libraryListeningStateFilter", "unfinished",
            "-libraryOfflineStateFilter", "all", "-librarySort", "recently_added",
            "-libraryUnfinishedDefaultApplied", "YES"]
        app.launchEnvironment["SPOKEN_MARGINS_UI_TESTING"] = "1"
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_TITLE"] = articleTitle
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_TEXT"] = [
            "The path begins beside a quiet wooden gate.",
            "Morning light reaches the old oak tree.",
            "A small bird lands on the stone wall.",
            "The river bends toward the distant bridge.",
            "Willows lean above the shallow water.",
            "A bicycle waits beside the village shop.",
            "Beyond the shop a narrow lane climbs uphill.",
            "Wild flowers grow along the garden fence.",
            "At the hilltop the whole valley comes into view.",
            "Clouds cast moving shadows across the fields.",
            "The returning path passes an empty bench.",
            "Our walk ends where the wooden gate stands."
        ].joined(separator: " ")
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_URL"] = "https://example.com/j1-article"
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testListenToAnArticle() throws {
        XCTContext.runActivity(named: "J1 step 1: Article is in the Library (offline seed)") { _ in
            app.launch()
            XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8), "Library did not open")
            XCTAssertTrue(element("library.row.item-ui-text-regression").waitForExistence(timeout: 5),
                          "Seeded article did not appear in the Library")
        }

        try XCTContext.runActivity(named: "J1 step 2: Start listening and watch position advance") { _ in
            let start = app.buttons["queue.start.item-ui-text-regression"]
            XCTAssertTrue(start.waitForExistence(timeout: 5), "Article's start control is missing")
            XCTAssertTrue(start.isEnabled, "Article cannot be started")
            start.tap()
            XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8), "Now Playing did not open")
            let title = app.buttons["playback.itemTitle.button"]
            XCTAssertTrue(title.waitForExistence(timeout: 5), "Playing item's title is missing")
            XCTAssertEqual(title.label, articleTitle, "A different item is playing")

            let playPause = app.buttons["playback.play.button"]
            XCTAssertTrue(playPause.waitForExistence(timeout: 5), "Playback control is missing")
            let playing = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label == %@ AND enabled == true", "Pause"),
                object: playPause
            )
            XCTAssertEqual(XCTWaiter().wait(for: [playing], timeout: 10), .completed,
                           "Article never reached the visible playing state")

            let current = currentSentence
            XCTAssertTrue(current.waitForExistence(timeout: 5), "The article's live passage is missing")
            let firstSentence = current.label
            screenshot("J1 article passage, first moment")
            let follows = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                self.currentSentence.exists && self.currentSentence.label != firstSentence
            }, object: nil)
            XCTAssertEqual(XCTWaiter().wait(for: [follows], timeout: 10), .completed,
                           "The current sentence did not follow the advancing article")
            screenshot("J1 article passage, later moment")

            let progress = element("playback.progress.label")
            XCTAssertTrue(progress.waitForExistence(timeout: 5), "Article position is missing")
            let startingPosition = try XCTUnwrap(positionPercent(progress), "Article position is not a percentage")
            let advancing = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    self.positionPercent(progress).map { $0 > startingPosition } ?? false
                }, object: nil
            )
            XCTAssertEqual(XCTWaiter().wait(for: [advancing], timeout: 10), .completed,
                           "Article position did not advance while playing")
            XCTAssertEqual(playPause.label, "Pause", "Playback stopped before the pause step")
        }

        XCTContext.runActivity(named: "J1 step 3: Pause in the app (Lock Screen resume is owner-only)") { _ in
            let playPause = app.buttons["playback.play.button"]
            playPause.tap()
            let paused = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label == %@ AND enabled == true", "Play"),
                object: playPause
            )
            XCTAssertEqual(XCTWaiter().wait(for: [paused], timeout: 5), .completed,
                           "Article did not reach the visible paused state")
            let progress = element("playback.progress.label")
            let pausedPosition = progress.label
            let pausedSentence = currentSentence.label
            let movesWhilePaused = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label != %@", pausedPosition), object: progress
            )
            movesWhilePaused.isInverted = true
            XCTAssertEqual(XCTWaiter().wait(for: [movesWhilePaused], timeout: 2), .completed,
                           "Article position kept changing after pause")
            XCTAssertEqual(currentSentence.label, pausedSentence, "The highlighted sentence changed while paused")
        }

        XCTContext.runActivity(named: "J1 step 4: Open the existing full reader from a late passage") { _ in
            let scrubber = element("playback.scrubber")
            XCTAssertTrue(scrubber.waitForExistence(timeout: 5))
            let beforeSeekSentenceID = currentSentence.identifier
            scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).tap()
            let late = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                self.positionPercent(self.element("playback.progress.label")).map { $0 >= 60 } ?? false
            }, object: nil)
            XCTAssertEqual(XCTWaiter().wait(for: [late], timeout: 10), .completed, "The article did not seek to a late passage")
            let passageMoved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                self.currentSentence.exists && self.currentSentence.identifier != beforeSeekSentenceID
            }, object: nil)
            XCTAssertEqual(XCTWaiter().wait(for: [passageMoved], timeout: 5), .completed,
                           "The highlighted passage did not follow the paused seek")
            let sentence = currentSentence
            XCTAssertTrue(sentence.waitForExistence(timeout: 5))
            let selectedText = sentence.label
            XCTAssertTrue(sentence.isHittable, "The live current sentence is not in the visible passage")
            sentence.tap()
            XCTAssertTrue(element("nativeText.peek.sheet").waitForExistence(timeout: 5), "The existing source reader did not open")
            let reader = app.textViews["nativeText.peek.text"]
            XCTAssertTrue(reader.waitForExistence(timeout: 5))
            let chapter = reader.value as? String ?? ""
            XCTAssertTrue(chapter.contains(selectedText), "The reader opened a different source")
            XCTAssertTrue(chapter.contains("The path begins beside a quiet wooden gate."), "The full chapter must remain selectable")
            screenshot("J1 full reader at the late passage")
            app.buttons["Close"].tap()
            XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 5))
            XCTAssertEqual(app.buttons["playback.play.button"].label, "Play", "Opening the reader resumed paused playback")
        }
    }

    private var currentSentence: XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND value == %@",
                                        "playback.now.passage.sentence.", "Current sentence")).firstMatch
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

    private func positionPercent(_ progress: XCUIElement) -> Int? {
        Int(progress.label.replacingOccurrences(of: "%", with: ""))
    }
}
