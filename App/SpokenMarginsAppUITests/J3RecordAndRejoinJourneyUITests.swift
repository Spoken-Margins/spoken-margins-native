import XCTest

// J3 uses real fixture files and the normal podcast/Margin players. It cannot
// prove audible voice, microphone capture, Bluetooth or background behavior.
final class J3RecordAndRejoinJourneyUITests: XCTestCase {
    private var app: XCUIApplication!
    private let itemID = "item-ui-podcast"
    private let itemTitle = "UI Test Offline Podcast"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing",
            "-libraryContentTypeFilter", "all", "-libraryListeningStateFilter", "unfinished",
            "-libraryOfflineStateFilter", "all", "-librarySort", "recently_added",
            "-libraryUnfinishedDefaultApplied", "YES", "-mediaPlaybackRate", "1"]
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_RECORDING"] = "1"
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_PODCAST"] = "1"
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testRecordMarginAndRejoin() throws {
        var savedMarginID = ""
        var positionBeforeRecording = 0
        var positionBeforeMarginPlayback = 0

        try XCTContext.runActivity(named: "J3 step 1: Record about ten seconds, save, resume and find the Margin") { _ in
            app.launch()
            XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8), "Library did not open")
            tap("queue.start.\(itemID)")
            assertSourcePlaying()
            try assertSourceClockAdvances()
            positionBeforeRecording = try sourceSeconds()
            tap("playback.interject.button")
            XCTAssertTrue(element("recording.screen").waitForExistence(timeout: 5), "Recording did not open")
            XCTAssertTrue(element("recording.anchor").label.contains(itemTitle), "Recording is anchored to a different item")
            let duration = element("recording.duration.label")
            XCTAssertTrue(duration.waitForExistence(timeout: 5), "Recording duration is missing")
            waitUntil("Recording clock did not reach ten seconds", timeout: 15) {
                self.seconds(duration.label).map { $0 >= 10 } ?? false
            }
            tap("recording.finish.button")
            assertSourcePlaying()
            let resumed = try sourceSeconds()
            XCTAssertGreaterThanOrEqual(resumed, positionBeforeRecording, "Source jumped backwards after saving")
            XCTAssertLessThan(resumed - positionBeforeRecording, 8, "Source advanced through the recording instead of pausing")
            try assertSourceClockAdvances()
            openTimeline()
            let margin = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline.interjection.")).firstMatch
            XCTAssertTrue(margin.waitForExistence(timeout: 5), "Saved Margin did not appear on the timeline")
            XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline.interjection.")).count, 1,
                           "Recording produced duplicate Margins")
            savedMarginID = margin.identifier
            returnToPlayback()
        }

        try XCTContext.runActivity(named: "J3 step 2: Listen another minute, open the saved Margin and play to completion") { _ in
            let start = try sourceSeconds()
            waitUntil("Podcast did not keep advancing for another minute", timeout: 80) {
                (try? self.sourceSeconds()).map { $0 >= start + 60 } ?? false
            }
            assertSourcePlaying()
            positionBeforeMarginPlayback = try sourceSeconds()
            openTimeline()
            tap(savedMarginID)
            playMarginToCompletion()
        }

        try XCTContext.runActivity(named: "J3 step 3: Return to the source and confirm playback continues where we left it") { _ in
            tap("marginDetail.done.button")
            returnToPlayback()
            let paused = try sourceSeconds()
            XCTAssertLessThan(abs(paused - positionBeforeMarginPlayback), 8, "Margin playback lost the source position")
            let control = app.buttons["playback.play.button"]
            if control.label == "Play" { tap("playback.play.button") }
            assertSourcePlaying()
            try assertSourceClockAdvances()
            // Pause before force-quitting so reopening can find the same unfinished session.
            tap("playback.play.button")
            waitUntil("Podcast did not pause before relaunch") { control.label == "Play" }
        }

        XCTContext.runActivity(named: "J3 step 4: Force-quit, reopen without resetting and play the same saved Margin") { _ in
            app.terminate()
            // Rebuild the app/model/players while keeping the first launch's
            // database and files. Transcription stays unavailable for synthetic audio.
            app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_PRESERVE_LIBRARY"] = "1"
            app.launch()
            XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8), "Library did not reopen")
            tap("queue.start.\(itemID)")
            assertSourcePlaying()
            openTimeline()
            tap(savedMarginID)
            playMarginToCompletion()
        }
    }

    private func playMarginToCompletion() {
        XCTAssertTrue(element("marginDetail.screen").waitForExistence(timeout: 5), "Margin detail did not open")
        let play = app.buttons["marginDetail.playRecording.button"]
        XCTAssertTrue(play.waitForExistence(timeout: 5), "Saved recording is unavailable")
        XCTAssertTrue(play.isEnabled, "Saved Margin cannot be played")
        tap("marginDetail.playRecording.button")
        waitUntil("Margin never entered its playing state") { play.label == "Stop playing" }
        // An immediate failure can also reset this button. Require sustained
        // playing, then natural completion, with no visible audio failure.
        let stoppedEarly = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in play.label != "Stop playing" }, object: nil
        )
        stoppedEarly.isInverted = true
        XCTAssertEqual(XCTWaiter().wait(for: [stoppedEarly], timeout: 5), .completed,
                       "Margin stopped before its short recording could finish")
        waitUntil("Margin never completed playback", timeout: 20) { play.label == "Play Margin" }
        XCTAssertFalse(app.buttons["app.feedback.dismiss"].exists, "Margin playback left a visible error")
    }

    private func assertSourcePlaying() {
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8), "Now Playing did not open")
        XCTAssertEqual(app.buttons["playback.itemTitle.button"].label, itemTitle, "A different source is playing")
        let control = app.buttons["playback.play.button"]
        waitUntil("Podcast did not enter the playing state", timeout: 10) { control.exists && control.isEnabled && control.label == "Pause" }
    }

    private func assertSourceClockAdvances() throws {
        let start = try sourceSeconds()
        waitUntil("Podcast clock is stuck", timeout: 8) { (try? self.sourceSeconds()).map { $0 > start } ?? false }
    }

    private func sourceSeconds() throws -> Int {
        let progress = element("playback.progress.label")
        XCTAssertTrue(progress.waitForExistence(timeout: 5), "Podcast clock is missing")
        return try XCTUnwrap(seconds(progress.label), "Podcast clock is not a media time: \(progress.label)")
    }

    private func seconds(_ label: String) -> Int? {
        guard let clock = label.split(separator: " ").last else { return nil }
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 || parts.count == 3 else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    private func openTimeline() {
        if element("playback.timeline.adjacent").exists { return }
        tap("playback.timeline.button")
        XCTAssertTrue(element("timeline.screen").waitForExistence(timeout: 5), "Timeline did not open")
    }

    private func returnToPlayback() {
        let back = app.buttons["timeline.nowPlaying.button"]
        if back.exists { tap("timeline.nowPlaying.button") }
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 5), "Could not return to Now Playing")
    }

    private func tap(_ identifier: String) {
        let control = app.buttons[identifier].firstMatch
        for _ in 0..<5 where !control.isHittable { app.swipeUp() }
        XCTAssertTrue(control.waitForExistence(timeout: 5), "Missing control: \(identifier)")
        XCTAssertTrue(control.isHittable, "Control is not tappable: \(identifier)")
        control.tap()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 5, condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: timeout), .completed, message)
    }
}
