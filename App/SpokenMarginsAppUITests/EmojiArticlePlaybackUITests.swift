import XCTest

final class EmojiArticlePlaybackUITests: XCTestCase {
    private let title = "Designing emoji for the way we communicate today"

    func testExactEmojiArticleCompletesAfterPauseAndResumeNearCrashPoint() throws {
        let article = try Self.fixtureText()
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing",
            "-libraryContentTypeFilter", "all", "-libraryListeningStateFilter", "unfinished",
            "-libraryOfflineStateFilter", "all", "-librarySort", "recently_added",
            "-libraryUnfinishedDefaultApplied", "YES"]
        app.launchEnvironment["SPOKEN_MARGINS_UI_TESTING"] = "1"
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_TITLE"] = title
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_TEXT"] = article
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_URL"] = Self.sourceURL
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SPEECH_RATE"] = "0.55"
        // An app-hosted adapter run can leave this bundle running.
        app.terminate()
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["home.screen"].waitForExistence(timeout: 10))
        let start = app.buttons["queue.start.item-ui-text-regression"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertTrue(app.descendants(matching: .any)["playback.screen"].waitForExistence(timeout: 5))

        let progress = app.descendants(matching: .any)["playback.progress.label"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        let playPause = app.buttons["playback.play.button"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 5))
        let deadline = Date().addingTimeInterval(720)
        var highestProgress = 0
        var didExerciseCrashPointResume = false
        while Date() < deadline {
            XCTAssertNotEqual(app.state, .notRunning, "The app terminated while speaking the exact emoji article.")
            let progressElements = app.descendants(matching: .any)
                .matching(identifier: "playback.progress.label")
                .allElementsBoundByIndex
            if let progressElement = progressElements.first,
               let percent = Self.progressPercent(from: progressElement.label) {
                highestProgress = max(highestProgress, percent)
                if !didExerciseCrashPointResume, percent >= 23 {
                    playPause.tap()
                    XCTAssertTrue(Self.wait(forLabel: "Play", on: playPause, timeout: 5))
                    let pausedProgress = try XCTUnwrap(Self.progressPercent(from: progress.label))
                    Thread.sleep(forTimeInterval: 2)
                    XCTAssertEqual(
                        Self.progressPercent(from: progress.label),
                        pausedProgress,
                        "Source progress advanced while speech was paused near the prior crash point."
                    )
                    playPause.tap()
                    XCTAssertTrue(Self.wait(forLabel: "Pause", on: playPause, timeout: 5))
                    didExerciseCrashPointResume = true
                }
                if percent == 100 {
                    XCTAssertTrue(didExerciseCrashPointResume)
                    // Completion may close the session between reading progress and the screen.
                    let completion = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                        app.descendants(matching: .any)["playback.screen"].exists ||
                        app.descendants(matching: .any)["home.screen"].exists
                    }, object: nil)
                    XCTAssertEqual(XCTWaiter().wait(for: [completion], timeout: 5), .completed)
                    return
                }
            } else if app.descendants(matching: .any)["home.screen"].exists {
                XCTAssertTrue(didExerciseCrashPointResume)
                XCTAssertGreaterThanOrEqual(
                    highestProgress,
                    90,
                    "Playback returned Home before reaching the end of the emoji article."
                )
                return
            }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTFail("The exact emoji article did not complete; highest progress was \(highestProgress)%.")
    }

    private static func fixtureText() throws -> String {
        let bundle = Bundle(for: EmojiArticlePlaybackUITests.self)
        let url = try XCTUnwrap(bundle.url(forResource: "emoji-article-crash-regression", withExtension: "txt"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func progressPercent(from label: String) -> Int? {
        guard let token = label.split(separator: "%", maxSplits: 1).first else { return nil }
        return Int(token.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func wait(forLabel label: String, on element: XCUIElement, timeout: TimeInterval) -> Bool {
        XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)],
            timeout: timeout
        ) == .completed
    }

    private static let sourceURL = "https://blog.google/products-and-platforms/platforms/android/world-emoji-day-noto-3d/"
}
