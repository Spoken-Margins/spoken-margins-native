import XCTest

// J12: the sharing loop, as far as one simulator can script it (#3222). The listener records two Margins, sends
// them (the packet's size is read off the ready screen), and then a friend's packet arrives for the same episode:
// the Margins tab lists it without a relaunch of the screen, and "Hear new Margins first" plays it in place.
// The two-device hand-off is a fixture: the relaunch with SPOKEN_MARGINS_UI_TEST_KEEP_LIBRARY and
// SPOKEN_MARGINS_UI_TEST_COOP imports one Margin from "Sam", the way J9 does. Adding the podcast by search needs the
// network, and replying then importing the replies back needs a second install, so those steps, the system share
// sheet, and everything audible stay with the agent run and the owner (docs/journeys.md, J12).
// The numbers a human-factors read wants (taps per step, seconds, packet size) go in an attachment, not in
// assertions: a slower build is a finding for the desk to read, not a failed test.
final class J12SharingLoopJourneyUITests: XCTestCase {
    private var app: XCUIApplication!
    private let episodeTitle = "J12: An episode shared back and forth"
    private let itemId = "item-ui-podcast"
    private var taps = 0
    private var tapsAtStepStart = 0
    private var startedAt = Date()
    private var report: [String] = []

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
        let attachment = XCTAttachment(string: report.joined(separator: "\n"))
        attachment.name = "J12 sharing loop"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
        app = nil
    }

    func testRecordTwoMarginsSendThemAndHearAFriendsMargin() throws {
        XCTContext.runActivity(named: "J12 step 1: The episode is in the Library (offline seed)") { _ in
            startedAt = Date()
            app.launch()
            XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8), "Library did not open")
            XCTAssertTrue(element("library.row.\(itemId)").waitForExistence(timeout: 5),
                          "Seeded episode did not appear in the Library")
        }

        try XCTContext.runActivity(named: "J12 step 2: Listen to about 20:00 and record two Margins") { _ in
            beginStep()
            tap("queue.start.\(itemId)")
            XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8), "Now Playing did not open")
            try waitUntilPlaying("Episode never reached the playing state")
            try scrub(to: 0.8)
            waitUntil("Scrub did not land near 20:00; clock shows \(element("playback.progress.label").label)", timeout: 10) {
                self.currentPosition().map { (17 * 60...23 * 60).contains($0) } ?? false
            }
            try recordAMargin(seconds: 3)
            try recordAMargin(seconds: 3)
            endStep("two Margins recorded")
        }

        XCTContext.runActivity(named: "J12 step 3: Send them: the packet is made and its size is shown") { _ in
            beginStep()
            tap("playback.share.button")
            tap("sharing.send.button")
            let size = element("sharing.packetSize")
            let madeAt = Date()
            XCTAssertTrue(size.waitForExistence(timeout: 60), "The packet was not made, or its size is not shown")
            report.append(String(format: "packet made in %.1fs, %@", Date().timeIntervalSince(madeAt), size.label))
            endStep("packet ready")
            // The system share sheet is not scripted: the file is ready, which is where the sender hands it on.
            tap("sharing.done.button")
            XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8), "Did not return to Now Playing")
            XCTAssertTrue(playPause.waitForExistence(timeout: 5), "Playback control is missing")
            if playPause.label == "Pause" { playPause.tap() }
            waitUntil("Episode did not reach the paused state") { self.playPause.label == "Play" }
        }

        XCTContext.runActivity(named: "J12 step 4: A friend's packet arrives (fixture); Continue offers it first") { _ in
            beginStep()
            app.terminate()
            app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_KEEP_LIBRARY"] = "1"
            app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_COOP"] = "1"
            app.launch()
            XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8), "Library did not reopen")
            XCTAssertTrue(element("library.row.\(itemId)").waitForExistence(timeout: 5),
                          "Episode is missing from the Library after relaunch")
            tap("queue.start.\(itemId)")
            let hear = offerButton("newMarginsOffer.review", orLabel: "Hear new Margins first")
            XCTAssertTrue(hear.waitForExistence(timeout: 5), "Continue did not offer the friend's Margin first")
            endStep("offer shown")
            beginStep()
            hear.tap()
            taps += 1
            XCTAssertTrue(element("review.playing").waitForExistence(timeout: 40), "The friend's Margin never started playing")
            endStep("friend's Margin playing (import to first audio is this step plus the one before it)")
            XCTAssertFalse(element("item.lastFailure").exists, "A playback problem was reported")
        }

        XCTContext.runActivity(named: "J12 step 5: The Margins tab lists the friend's Margin without a relaunch (#3263)") { _ in
            waitUntil("The review card did not go away after the Margin", timeout: 40) { !self.element("review.progress").exists }
            let tab = element("playback.margins.button")
            XCTAssertTrue(tab.waitForExistence(timeout: 8), "The Margins tab button is missing")
            tab.tap() // checking, not listening: not counted
            let friends = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "margins.shared.row.")).firstMatch
            XCTAssertTrue(friends.waitForExistence(timeout: 8), "The friend's Margin is not on the Margins tab")
            let count = element("playback.margins.count")
            XCTAssertTrue(count.waitForExistence(timeout: 5), "The Margins count is missing")
            XCTAssertNotEqual(count.label, "Margins: 0", "The Margins tab says none")
            report.append("Margins tab: \(count.label)")
        }
    }

    // MARK: Steps

    private func recordAMargin(seconds minimum: Int) throws {
        tap("playback.interject.button")
        XCTAssertTrue(element("recording.screen").waitForExistence(timeout: 5), "Recording did not open")
        let duration = element("recording.duration.label")
        XCTAssertTrue(duration.waitForExistence(timeout: 5), "Recording clock is missing")
        waitUntil("Recording clock did not reach \(minimum) s", timeout: 15) { self.seconds(duration.label).map { $0 >= minimum } ?? false }
        tap("recording.finish.button")
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8), "Did not return to Now Playing")
        XCTAssertTrue(playPause.waitForExistence(timeout: 5), "Playback control is missing")
    }

    private func beginStep() { tapsAtStepStart = taps }

    private func endStep(_ what: String) {
        report.append(String(format: "%6.1fs  %d taps  %@", Date().timeIntervalSince(startedAt), taps - tapsAtStepStart, what))
    }

    // MARK: Helpers (the same as J9's)

    private var playPause: XCUIElement { app.buttons["playback.play.button"] }

    private func offerButton(_ identifier: String, orLabel label: String) -> XCUIElement {
        let byIdentifier = app.buttons[identifier].firstMatch
        return byIdentifier.waitForExistence(timeout: 5) ? byIdentifier : app.buttons[label].firstMatch
    }

    private func waitUntilPlaying(_ message: String) throws {
        XCTAssertTrue(playPause.waitForExistence(timeout: 5), "Playback control is missing")
        waitUntil(message, timeout: 10) { self.playPause.isEnabled && self.playPause.label == "Pause" }
    }

    private func scrub(to fraction: CGFloat) throws {
        let scrubber = element("playback.scrubber")
        XCTAssertTrue(scrubber.waitForExistence(timeout: 5), "Episode scrubber is missing")
        XCTAssertTrue(scrubber.isEnabled, "Episode scrubber is disabled")
        scrubber.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: 0.5)).tap()
        taps += 1
    }

    private func currentPosition() -> Int? {
        let label = element("playback.progress.label")
        return label.exists ? seconds(label.label) : nil
    }

    private func seconds(_ label: String) -> Int? {
        guard let clock = label.split(separator: " ").last else { return nil }
        let parts = clock.split(separator: ":").map { Int($0) }
        guard parts.count == 2 || parts.count == 3, !parts.contains(nil) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }

    private func tap(_ identifier: String) {
        let control = app.buttons[identifier].firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 8), "Missing control: \(identifier)")
        for _ in 0..<4 where !control.isHittable { app.swipeUp() }
        XCTAssertTrue(control.isHittable, "Control can't be tapped: \(identifier)")
        control.tap()
        taps += 1
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) {
        let met = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [met], timeout: timeout), .completed, message)
    }
}
