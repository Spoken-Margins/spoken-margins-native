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
            XCTAssertFalse(app.buttons["playback.itemTitle.button"].label.isEmpty, "The PDF has no title")
            try waitUntilPlaying("The PDF never reached the playing state")
            let first = try percent()
            waitUntil("The PDF's position did not advance while playing", timeout: 15) {
                self.currentPercent().map { $0 > first } ?? false
            }
        }

        try XCTContext.runActivity(named: "J7 step 2a: Write a Margin at the current passage") { _ in
            tap("playback.write.button")
            XCTAssertTrue(element("writtenMargin.screen").waitForExistence(timeout: 5), "Write a Margin did not open")
            let anchor = element("writtenMargin.anchor")
            XCTAssertTrue(anchor.waitForExistence(timeout: 5), "The Margin's saved position is missing")
            marginPercent = try XCTUnwrap(trailingPercent(anchor.label), "Saved position has no percentage: \(anchor.label)")
            let field = element("writtenMargin.text")
            field.tap()
            field.typeText(note)
            tap("writtenMargin.save.button")
            XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8), "Did not return to Now Playing")
        }

        try XCTContext.runActivity(named: "J7 step 2b: Move away, then reopen the Margin at its passage") { _ in
            let scrubber = element("playback.scrubber")
            if scrubber.exists, scrubber.isEnabled {
                scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).tap()
                waitUntil("Scrubbing did not move away from the Margin", timeout: 10) {
                    self.currentPercent().map { $0 >= marginPercent + 20 } ?? false
                }
            }
            tap("playback.timeline.button")
            XCTAssertTrue(element("timeline.screen").waitForExistence(timeout: 5), "Timeline did not open")
            let margin = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline.interjection.")).firstMatch
            XCTAssertTrue(margin.waitForExistence(timeout: 5), "The Margin is not on the timeline")
            margin.tap()
            XCTAssertTrue(element("marginDetail.screen").waitForExistence(timeout: 5), "The Margin did not open")
            let text = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", note)).firstMatch
            XCTAssertTrue(text.waitForExistence(timeout: 5), "The Margin does not show what was written")
            tap("marginDetail.playMoment.button")
            XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8), "Play this moment did not open Now Playing")
            waitUntil("The Margin did not open at its passage (\(marginPercent)%)", timeout: 10) {
                self.currentPercent().map { abs($0 - marginPercent) <= 3 } ?? false
            }
        }
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
