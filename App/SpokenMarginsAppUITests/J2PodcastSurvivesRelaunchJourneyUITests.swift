import XCTest

// J2: a downloaded podcast episode keeps its place across a force-quit, and a
// scrub made before pressing play is where playback starts.
// The episode is a generated 25-minute local file (SPOKEN_MARGINS_UI_TEST_PODCAST),
// so adding it from a feed and the download itself stay with the agent run.
// Chapters are not seeded, so step 4 scrubs rather than jumping to a chapter.
// Audible audio, the Lock Screen and Bluetooth stay with the owner on a device.
// A moving clock alone does not prove audio.
final class J2PodcastSurvivesRelaunchJourneyUITests: XCTestCase {
    private var app: XCUIApplication!
    private let episodeTitle = "J2: A long episode"
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
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_TITLE"] = episodeTitle
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testPodcastPlaybackSurvivesRelaunch() throws {
        XCTContext.runActivity(named: "J2 step 1: Downloaded episode is in the Library (offline seed)") { _ in
            app.launch()
            XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8), "Library did not open")
            XCTAssertTrue(element("library.row.\(itemId)").waitForExistence(timeout: 5),
                          "Seeded episode did not appear in the Library")
            let start = app.buttons["queue.start.\(itemId)"]
            XCTAssertTrue(start.waitForExistence(timeout: 5), "Episode's start control is missing")
            XCTAssertEqual(start.value as? String, "Ready offline", "Episode is not shown as downloaded")
        }

        var pausedSeconds = 0
        try XCTContext.runActivity(named: "J2 step 2: Play, then scrub to about 20:00 and keep playing") { _ in
            let start = app.buttons["queue.start.\(itemId)"]
            XCTAssertTrue(start.isEnabled, "Episode cannot be started")
            start.tap()
            XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8), "Now Playing did not open")
            let title = app.buttons["playback.itemTitle.button"]
            XCTAssertTrue(title.waitForExistence(timeout: 5), "Playing item's title is missing")
            XCTAssertEqual(title.label, episodeTitle, "A different item is playing")
            try waitUntilPlaying("Episode never reached the visible playing state")

            try scrub(to: 0.8)
            let landed = try waitForPosition(in: 17 * 60...23 * 60, "Scrub did not land near 20:00")
            try waitForPosition(in: (landed + 1)...(landed + 30), "Episode did not keep playing from the scrubbed point")
            XCTAssertEqual(playPause.label, "Pause", "Playback stopped after the scrub")
            assertNoSeekFailure()
        }

        try XCTContext.runActivity(named: "J2 step 3: Pause, force-quit and reopen") { _ in
            playPause.tap()
            let paused = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label == %@ AND enabled == true", "Play"), object: playPause
            )
            XCTAssertEqual(XCTWaiter().wait(for: [paused], timeout: 5), .completed,
                           "Episode did not reach the visible paused state")
            pausedSeconds = try XCTUnwrap(position(), "Episode position is not a time")

            app.terminate()
            app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_KEEP_LIBRARY"] = "1"
            app.launch()
            XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8), "Library did not reopen")
            XCTAssertTrue(element("library.row.\(itemId)").waitForExistence(timeout: 5),
                          "Episode is missing from the Library after relaunch")
            let open = app.buttons["miniPlayer.open.button"]
            XCTAssertTrue(open.waitForExistence(timeout: 8), "No mini player for the paused episode after relaunch")
            open.tap()
            XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8), "Now Playing did not reopen")
            XCTAssertTrue(playPause.waitForExistence(timeout: 5), "Playback control is missing after relaunch")
            XCTAssertEqual(playPause.label, "Play", "Episode started playing by itself after relaunch")
            // A few seconds, not 30: a pause that saved only its last periodic tick would reopen well short of the label.
            try waitForPosition(in: max(0, pausedSeconds - 5)...(pausedSeconds + 5),
                                "Episode did not reopen where it was paused (\(pausedSeconds) s)")
        }

        try XCTContext.runActivity(named: "J2 step 4: Scrub before pressing play, then play from the new point") { _ in
            try scrub(to: 0.3)
            let target = try waitForPosition(in: 4 * 60...11 * 60, "Scrub before play did not land near 7:30")
            playPause.tap()
            try waitUntilPlaying("Episode did not start after the scrub")
            try waitForPosition(in: (target + 1)...(target + 30), "Playback did not start from the scrubbed point")

            // Prove a negative: the clock must not jump back to the pre-relaunch point.
            let jumpsBack = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in (self.position() ?? 0) > pausedSeconds - 120 }, object: nil
            )
            jumpsBack.isInverted = true
            XCTAssertEqual(XCTWaiter().wait(for: [jumpsBack], timeout: 4), .completed,
                           "Playback jumped back toward \(pausedSeconds) s after starting at \(target) s")
            XCTAssertEqual(playPause.label, "Pause", "Playback stopped after starting from the scrubbed point")
            assertNoSeekFailure()
        }
    }

    private var playPause: XCUIElement { app.buttons["playback.play.button"] }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func waitUntilPlaying(_ message: String) throws {
        XCTAssertTrue(playPause.waitForExistence(timeout: 5), "Playback control is missing")
        let playing = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@ AND enabled == true", "Pause"), object: playPause
        )
        XCTAssertEqual(XCTWaiter().wait(for: [playing], timeout: 10), .completed, message)
    }

    /// Taps the position slider at a fraction of its width, as a listener would.
    private func scrub(to fraction: CGFloat) throws {
        let scrubber = element("playback.scrubber")
        XCTAssertTrue(scrubber.waitForExistence(timeout: 5), "Episode scrubber is missing")
        XCTAssertTrue(scrubber.isEnabled, "Episode scrubber is disabled")
        scrubber.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: 0.5)).tap()
    }

    /// Waits until the elapsed-time label is inside `range`, then returns the time it shows.
    @discardableResult
    private func waitForPosition(in range: ClosedRange<Int>, _ message: String) throws -> Int {
        let inRange = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in self.position().map { range.contains($0) } ?? false }, object: nil
        )
        let result = XCTWaiter().wait(for: [inRange], timeout: 10)
        XCTAssertEqual(result, .completed, "\(message); clock shows \(element("playback.progress.label").label)")
        return try XCTUnwrap(position(), "Episode position is not a time")
    }

    /// The elapsed-time label ("m:ss" or "h:mm:ss") in seconds.
    private func position() -> Int? {
        let label = element("playback.progress.label")
        guard label.exists else { return nil }
        let parts = label.label.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2, parts.count == label.label.split(separator: ":").count else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    private func assertNoSeekFailure() {
        XCTAssertFalse(element("item.lastFailure").exists, "A playback problem was reported")
        let banner = element("app.feedback.banner")
        if banner.exists {
            XCTAssertFalse(banner.label.localizedCaseInsensitiveContains("seek"), "Seek failure shown: \(banner.label)")
        }
    }
}
