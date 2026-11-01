import XCTest

/// Opens each main screen from the seeded launch and attaches one named screenshot per screen, in
/// light and dark appearance, so an unattended integration run can hand the critics the whole app
/// (#381). It only checks that each screen appears; what the screens show may change freely.
///
/// Export the screenshots from the result bundle with
/// `xcrun xcresulttool export attachments --path <run>.xcresult --output-path <folder>`;
/// `verify-tests.py --plan tour` does that itself and lists them in its manifest.
final class ScreenTourTests: XCTestCase {
    private var app: XCUIApplication!
    private var appearance = "light"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        // The simulator keeps its appearance between runs; leave it as the other UI tests expect.
        XCUIDevice.shared.appearance = .light
    }

    func testTourInLightAppearance() throws {
        tour(.light, named: "light")
    }

    func testTourInDarkAppearance() throws {
        tour(.dark, named: "dark")
    }

    /// The Live Activity's Lock Screen card at the default and the largest text size (#1940). A UI test can't lock
    /// the simulator, so the app lays the real card out at the narrowest Lock Screen width in place of its screens,
    /// with its measured size printed under it.
    func testLiveActivityCardAtDefaultAndLargestTextSize() throws {
        XCUIDevice.shared.appearance = .dark
        appearance = "dark"
        for size in ["large", "accessibility5"] {
            app.terminate()
            app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_LIVE_ACTIVITY_PREVIEW"] = size
            launch()
            XCTAssertTrue(element("liveActivityPreview.screen").waitForExistence(timeout: 10),
                          "The Live Activity card did not appear at \(size)")
            for status in ["paused", "playing"] {
                // The caption reads 0 × 0 until the card has been laid out and measured.
                let caption = element("liveActivityPreview.size.\(status)")
                let measured = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "exists == true AND NOT (label CONTAINS %@)", ": 0 × 0 pt"), object: caption
                )
                XCTAssertEqual(XCTWaiter().wait(for: [measured], timeout: 5), .completed,
                               "The \(status) card was not measured at \(size)")
            }
            capture("10-live-activity-\(size)")
        }
    }

    private func tour(_ style: XCUIDevice.Appearance, named name: String) {
        XCUIDevice.shared.appearance = style
        appearance = name
        launch()

        XCTAssertTrue(element("library.screen").waitForExistence(timeout: 10), "Library did not appear")
        capture("01-library")

        let row = app.buttons["library.row.item-pill"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The seeded item is missing from Library")
        row.tap()
        XCTAssertTrue(element("item.screen").waitForExistence(timeout: 5), "Item did not appear")
        capture("02-item")
        app.buttons["item.home.button"].tap()
        XCTAssertTrue(element("library.screen").waitForExistence(timeout: 5))

        app.buttons["queue.start.item-pill"].tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 10), "The text player did not appear")
        pausePlaybackIfPlaying()
        capture("03-player-text")

        element("playback.options.button").tap()
        scrollTo("playback.export.button").tap()
        XCTAssertTrue(element("export.screen").waitForExistence(timeout: 5), "Share/Export did not appear")
        capture("04-share-export")
        app.buttons["export.home.button"].tap()
        XCTAssertTrue(element("library.screen").waitForExistence(timeout: 5))

        tapRoot("Margins")
        XCTAssertTrue(element("margins.screen").waitForExistence(timeout: 5), "Margins did not appear")
        capture("05-margins")

        tapRoot("Following")
        XCTAssertTrue(element("sources.screen").waitForExistence(timeout: 5), "Following did not appear")
        capture("06-following")

        // The first-run drawer opens by itself only on an empty Library; Following opens the same drawer.
        scrollTo("sources.browseCatalog").tap()
        XCTAssertTrue(element("catalog.drawer.done").waitForExistence(timeout: 5), "The first-run drawer did not appear")
        capture("07-first-run-drawer")
        element("catalog.drawer.done").tap()
        XCTAssertTrue(element("sources.screen").waitForExistence(timeout: 5))

        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(element("settings.screen").waitForExistence(timeout: 5), "Settings did not appear")
        capture("08-settings")

        openPodcastPlayer()
        capture("09-player-podcast")
    }

    /// Adds a podcast episode through the app's own UI-testing link resolver (the one
    /// Gate1FlowUITests uses for the episode picker) and starts it. The episode's audio URL doesn't
    /// resolve, so the player shows the podcast layout without any network audio.
    private func openPodcastPlayer() {
        app.terminate()
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_AMBIGUOUS_SOURCE_LINK"] = "1"
        launch()
        XCTAssertTrue(element("library.screen").waitForExistence(timeout: 10))
        app.buttons["home.addSource.button"].tap()
        scrollTo("addSource.route.linkOrPodcast").tap()
        let link = element("sourceLink.url.field")
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
        link.typeText("https://open.spotify.com/episode/screen-tour")
        app.buttons["sourceLink.import.button"].tap()
        let episode = app.buttons["sourceLink.candidate.0"]
        XCTAssertTrue(episode.waitForExistence(timeout: 5), "The episode picker did not appear")
        episode.tap()
        let close = app.buttons["Close"].firstMatch
        if close.waitForExistence(timeout: 3) {
            close.tap()
        }
        XCTAssertTrue(element("library.screen").waitForExistence(timeout: 5))

        let podcastRow = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "library.row.", "Ambiguous Episode One"
        )).firstMatch
        XCTAssertTrue(podcastRow.waitForExistence(timeout: 8), "The podcast episode did not reach Library")
        let start = app.buttons[podcastRow.identifier.replacingOccurrences(of: "library.row.", with: "queue.start.")]
        XCTAssertTrue(start.exists, "The podcast row has no play control")
        start.tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 10), "The podcast player did not appear")
    }

    private func launch() {
        app.launchArguments = ["--ui-testing",
            "-libraryContentTypeFilter", "all", "-libraryListeningStateFilter", "unfinished",
            "-libraryOfflineStateFilter", "all", "-librarySort", "recently_added",
            "-libraryUnfinishedDefaultApplied", "YES"]
        app.launchEnvironment["SPOKEN_MARGINS_UI_TESTING"] = "1"
        app.launch()
    }

    private func capture(_ screen: String) {
        // Let the navigation transition finish so the screenshot shows the screen, not the push.
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "settle")], timeout: 0.8)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "tour-\(appearance)-\(screen)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func tapRoot(_ name: String) {
        let button = app.buttons[name].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Missing \(name) root control")
        button.tap()
    }

    /// `isHittable` fails the test on an element with no frame yet, so look at the frame first (#2760).
    private func isReadyToTap(_ candidate: XCUIElement) -> Bool {
        guard candidate.exists else { return false }
        let frame = candidate.frame
        guard !frame.isNull, !frame.isInfinite, !frame.isEmpty else { return false }
        return candidate.isHittable
    }

    private func scrollTo(_ identifier: String) -> XCUIElement {
        let candidate = element(identifier)
        for _ in 0..<12 where !isReadyToTap(candidate) {
            app.swipeUp()
        }
        XCTAssertTrue(candidate.waitForExistence(timeout: 5), "Missing \(identifier)")
        return candidate
    }

    private func pausePlaybackIfPlaying() {
        let playPause = element("playback.play.button")
        guard playPause.waitForExistence(timeout: 8) else { return }
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@ OR label == %@", "Play", "Pause"), object: playPause
        )], timeout: 20)
        if playPause.label == "Pause" {
            playPause.tap()
        }
    }
}
