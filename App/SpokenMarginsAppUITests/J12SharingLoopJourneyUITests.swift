import XCTest

// J12: the sharing loop, as far as one simulator can script it (#3222). The listener records two Margins, sends
// them (the packet's size is read off the package details), and then a friend's packet arrives for the same episode:
// the Margins tab lists it, and "Hear new Margins first" plays it in place.
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

        XCTContext.runActivity(named: "J12 step 3: Send them: the packet is built and its size is shown") { _ in
            beginStep()
            // Tap 1 (#1507): Share on the playback screen opens the sheet on its review, with Share pinned.
            tap("playback.shareMargins.button")
            XCTAssertTrue(element("build23.sender.experience").waitForExistence(timeout: 8), "The Share Margins sheet did not open")
            let cleanUpQuestion = app.alerts["Clean selected Margins automatically?"]
            if cleanUpQuestion.waitForExistence(timeout: 2) { cleanUpQuestion.buttons["Not now"].tap() } // first share only
            XCTAssertTrue(element("build23.sender.stage.review").waitForExistence(timeout: 8), "Share did not open on the review step")
            // Tap 2 is Share here, which opens the iOS share sheet. It has to be on screen without scrolling.
            let share = element("build23.sender.review.share")
            XCTAssertTrue(share.waitForExistence(timeout: 5) && share.isHittable, "Share is not reachable on the review step without scrolling")
            // The package details are built without opening the iOS share sheet, which a script can't dismiss, so
            // this tap stands in for Share and counts as the second.
            tap("build23.sender.preview.build")
            XCTAssertLessThanOrEqual(taps - tapsAtStepStart, 2, "Sharing from the playback screen took more than two taps")
            let size = element("build23.sender.preview.packetSize")
            let builtAt = Date()
            XCTAssertTrue(size.waitForExistence(timeout: 60), "The packet was not built, or its size is not shown")
            note(String(format: "packet built in %.1fs, %@", Date().timeIntervalSince(builtAt), size.label))
            endStep("packet ready (the system share sheet is not scripted)")
            tap("build23.sender.cancel")
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

        XCTContext.runActivity(named: "J12 step 5: The Margins tab lists the friend's Margin") { _ in
            waitUntil("The review card did not go away after the Margin", timeout: 40) { !self.element("review.playing").exists }
            let tab = element("playback.margins.button")
            XCTAssertTrue(tab.waitForExistence(timeout: 8), "The Margins tab button is missing")
            tab.tap() // checking, not listening: not counted
            let friends = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "margins.shared.row.")).firstMatch
            XCTAssertTrue(friends.waitForExistence(timeout: 8), "The friend's Margin is not on the Margins tab")
            let count = element("playback.margins.count")
            XCTAssertTrue(count.waitForExistence(timeout: 5), "The Margins count is missing")
            XCTAssertTrue(count.label.hasPrefix("Margins:") && !count.label.hasSuffix(" 0"), "The Margins tab says none: \(count.label)")
            note("Margins tab: \(count.label)")
        }
    }

    /// #3792: on a friend's item, an answer made after the friend's packet arrived opens the reply sheet on its review,
    /// as a receipt: the reply heading, one row for the Margin going, no editor and no navigator open, Share link one
    /// tap away, and no cleanup question. Two taps from the playback screen, as the ordinary Share (#1507).
    func testAnAnswerOpensTheReplySheetOnItsReceipt() throws {
        XCTContext.runActivity(named: "J12 reply, step 1: The episode is in the Library (offline seed)") { _ in
            app.launch()
            XCTAssertTrue(element("library.row.\(itemId)").waitForExistence(timeout: 8), "Seeded episode did not appear in the Library")
        }

        try XCTContext.runActivity(named: "J12 reply, step 2: A friend's packet arrives (fixture); answer with one Margin") { _ in
            app.terminate()
            app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_KEEP_LIBRARY"] = "1"
            app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_COOP"] = "1"
            app.launch()
            XCTAssertTrue(element("library.row.\(itemId)").waitForExistence(timeout: 8), "Episode is missing after relaunch")
            tap("queue.start.\(itemId)")
            let skip = offerButton("newMarginsOffer.skip", orLabel: "Listen without them")
            XCTAssertTrue(skip.waitForExistence(timeout: 5), "Continue did not offer the friend's Margin")
            skip.tap() // listen on: the answer below is made on the friend's item either way
            XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8), "Now Playing did not open")
            try waitUntilPlaying("Episode never reached the playing state")
            try recordAMargin(seconds: 3)
        }

        XCTContext.runActivity(named: "J12 reply, step 3: Share opens the reply sheet on its receipt") { _ in
            beginStep()
            tap("playback.shareMargins.button") // tap 1
            XCTAssertTrue(element("build23.sender.experience").waitForExistence(timeout: 8), "The Share sheet did not open")
            XCTAssertFalse(app.alerts["Clean selected Margins automatically?"].waitForExistence(timeout: 2),
                           "The cleanup question showed on the reply sheet")
            XCTAssertTrue(element("build23.sender.stage.review").waitForExistence(timeout: 8), "The reply sheet did not open on its review")
            XCTAssertTrue(element("build23.sender.heading").label.hasPrefix("Send replies to"), "The sheet is not the reply sheet: \(element("build23.sender.heading").label)")
            XCTAssertFalse(element("build23.sender.review.navigator").exists, "The reply review drew the Margin navigator")
            let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "build23.sender.review.selector."))
            XCTAssertGreaterThanOrEqual(rows.count, 1, "The receipt should hold a row for the Margin going")
            XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "build23.sender.margin.editor.")).firstMatch.exists,
                           "An editor was open before any row was tapped")
            let share = element("build23.sender.review.share")
            XCTAssertTrue(share.waitForExistence(timeout: 5) && share.isHittable && share.isEnabled,
                          "Share is not reachable on the reply review without scrolling")
            XCTAssertLessThanOrEqual(taps - tapsAtStepStart, 1, "The reply review is more than one tap past Share")
            note("reply sheet open on its receipt after \(taps - tapsAtStepStart) tap(s); the system share sheet is not scripted")
            tap("build23.sender.cancel")
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
        note(String(format: "%6.1fs  %ld taps  %@", Date().timeIntervalSince(startedAt), taps - tapsAtStepStart, what))
    }

    // The attachment reached the hosted evidence only for the failed run (2e2dd48), not for the passing ones (2c6c009,
    // 88b246b), so the numbers were lost. An activity name lands in the xcodebuild log of every run, which the hosted
    // run keeps (#3222).
    private func note(_ line: String) {
        report.append(line)
        XCTContext.runActivity(named: "J12 report: \(line)") { _ in }
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
        let control = element(identifier)
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
