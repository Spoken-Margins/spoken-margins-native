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
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_TEXT"] = String(
            repeating: "On a short walk, notice the trees and the light along the path. ",
            count: 20
        )
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
            let movesWhilePaused = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label != %@", pausedPosition), object: progress
            )
            movesWhilePaused.isInverted = true
            XCTAssertEqual(XCTWaiter().wait(for: [movesWhilePaused], timeout: 2), .completed,
                           "Article position kept changing after pause")
        }
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func positionPercent(_ progress: XCUIElement) -> Int? {
        Int(progress.label.replacingOccurrences(of: "%", with: ""))
    }
}
