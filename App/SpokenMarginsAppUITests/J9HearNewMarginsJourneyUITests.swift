import XCTest

// J9: a friend's new Margin, shared while the listener was already further on, is offered when they press
// Continue. It plays in place with a lead-in, then the episode goes back to where they left off.
// The episode is the generated offline podcast (SPOKEN_MARGINS_UI_TEST_PODCAST). Step 2 saves one of the
// listener's own Margins with the stand-in recorder, step 3 relaunches with SPOKEN_MARGINS_UI_TEST_KEEP_LIBRARY
// and SPOKEN_MARGINS_UI_TEST_COOP, which imports one new Margin from "Sam" five minutes into the episode, the
// way a co-op packet would. What the voices sound like and whether the lead-in sounds right stay with the owner.
// A moving clock or a card on screen does not prove audio.
final class J9HearNewMarginsJourneyUITests: XCTestCase {
    private var app: XCUIApplication!
    private let episodeTitle = "J9: An episode a friend added to"
    private let itemId = "item-ui-podcast"
    /// Where the imported Margin sits (`UITestingLaunchSeed.coopMarginMediaTimeMs`), and the lead-in before it.
    private let friendMarginAt = 300
    private let leadIn = 10

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

    func testHearAFriendsNewMarginThenCarryOnWhereYouWere() throws {
        var pausedSeconds = 0

        XCTContext.runActivity(named: "J9 step 1: The episode is in the Library (offline seed)") { _ in
            app.launch()
            XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8), "Library did not open")
            XCTAssertTrue(element("library.row.\(itemId)").waitForExistence(timeout: 5),
                          "Seeded episode did not appear in the Library")
        }

        try XCTContext.runActivity(named: "J9 step 2: Listen to about 20:00, save a Margin of your own and pause") { _ in
            tap("queue.start.\(itemId)")
            XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8), "Now Playing did not open")
            XCTAssertEqual(app.buttons["playback.itemTitle.button"].label, episodeTitle, "A different item is playing")
            try waitUntilPlaying("Episode never reached the playing state")
            try scrub(to: 0.8)
            waitUntil("Scrub did not land near 20:00; clock shows \(element("playback.progress.label").label)", timeout: 10) {
                self.currentPosition().map { (17 * 60...23 * 60).contains($0) } ?? false
            }

            tap("playback.interject.button")
            XCTAssertTrue(element("recording.screen").waitForExistence(timeout: 5), "Recording did not open")
            let duration = element("recording.duration.label")
            XCTAssertTrue(duration.waitForExistence(timeout: 5), "Recording clock is missing")
            waitUntil("Recording clock did not reach 5 s", timeout: 15) { self.seconds(duration.label).map { $0 >= 5 } ?? false }
            tap("recording.finish.button")
            XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8), "Did not return to Now Playing")

            // The episode carries on after a recording; pause it where it is.
            XCTAssertTrue(playPause.waitForExistence(timeout: 5), "Playback control is missing")
            waitUntil("Episode did not carry on after the Margin was saved", timeout: 10) { self.playPause.label == "Pause" }
            playPause.tap()
            waitUntil("Episode did not reach the paused state") { self.playPause.label == "Play" }
            pausedSeconds = try position()
            XCTAssertTrue((17 * 60...25 * 60).contains(pausedSeconds), "Episode paused at \(pausedSeconds) s, not near 20:00")
        }

        XCTContext.runActivity(named: "J9 step 3: Force-quit; a friend's Margin from before this point arrives; press Continue") { _ in
            app.terminate()
            app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_KEEP_LIBRARY"] = "1"
            app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_COOP"] = "1"
            app.launch()
            XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8), "Library did not reopen")
            XCTAssertTrue(element("library.row.\(itemId)").waitForExistence(timeout: 5),
                          "Episode is missing from the Library after relaunch")
            tap("queue.start.\(itemId)")

            // The identifier is what the app sets; some iOS versions drop it from a dialog's buttons, so fall back to its words.
            let hear = offerButton("newMarginsOffer.review", orLabel: "Hear new Margins first")
            XCTAssertTrue(hear.waitForExistence(timeout: 5), "Continue did not offer the new Margin first")
            XCTAssertFalse(element("playback.screen").exists, "Continue skipped past the new Margin without asking")
            XCTAssertTrue(offerButton("newMarginsOffer.skip", orLabel: "Listen without them").exists,
                          "The offer has no way to carry on without the new Margin")
            hear.tap()
        }

        XCTContext.runActivity(named: "J9 step 4: The friend's Margin plays in place after a lead-in") { _ in
            XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8), "Now Playing did not open")
            let progress = element("review.progress")
            XCTAssertTrue(progress.waitForExistence(timeout: 8), "The review card did not appear")
            XCTAssertTrue(progress.label.contains("1 of 1"), "The review does not say it is one Margin: \(progress.label)")
            XCTAssertTrue(element("review.comingUp").waitForExistence(timeout: 5), "No lead-in before the friend's Margin")
            waitUntil("The lead-in did not start about \(leadIn) s before the Margin; clock shows \(element("playback.progress.label").label)", timeout: 10) {
                self.currentPosition().map { ($0 >= self.friendMarginAt - self.leadIn - 10) && $0 <= self.friendMarginAt + 2 } ?? false
            }
            XCTAssertTrue(element("review.playing").waitForExistence(timeout: 25), "The friend's Margin never started playing")
            XCTAssertFalse(element("item.lastFailure").exists, "A playback problem was reported")
        }

        try XCTContext.runActivity(named: "J9 step 5: The episode carries on from where you were") { _ in
            waitUntil("The review card did not go away after the Margin", timeout: 25) { !self.element("review.progress").exists }
            try waitUntilPlaying("The episode did not carry on after the review")
            let resumed = try position()
            XCTAssertTrue(abs(resumed - pausedSeconds) <= 35,
                          "Episode carried on at \(resumed) s, not where you left off (\(pausedSeconds) s)")
            let start = resumed
            waitUntil("The episode clock is stuck after the review", timeout: 8) { self.currentPosition().map { $0 > start } ?? false }
            XCTAssertFalse(element("item.lastFailure").exists, "A playback problem was reported")
        }
    }

    private var playPause: XCUIElement { app.buttons["playback.play.button"] }

    private func offerButton(_ identifier: String, orLabel label: String) -> XCUIElement {
        let byIdentifier = app.buttons[identifier].firstMatch
        return byIdentifier.waitForExistence(timeout: 5) ? byIdentifier : app.buttons[label].firstMatch
    }

    private func waitUntilPlaying(_ message: String) throws {
        XCTAssertTrue(playPause.waitForExistence(timeout: 5), "Playback control is missing")
        waitUntil(message, timeout: 10) { self.playPause.isEnabled && self.playPause.label == "Pause" }
    }

    /// Taps the position slider at a fraction of its width, as a listener would.
    private func scrub(to fraction: CGFloat) throws {
        let scrubber = element("playback.scrubber")
        XCTAssertTrue(scrubber.waitForExistence(timeout: 5), "Episode scrubber is missing")
        XCTAssertTrue(scrubber.isEnabled, "Episode scrubber is disabled")
        scrubber.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: 0.5)).tap()
    }

    /// The episode's elapsed-time label in seconds.
    private func position() throws -> Int {
        let label = element("playback.progress.label")
        XCTAssertTrue(label.waitForExistence(timeout: 5), "Episode clock is missing")
        return try XCTUnwrap(seconds(label.label), "Episode clock is not a time: \(label.label)")
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
