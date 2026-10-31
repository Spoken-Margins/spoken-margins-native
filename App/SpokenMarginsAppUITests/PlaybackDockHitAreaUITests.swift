import XCTest

// #430 / #151: every playback dock control takes a tap anywhere in a 44 × 44 pt area around it. Accessibility frames
// alone can't show this: a plain SwiftUI button reports its 44 pt frame but took taps only on its glyph or word, so
// these tap by coordinate near each edge of the larger of the control's frame and a 44 pt square, then check the
// control acted. Not tapped here: Add a Margin and the pencil (filled 52 pt shapes, J3's to tap), Skim (needs a
// listening map the seeds don't have) and the finished-item Share; they use the same 44 pt target helper.
final class PlaybackDockHitAreaUITests: XCTestCase {
    private var app: XCUIApplication!

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

    /// The live-speech article seed J1 uses: it plays reliably, so Play/Pause has a state to flip.
    func testDockControlsTakeTapsAcrossTheirWholeTarget() throws {
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_TITLE"] = "Dock targets"
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_TEXT"] = (1...12)
            .map { "Sentence \($0) walks a little further along the path." }.joined(separator: " ")
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_URL"] = "https://example.com/dock-targets"
        app.launch()
        let start = app.buttons["queue.start.item-ui-text-regression"]
        XCTAssertTrue(start.waitForExistence(timeout: 8), "The seeded article's start control is missing")
        start.tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8), "Now Playing did not open")

        XCTContext.runActivity(named: "Play/Pause flips from each edge") { _ in
            let playPause = app.buttons["playback.play.button"]
            // Wait for the start to finish, so a missed tap can't be covered by auto-start flipping the label.
            XCTAssertTrue(waitFor(playPause, "label == %@ AND enabled == true", "Pause", timeout: 20),
                          "The article never reached the visible playing state")
            for point in edgePoints(of: playPause) {
                let before = playPause.label
                tap(point)
                XCTAssertTrue(waitFor(playPause, "label != %@ AND label IN %@", before, ["Play", "Pause"]),
                              "A tap at \(point) did not flip \(before); the target is smaller than 44 pt there")
            }
            if playPause.label == "Pause" { playPause.tap() }
            XCTAssertTrue(waitFor(playPause, "label == %@", "Play"), "The article did not pause")
        }

        XCTContext.runActivity(named: "Each pane takes taps from each edge") { _ in
            for id in ["playback.timeline.button", "playback.margins.button", "playback.now.button"] {
                let pane = app.buttons[id].firstMatch
                XCTAssertTrue(pane.waitForExistence(timeout: 5), "\(id) is missing")
                for point in edgePoints(of: pane) {
                    if id != "playback.now.button" { app.buttons["playback.now.button"].tap() }
                    else { app.buttons["playback.timeline.button"].firstMatch.tap() }
                    tap(point)
                    XCTAssertTrue(waitFor(pane, "selected == true"), "A tap at \(point) did not select \(id)")
                }
            }
        }

        // The skip buttons are filled 62 pt circles, so this is a check that they still take a tap near their edge,
        // not a fix: the same as Play/Pause.
        XCTContext.runActivity(named: "Skip forward and back move the passage from their leading and trailing edges") { _ in
            for id in ["playback.forward.button", "playback.back.button"] {
                let skip = app.buttons[id]
                XCTAssertTrue(skip.waitForExistence(timeout: 5), "\(id) is missing")
                // Forward first, from near the start, so back always has somewhere to go.
                for point in edgePoints(of: skip).prefix(2) {
                    let before = currentSentence.identifier
                    tap(point)
                    XCTAssertTrue(waitFor(currentSentence, "identifier != %@", before),
                                  "A tap at \(point) on \(id) did not move the passage")
                }
            }
        }

        XCTContext.runActivity(named: "Speed changes from each edge") { _ in
            let rate = app.buttons["playback.rate.button"].firstMatch
            XCTAssertTrue(rate.waitForExistence(timeout: 5), "The speed control is missing")
            let original = rate.label
            for point in edgePoints(of: rate) {
                let before = rate.label
                tap(point)
                XCTAssertTrue(waitFor(rate, "label != %@", before), "A tap at \(point) did not change the speed")
            }
            for _ in 0..<12 where rate.label != original { rate.tap() }
            XCTAssertEqual(rate.label, original, "The speed did not return to where it started")
        }

        XCTContext.runActivity(named: "The article's scrubber takes a tap above and below its track") { _ in
            assertScrubberTakesTapsOffItsTrack()
        }

        XCTContext.runActivity(named: "More opens from each edge") { _ in
            let more = element("playback.options.button")
            XCTAssertTrue(more.waitForExistence(timeout: 5), "More is missing")
            for point in edgePoints(of: more) {
                tap(point)
                XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5), "A tap at \(point) did not open More")
                app.buttons["Done"].tap()
                XCTAssertTrue(waitFor(app.buttons["Done"], "exists == false"), "More did not close")
            }
        }

        XCTContext.runActivity(named: "Library opens from each edge") { _ in
            for index in 0..<4 {
                let library = app.buttons["playback.home.button"]
                XCTAssertTrue(library.waitForExistence(timeout: 5), "Library is missing")
                let point = edgePoints(of: library)[index]
                tap(point)
                // Now Playing leaving is the proof: the Library can sit under it the whole time.
                XCTAssertTrue(waitFor(element("playback.screen"), "exists == false") && element("home.screen").exists,
                              "A tap at \(point) did not open the Library")
                let open = app.buttons["miniPlayer.open.button"]
                XCTAssertTrue(open.waitForExistence(timeout: 5), "The mini player is missing")
                open.tap()
                XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 5), "Now Playing did not reopen")
            }
        }
    }

    /// #2917: the edge swipe back must keep working now that its strip no longer sits over the leading 32 pt and
    /// shadows taps there. A drag that starts a few points from the screen edge takes Now Playing back to Library.
    func testEdgeSwipeStillGoesBackToLibrary() throws {
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_TITLE"] = "Edge swipe"
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_TEXT"] = (1...12)
            .map { "Sentence \($0) walks a little further along the path." }.joined(separator: " ")
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_URL"] = "https://example.com/edge-swipe"
        app.launch()
        let start = app.buttons["queue.start.item-ui-text-regression"]
        XCTAssertTrue(start.waitForExistence(timeout: 8), "The seeded article's start control is missing")
        start.tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8), "Now Playing did not open")

        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 6, dy: 0))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .default, thenHoldForDuration: 0)
        XCTAssertTrue(waitFor(element("playback.screen"), "exists == false") && element("home.screen").exists,
                      "A swipe from the leading edge did not take Now Playing back to Library")
    }

    /// J2's downloaded 25-minute episode: the media scrubber and the seconds skips.
    func testPodcastScrubberAndSkipsTakeTapsAcrossTheirWholeTarget() throws {
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_PODCAST"] = "1"
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_TITLE"] = "Dock targets episode"
        app.launch()
        let start = app.buttons["queue.start.item-ui-podcast"]
        XCTAssertTrue(start.waitForExistence(timeout: 8), "The seeded episode's start control is missing")
        start.tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8), "Now Playing did not open")
        let playPause = app.buttons["playback.play.button"]
        XCTAssertTrue(waitFor(playPause, "label == %@ AND enabled == true", "Pause", timeout: 20),
                      "The episode never reached the visible playing state")
        playPause.tap()
        XCTAssertTrue(waitFor(playPause, "label == %@", "Play"), "The episode did not pause")

        XCTContext.runActivity(named: "The episode's scrubber takes a tap above and below its track") { _ in
            assertScrubberTakesTapsOffItsTrack()
        }

        XCTContext.runActivity(named: "Skip back and forward move the clock from their leading and trailing edges") { _ in
            for id in ["playback.back.button", "playback.forward.button"] {
                let skip = app.buttons[id]
                XCTAssertTrue(skip.waitForExistence(timeout: 5), "\(id) is missing")
                for point in edgePoints(of: skip).prefix(2) {
                    let before = element("playback.progress.label").label
                    tap(point)
                    XCTAssertTrue(waitFor(element("playback.progress.label"), "label != %@", before),
                                  "A tap at \(point) on \(id) did not move the clock")
                }
            }
        }
    }

    /// The bundled three-chapter article (J1 step 4's fixture) shows Next chapter in the chapter row.
    func testChapterRowControlsTakeTapsAcrossTheirWholeTarget() throws {
        app.launch()
        let start = app.buttons["queue.start.item-pill"]
        XCTAssertTrue(start.waitForExistence(timeout: 8), "The fixture article's start control is missing")
        start.tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8), "Now Playing did not open")
        let playPause = app.buttons["playback.play.button"]
        if waitFor(playPause, "label == %@", "Pause", timeout: 20) { playPause.tap() }

        XCTContext.runActivity(named: "Next chapter moves on from its leading and top edges") { _ in
            let chapter = app.buttons["playback.dock.chapter.button"]
            XCTAssertTrue(chapter.waitForExistence(timeout: 5), "The chapter title is missing")
            // Three chapters: two moves from chapter one. Leading and top are the edges a glyph-only target misses.
            for index in [0, 2] {
                let next = app.buttons["playback.nextChapter.button"]
                XCTAssertTrue(next.waitForExistence(timeout: 5), "Next chapter is missing")
                let before = chapter.label
                let point = edgePoints(of: next)[index]
                tap(point)
                XCTAssertTrue(waitFor(chapter, "label != %@", before), "A tap at \(point) did not move to the next chapter")
            }
        }

        XCTContext.runActivity(named: "The chapter title opens the item from the far end of its row") { _ in
            let chapter = app.buttons["playback.dock.chapter.button"]
            // The dock re-lays out after a chapter change; a frame read mid-move tapped where the row used to be (#2884).
            let frame = settledFrame(of: chapter)
            tap(CGPoint(x: frame.maxX - 4, y: frame.midY))
            XCTAssertTrue(element("item.screen").waitForExistence(timeout: 5)
                          && waitFor(element("playback.screen"), "exists == false"),
                          "A tap at the end of the chapter row, past a short title, did not open the item")
        }
    }

    // MARK: - Helpers

    /// Taps 2 points inside the top and bottom of a 44 pt band around the track (or the scrubber's frame, if taller),
    /// at two different places along it, and checks that each tap moved the position.
    private func assertScrubberTakesTapsOffItsTrack() {
        let scrubber = element("playback.scrubber")
        XCTAssertTrue(scrubber.waitForExistence(timeout: 5), "The scrubber is missing")
        let frame = scrubber.frame
        let height = max(frame.height, 44)
        for (x, dy) in [(0.75, -(height / 2 - 2)), (0.3, height / 2 - 2)] {
            let before = element("playback.progress.label").label
            tap(CGPoint(x: frame.minX + frame.width * x, y: frame.midY + dy))
            XCTAssertTrue(waitFor(element("playback.progress.label"), "label != %@", before),
                          "A tap \(dy) points off the scrubber's centre did not seek")
        }
    }

    /// Near each edge of the larger of the control's frame and a 44 pt square around its centre: leading, trailing,
    /// top, bottom. Two points in from the edge, so rounding never lands a tap on a neighbour.
    private func edgePoints(of element: XCUIElement) -> [CGPoint] {
        let frame = settledFrame(of: element)
        let halfWidth = max(frame.width, 44) / 2 - 2
        let halfHeight = max(frame.height, 44) / 2 - 2
        return [CGPoint(x: frame.midX - halfWidth, y: frame.midY), CGPoint(x: frame.midX + halfWidth, y: frame.midY),
                CGPoint(x: frame.midX, y: frame.midY - halfHeight), CGPoint(x: frame.midX, y: frame.midY + halfHeight)]
    }

    /// The element's frame once two reads 0.3 s apart agree. After a chapter change the dock moves a moment later, and
    /// a coordinate tap at the old position misses (#2884). Falls back to the last read if it never settles.
    private func settledFrame(of element: XCUIElement, timeout: TimeInterval = 5) -> CGRect {
        let deadline = Date().addingTimeInterval(timeout)
        var frame = element.frame
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.3)
            let next = element.frame
            if next == frame { return next }
            frame = next
        }
        return frame
    }

    private func tap(_ point: CGPoint) {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).tap()
    }

    private func waitFor(_ element: XCUIElement, _ format: String, _ args: Any..., timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, argumentArray: args),
                                                    object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private var currentSentence: XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND value == %@",
                                        "playback.now.passage.sentence.", "Current sentence")).firstMatch
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
