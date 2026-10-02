import XCTest

// J2 uses the bundled 40-second enclosure with the real podcast player/cache.
// Feed intake, downloading, a 20-minute seek, and audible content stay with the
// agent/owner journey. This script covers playback, seeks and persisted relaunch.
final class J2PodcastPlaybackSurvivesRelaunchJourneyUITests: XCTestCase {
    private var app: XCUIApplication!
    private let itemID = "item-ui-podcast-j2"
    private let episodeTitle = "J2: Offline podcast"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing",
            "-libraryContentTypeFilter", "all", "-libraryListeningStateFilter", "unfinished",
            "-libraryOfflineStateFilter", "all", "-librarySort", "recently_added",
            "-libraryUnfinishedDefaultApplied", "YES", "-mediaPlaybackRate", "1.0"]
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_PODCAST"] = "1"
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testPodcastPlaybackSurvivesRelaunch() throws {
        var savedPosition = 0
        XCTContext.runActivity(named: "J2 step 1: Episode is downloaded (offline local seed)") { _ in
            app.launch()
            XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8), "Library did not open")
            XCTAssertTrue(element("library.row.\(itemID)").waitForExistence(timeout: 5),
                          "Seeded podcast did not appear")
        }

        try XCTContext.runActivity(named: "J2 step 2: Play, scrub forward and keep playing") { _ in
            let start = app.buttons["queue.start.\(itemID)"]
            XCTAssertTrue(start.waitForExistence(timeout: 5), "Episode's start control is missing")
            XCTAssertTrue(start.isEnabled)
            start.tap()
            assertEpisodeOpen()
            waitForPlayback(label: "Pause")
            let openingPosition = try position()
            waitForAdvance(from: openingPosition)
            try scrub(to: 0.5)
            let soughtPosition = try position()
            // Broad bounds allow thumb/clock rounding; the short fixture substitutes
            // a middle-of-episode seek for the owner's about-20:00 seek.
            XCTAssertTrue((17...23).contains(soughtPosition), "Forward scrub did not reach the middle of the episode")
            waitForAdvance(from: soughtPosition)
            XCTAssertEqual(app.buttons["playback.play.button"].label, "Pause")
            XCTAssertFalse(element("app.feedback.dismiss").exists, "Playback/seek presented an error")
        }

        try XCTContext.runActivity(named: "J2 step 3: Pause, terminate and reopen persisted Library") { _ in
            app.buttons["playback.play.button"].tap()
            waitForPlayback(label: "Play")
            savedPosition = try position()
            assertClockHolds(at: savedPosition)
            app.terminate()
            // --ui-testing resets the library on every launch. Remove it to test
            // real restoration; leave the seed environment set to exercise its guard.
            app.launchArguments.removeAll { $0 == "--ui-testing" }
            app.launch()
            XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8), "Library did not reopen")
            let restoredPlayer = app.buttons["miniPlayer.open.button"]
            XCTAssertTrue(restoredPlayer.waitForExistence(timeout: 5), "Saved podcast session was not restored")
            restoredPlayer.tap()
            assertEpisodeOpen()
            waitForPlayback(label: "Play")
            let restoredPosition = try position()
            XCTAssertLessThanOrEqual(abs(restoredPosition - savedPosition), 2,
                                     "Relaunch lost the paused position or reseeded the Library")
            assertClockHolds(at: restoredPosition)
        }

        try XCTContext.runActivity(named: "J2 step 4: Seek while paused, then play at the new point") { _ in
            try scrub(to: 0.2)
            waitForPlayback(label: "Play")
            let newPosition = try position()
            XCTAssertTrue((6...10).contains(newPosition), "Paused scrub did not reach the new point")
            XCTAssertGreaterThan(savedPosition - newPosition, 8, "New seek must differ from the saved position")
            assertClockHolds(at: newPosition)
            app.buttons["playback.play.button"].tap()
            waitForPlayback(label: "Pause")

            let advances = advanceExpectation(from: newPosition)
            let jumpsAway = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard let seconds = self.clockSeconds() else { return true }
                return seconds < newPosition - 2 || seconds >= newPosition + 10
            }, object: nil)
            jumpsAway.isInverted = true
            let seekError = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == true"), object: element("app.feedback.dismiss")
            )
            seekError.isInverted = true
            XCTAssertEqual(XCTWaiter().wait(for: [advances, jumpsAway, seekError], timeout: 6), .completed,
                           "Podcast failed to advance from the new point, jumped away, or showed a seek error")
            XCTAssertEqual(app.buttons["playback.play.button"].label, "Pause", "Podcast stopped unexpectedly")
        }
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func assertEpisodeOpen() {
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8), "Now Playing did not open")
        let title = app.buttons["playback.itemTitle.button"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, episodeTitle, "A different item is playing")
        XCTAssertTrue(element("playback.progress.label").waitForExistence(timeout: 5), "Podcast clock is missing")
    }

    private func waitForPlayback(label: String) {
        let control = app.buttons["playback.play.button"]
        XCTAssertTrue(control.waitForExistence(timeout: 5), "Playback control is missing")
        let state = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@ AND enabled == true", label), object: control
        )
        XCTAssertEqual(XCTWaiter().wait(for: [state], timeout: 8), .completed,
                       "Podcast did not reach the \(label) control state")
    }

    private func clockSeconds() -> Int? {
        let parts = element("playback.progress.label").label.split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        let values = parts.compactMap { Int($0) }
        guard values.count == parts.count else { return nil }
        return values.reduce(0) { $0 * 60 + $1 }
    }

    private func position() throws -> Int {
        try XCTUnwrap(clockSeconds(), "Podcast position is not a clock value")
    }

    private func advanceExpectation(from seconds: Int) -> XCTNSPredicateExpectation {
        XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.clockSeconds().map { $0 > seconds } ?? false
        }, object: nil)
    }

    private func waitForAdvance(from seconds: Int) {
        XCTAssertEqual(XCTWaiter().wait(for: [advanceExpectation(from: seconds)], timeout: 5), .completed,
                       "Podcast clock did not advance while playing")
    }

    private func assertClockHolds(at seconds: Int) {
        let movement = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.clockSeconds() != seconds
        }, object: nil)
        movement.isInverted = true
        XCTAssertEqual(XCTWaiter().wait(for: [movement], timeout: 2), .completed,
                       "Paused podcast clock kept moving")
    }

    private func scrub(to fraction: Double) throws {
        let slider = app.sliders["playback.scrubber"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5), "Podcast scrubber is missing")
        XCTAssertTrue(slider.isEnabled)
        func coordinate(_ fraction: Double) -> XCUICoordinate {
            let inset = slider.frame.height / 2
            let x = inset + (slider.frame.width - 2 * inset) * fraction
            return slider.coordinate(withNormalizedOffset: CGVector(dx: x / slider.frame.width, dy: 0.5))
        }
        let currentFraction = Double(try position()) / 40.032
        coordinate(currentFraction).press(forDuration: 0.1, thenDragTo: coordinate(fraction),
                                          withVelocity: .slow, thenHoldForDuration: 0.1)
        let landing = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.clockSeconds().map { abs(Double($0) - fraction * 40.032) < 3 } ?? false
        }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [landing], timeout: 5), .completed,
                       "Podcast did not land at the requested scrub position")
    }
}
