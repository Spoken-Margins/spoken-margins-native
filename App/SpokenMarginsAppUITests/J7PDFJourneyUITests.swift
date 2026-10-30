import XCTest

// J7: listen to a text PDF, write a Margin, and reopen it at its passage.
// SPOKEN_MARGINS_UI_TEST_PDF=1 generates a four-page PDF with a running header,
// a "Downloaded on" stamp and page numbers, and imports it through the app's
// Files import, so the real PDF extraction runs. Picking the file in the Files
// sheet stays with the agent run. Whether the header, stamp and page numbers
// are left out of what is spoken is audible only, so it stays with the agent
// run and the owner; this script proves the PDF imports and plays.
final class J7PDFJourneyUITests: XCTestCase {
    private var app: XCUIApplication!
    private let note = "J7: the willows by the river"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing",
            "-libraryContentTypeFilter", "all", "-libraryListeningStateFilter", "unfinished",
            "-libraryOfflineStateFilter", "all", "-librarySort", "recently_added",
            "-libraryUnfinishedDefaultApplied", "YES"]
        app.launchEnvironment["SPOKEN_MARGINS_UI_TESTING"] = "1"
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_PDF"] = "1"
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testListenToAPDFAndReopenAMargin() throws {
        var marginPercent = 0
        var marginPassageID = ""
        var firstPassageID = ""

        try XCTContext.runActivity(named: "J7 step 1: The imported PDF is in the Library and plays") { _ in
            app.launch()
            XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8), "Library did not open")
            let row = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.row.item-obsidian-")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 20), "The PDF never finished importing into the Library")
            let itemId = String(row.identifier.dropFirst("library.row.".count))
            let start = app.buttons["queue.start.\(itemId)"]
            XCTAssertTrue(start.waitForExistence(timeout: 5), "The PDF's start control is missing")
            start.tap()
            XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8), "Now Playing did not open")
            let title = app.buttons["playback.itemTitle.button"].label
            XCTAssertTrue(title.contains("Walking Notes"), "A different item is playing: \(title)")
            try waitUntilPlaying("The PDF never reached the playing state")
            XCTAssertTrue(element("playback.now.passage").waitForExistence(timeout: 5), "The PDF live passage is missing")
            XCTAssertTrue(currentPassage.waitForExistence(timeout: 5), "The PDF has no highlighted current sentence")
            firstPassageID = currentPassage.identifier
            screenshot("J7 PDF passage, first moment")
            let first = try percent()
            waitUntil("The PDF's position did not advance while playing", timeout: 15) {
                self.currentPercent().map { $0 > first } ?? false
            }
        }

        try XCTContext.runActivity(named: "J7 step 2a: Write a Margin at the current passage") { _ in
            // Move well into the document first, so a Margin anchored at the start can't pass for one
            // anchored at the passage being heard (#1044 APO-02).
            let scrubber = element("playback.scrubber")
            XCTAssertTrue(scrubber.waitForExistence(timeout: 5), "No scrubber to move into the PDF with")
            scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).tap()
            waitUntil("Scrubbing did not move into the PDF", timeout: 10) {
                self.currentPercent().map { $0 >= 25 } ?? false
            }
            let playingPercent = try percent()
            XCTAssertTrue(element("playback.now.passage").exists, "The PDF passage disappeared after seeking")
            waitUntil("The PDF passage stayed at its opening sentence after seeking", timeout: 5) {
                self.currentPassage.exists && self.currentPassage.identifier != firstPassageID
            }
            screenshot("J7 PDF passage, later moment")
            // Pause first, so the passage read here is the one the Margin is saved at, not a sentence earlier.
            if playPause.label == "Pause" { playPause.tap() }
            waitUntil("The PDF did not pause before the Margin was written") { self.playPause.label == "Play" }
            XCTAssertTrue(currentPassage.waitForExistence(timeout: 5), "The PDF has no highlighted current sentence once paused")
            marginPassageID = currentPassage.identifier
            tap("playback.write.button")
            XCTAssertTrue(element("writtenMargin.screen").waitForExistence(timeout: 5), "Write a Margin did not open")
            let anchor = element("writtenMargin.anchor")
            XCTAssertTrue(anchor.waitForExistence(timeout: 5), "The Margin's saved position is missing")
            marginPercent = try XCTUnwrap(trailingPercent(anchor.label), "Saved position has no percentage: \(anchor.label)")
            XCTAssertLessThanOrEqual(abs(marginPercent - playingPercent), 3,
                                     "The Margin was placed at \(marginPercent)%, not at the passage playing (\(playingPercent)%)")
            let field = element("writtenMargin.text")
            field.tap()
            field.typeText(note)
            tap("writtenMargin.save.button")
            XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8), "Did not return to Now Playing")
        }

        try XCTContext.runActivity(named: "J7 step 2b: Move away, then reopen the Margin at its passage") { _ in
            // Without moving away, the passage check below would pass even if reopening never seeks.
            let scrubber = element("playback.scrubber")
            XCTAssertTrue(scrubber.waitForExistence(timeout: 5), "No scrubber to move away from the Margin with")
            XCTAssertTrue(scrubber.isEnabled, "The scrubber is disabled")
            scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).tap()
            waitUntil("Scrubbing did not move away from the Margin", timeout: 10) {
                self.currentPercent().map { $0 >= marginPercent + 20 } ?? false
            }
            tap("playback.timeline.button")
            XCTAssertTrue(element("timeline.screen").waitForExistence(timeout: 5), "Timeline did not open")
            // The Timeline is a lazy list that follows the playing source, which is now well past the
            // Margin, so the Margin's row isn't materialized until the list is scrolled back to it (#1427).
            let margin = revealTimelineMargin()
            margin.tap()
            XCTAssertTrue(element("marginDetail.screen").waitForExistence(timeout: 5), "The Margin did not open")
            let text = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", note)).firstMatch
            XCTAssertTrue(text.waitForExistence(timeout: 5), "The Margin does not show what was written")
            tap("marginDetail.playMoment.button")
            XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8), "Play this moment did not open Now Playing")
            waitUntil("The Margin did not open at its passage (\(marginPercent)%)", timeout: 10) {
                self.currentPercent().map { abs($0 - marginPercent) <= 3 } ?? false
            }
            // Percent alone allows a neighbouring sentence; the passage id is the sentence the Margin was written at.
            waitUntil("The Margin did not reopen at its passage (\(marginPassageID))", timeout: 10) {
                self.currentPassage.exists && self.currentPassage.identifier == marginPassageID
            }
        }
    }

    /// Scrolls the lazy Timeline back, then forward if needed, until the saved Margin's row is on screen.
    /// A bounded search: if the row is still missing after both passes, the Margin isn't on the Timeline.
    private func revealTimelineMargin() -> XCUIElement {
        let margin = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline.interjection.")).firstMatch
        let timeline = element("timeline.screen")
        XCTAssertTrue(timeline.waitForExistence(timeout: 5), "Timeline did not open")
        func isRevealed() -> Bool { margin.exists && margin.isHittable }
        if !isRevealed() { _ = margin.waitForExistence(timeout: 2) }
        var swipes = 0
        while !isRevealed() && swipes < 12 {
            timeline.swipeDown()
            swipes += 1
        }
        swipes = 0
        while !isRevealed() && swipes < 24 {
            timeline.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(isRevealed(), "The Margin is not on the timeline, even after scrolling through it")
        screenshot("J7 Timeline with the saved Margin revealed")
        return margin
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private var currentPassage: XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND value == %@",
                                         "playback.now.passage.sentence.", "Current sentence")).firstMatch
    }

    private var playPause: XCUIElement { app.buttons["playback.play.button"] }

    private func waitUntilPlaying(_ message: String) throws {
        XCTAssertTrue(playPause.waitForExistence(timeout: 5), "Playback control is missing")
        waitUntil(message, timeout: 10) { self.playPause.isEnabled && self.playPause.label == "Pause" }
    }

    private func percent() throws -> Int {
        let label = element("playback.progress.label")
        XCTAssertTrue(label.waitForExistence(timeout: 5), "The PDF's position is missing")
        return try XCTUnwrap(currentPercent(), "The PDF's position is not a percentage: \(label.label)")
    }

    private func currentPercent() -> Int? {
        let label = element("playback.progress.label")
        guard label.exists else { return nil }
        return Int(label.label.replacingOccurrences(of: "%", with: ""))
    }

    /// The last number before "percent" or "%" in a label such as "Saved position for X, Text, 12 percent".
    private func trailingPercent(_ label: String) -> Int? {
        let words = label.replacingOccurrences(of: "%", with: " percent").split(separator: " ")
        guard let index = words.lastIndex(of: "percent"), index > words.startIndex else { return nil }
        return Int(words[words.index(before: index)])
    }

    private func tap(_ identifier: String) {
        let control = app.buttons[identifier].firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 5), "Missing control: \(identifier)")
        for _ in 0..<4 where !control.isHittable { app.swipeUp() }
        XCTAssertTrue(control.isHittable, "Control can't be tapped: \(identifier)")
        control.tap()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) {
        let met = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [met], timeout: timeout), .completed, message)
    }
}
