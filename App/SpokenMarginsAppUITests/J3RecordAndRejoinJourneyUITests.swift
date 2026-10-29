import XCTest

// J3: record a spoken Margin while a podcast plays, rejoin the podcast, replay
// the Margin, and replay it again after a force-quit.
// The episode is the generated offline podcast (SPOKEN_MARGINS_UI_TEST_PODCAST).
// SPOKEN_MARGINS_UI_TEST_RECORDING=1 swaps the microphone for a recorder that
// saves a real tone file as long as the recording lasted, and gives the Margin a
// fixed transcript, so no permission prompt appears. What the Margin sounds like,
// the microphone itself, Bluetooth and the Lock Screen stay with the owner.
// A moving clock or a play button's state does not prove audio.
final class J3RecordAndRejoinJourneyUITests: XCTestCase {
    private var app: XCUIApplication!
    private let episodeTitle = "J3: An episode to talk over"
    private let itemId = "item-ui-podcast"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing",
            "-libraryContentTypeFilter", "all", "-libraryListeningStateFilter", "unfinished",
            "-libraryOfflineStateFilter", "all", "-librarySort", "recently_added",
            "-libraryUnfinishedDefaultApplied", "YES"]
        app.launchEnvironment["SPOKEN_MARGINS_UI_TESTING"] = "1"
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_PODCAST"] = "1"
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_RECORDING"] = "1"
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_TITLE"] = episodeTitle
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testRecordAMarginAndRejoinIt() throws {
        var marginId = ""
        var marginPosition = 0
        var beforeOpeningMargin = 0

        try XCTContext.runActivity(named: "J3 step 1: Record about 10 s while the podcast plays, then finish") { _ in
            app.launch()
            XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8), "Library did not open")
            tap("queue.start.\(itemId)")
            XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8), "Now Playing did not open")
            XCTAssertEqual(app.buttons["playback.itemTitle.button"].label, episodeTitle, "A different item is playing")
            try waitUntilPlaying("Podcast never reached the playing state")
            try waitUntilAdvancing("Podcast clock did not move before recording")
            assertDockStaysFixedWhileSwitching()
            // Record well past 0:00, so a Margin anchored at the start can't pass for one anchored here (#1044 APO-01).
            waitUntil("Podcast did not reach 0:30 before recording", timeout: 45) {
                self.currentPosition().map { $0 >= 30 } ?? false
            }
            marginPosition = try position()

            tap("playback.interject.button")
            XCTAssertTrue(element("recording.screen").waitForExistence(timeout: 5), "Recording did not open")
            let duration = element("recording.duration.label")
            XCTAssertTrue(duration.waitForExistence(timeout: 5), "Recording clock is missing")
            waitUntil("Recording clock did not reach 10 s", timeout: 20) {
                self.seconds(duration.label).map { $0 >= 10 } ?? false
            }
            tap("recording.finish.button")

            XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8), "Did not return to Now Playing")
            try waitUntilPlaying("Podcast did not resume after the Margin was saved")
            let resumed = try position()
            XCTAssertGreaterThanOrEqual(resumed, marginPosition - 2, "Podcast jumped back after the Margin")
            XCTAssertLessThan(resumed - marginPosition, 10, "Podcast kept playing under the recording instead of pausing")
            try waitUntilAdvancing("Podcast clock is stuck after the Margin")
            assertOwnMarginFilters()

            openTimeline()
            let margins = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline.interjection."))
            XCTAssertTrue(margins.firstMatch.waitForExistence(timeout: 5), "The Margin is not on the timeline")
            XCTAssertEqual(margins.count, 1, "Recording made more than one Margin")
            marginId = margins.firstMatch.identifier
            tap("timeline.nowPlaying.button")
            XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 5), "Could not return to Now Playing")
        }

        try XCTContext.runActivity(named: "J3 step 2: Keep listening a minute, then open the Margin and play it to the end") { _ in
            let start = try position()
            waitUntil("Podcast did not play on for a minute", timeout: 80) {
                self.currentPosition().map { $0 >= start + 60 } ?? false
            }
            try waitUntilPlaying("Podcast stopped during the minute")
            beforeOpeningMargin = try position()
            openTimeline()
            element(marginId).tap()
            playMarginToTheEnd()
        }

        try XCTContext.runActivity(named: "J3 step 3: Return to the source; it continues at a sensible place") { _ in
            tap("marginDetail.done.button")
            tap("timeline.nowPlaying.button")
            XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 5), "Could not return to Now Playing")
            if playPause.label == "Play" { playPause.tap() }
            try waitUntilPlaying("Podcast stayed stopped after the Margin")
            let now = try position()
            XCTAssertTrue(abs(now - beforeOpeningMargin) < 20 || abs(now - marginPosition) < 20,
                          "Podcast continued at \(now) s, not where you were (\(beforeOpeningMargin) s) or at the Margin (\(marginPosition) s)")
            try waitUntilAdvancing("Podcast is stuck after the Margin played")
        }

        try XCTContext.runActivity(named: "J3 step 3b: Play this moment goes back to where the Margin was recorded") { _ in
            // The source is now a minute or more past the Margin, so landing near it proves where it was anchored.
            tap("playback.margins.button")
            tap("playback.margins.filter.mine")
            let playMoment = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "margins.row.", ".play"
            )).firstMatch
            XCTAssertTrue(playMoment.waitForExistence(timeout: 5), "The playback Margin row has no play button")
            playMoment.tap()
            XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8), "Play this moment did not open Now Playing")
            // The moment starts 30 s before the Margin (its lead-in); "Play it now" skips to the Margin itself.
            tap("marginMoment.playNow")
            waitUntil("Play it now did not land at the Margin (\(marginPosition) s)", timeout: 10) {
                self.currentPosition().map { abs($0 - marginPosition) <= 10 } ?? false
            }
            // The Margin's voice plays with the source paused, then the source carries on; pause it for the force-quit.
            _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in self.playPause.label == "Pause" }, object: nil)], timeout: 30)
            if playPause.label == "Pause" { playPause.tap() }
            waitUntil("Podcast did not pause before the force-quit") { self.playPause.label == "Play" }
        }

        XCTContext.runActivity(named: "J3 step 4: Force-quit, reopen and play the same Margin again") { _ in
            app.terminate()
            app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_KEEP_LIBRARY"] = "1"
            app.launch()
            XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8), "Library did not reopen")
            tap("miniPlayer.open.button")
            XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8), "Now Playing did not reopen")
            openTimeline()
            XCTAssertTrue(element(marginId).waitForExistence(timeout: 5), "The Margin is gone after relaunch")
            element(marginId).tap()
            playMarginToTheEnd()
        }
    }

    private var playPause: XCUIElement { app.buttons["playback.play.button"] }

    private func playMarginToTheEnd() {
        XCTAssertTrue(element("marginDetail.screen").waitForExistence(timeout: 5), "Margin did not open")
        let play = app.buttons["marginDetail.playRecording.button"]
        XCTAssertTrue(play.waitForExistence(timeout: 5), "The Margin has no recording to play")
        play.tap()
        waitUntil("The Margin never started playing") { play.label == "Stop playing" }
        assertNoAudioProblemShown()
        // An unplayable file resets the button at once, so require it to keep playing first.
        let stopsEarly = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in play.label != "Stop playing" }, object: nil
        )
        stopsEarly.isInverted = true
        XCTAssertEqual(XCTWaiter().wait(for: [stopsEarly], timeout: 5), .completed,
                       "The Margin stopped before its 10 s recording could finish")
        waitUntil("The Margin never played to the end", timeout: 25) { play.label == "Hear my recording" }
        assertNoAudioProblemShown()
    }

    private func assertNoAudioProblemShown() {
        let banner = element("app.feedback.banner")
        guard banner.exists else { return }
        for problem in ["unavailable", "couldn't be played", "could not be played"] {
            XCTAssertFalse(banner.label.localizedCaseInsensitiveContains(problem), "Margin playback reported: \(banner.label)")
        }
    }

    /// J3 has one own Margin and no shared packet. Mixed-origin ordering is host-tested;
    /// screenshots with both kinds and shared playback still belong to J5.
    private func assertOwnMarginFilters() {
        tap("playback.margins.button")
        let ownRows = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND NOT (identifier ENDSWITH %@)", "margins.row.", ".play"
        ))
        for (filter, expectedCount) in [("all", 1), ("mine", 1), ("shared", 0)] {
            tap("playback.margins.filter.\(filter)")
            waitUntil("The \(filter) filter shows the wrong Margin count") {
                self.element("playback.margins.count").label == "Margins: \(expectedCount)"
            }
            XCTAssertEqual(ownRows.count, expectedCount, "Filtering did not change the actual rows")
            XCTAssertTrue(playPause.isHittable, "Filtering hid the playback dock")
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Playback Margins — \(filter) — own-only J3 fixture"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        tap("playback.now.button")
    }

    private func assertDockStaysFixedWhileSwitching() {
        let controls = element("playback.controls")
        let original = controls.frame
        for (button, content) in [("playback.timeline.button", "timeline.screen"),
                                  ("playback.margins.button", "margins.screen"),
                                  ("playback.now.button", "playback.now.margins")] {
            tap(button)
            XCTAssertTrue(element(content).waitForExistence(timeout: 5), "Playback pane did not appear")
            XCTAssertEqual(controls.frame.minY, original.minY, accuracy: 1, "Dock moved when switching panes")
            XCTAssertEqual(controls.frame.height, original.height, accuracy: 1, "Dock changed height")
            for control in ["playback.play.button", "playback.interject.button", "playback.write.button"] {
                XCTAssertTrue(app.buttons[control].isHittable, "Dock control disappeared: \(control)")
            }
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Fixed dock — \(content)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
    }

    private func openTimeline() {
        if element("timeline.screen").exists { return }
        tap("playback.timeline.button")
        XCTAssertTrue(element("timeline.screen").waitForExistence(timeout: 5), "Timeline did not open")
    }

    private func waitUntilPlaying(_ message: String) throws {
        XCTAssertTrue(playPause.waitForExistence(timeout: 5), "Playback control is missing")
        waitUntil(message, timeout: 10) { self.playPause.isEnabled && self.playPause.label == "Pause" }
    }

    private func waitUntilAdvancing(_ message: String) throws {
        let start = try position()
        waitUntil(message, timeout: 8) { self.currentPosition().map { $0 > start } ?? false }
    }

    /// The podcast's elapsed-time label in seconds.
    private func position() throws -> Int {
        let label = element("playback.progress.label")
        XCTAssertTrue(label.waitForExistence(timeout: 5), "Podcast clock is missing")
        return try XCTUnwrap(seconds(label.label), "Podcast clock is not a time: \(label.label)")
    }

    /// The same, without waiting, for use inside a predicate.
    private func currentPosition() -> Int? {
        let label = element("playback.progress.label")
        return label.exists ? seconds(label.label) : nil
    }

    /// "m:ss", "mm:ss" or "h:mm:ss", optionally after a word such as "Recording duration".
    private func seconds(_ label: String) -> Int? {
        guard let clock = label.split(separator: " ").last else { return nil }
        let parts = clock.split(separator: ":").map { Int($0) }
        guard parts.count == 2 || parts.count == 3, !parts.contains(nil) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
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
