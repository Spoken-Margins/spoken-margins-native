import XCTest

// J14: a listener who already has history on an episode (heard to the end, marked complete, or never started)
// receives a friend's Margins and can still hear them and find the episode again (docs/journeys.md, J14; #4100).
// The episode is the generated offline podcast (SPOKEN_MARGINS_UI_TEST_PODCAST). The first launch seeds the listener's
// history: SPOKEN_MARGINS_UI_TEST_PODCAST_PLACE puts a saved place on the episode (1490 s of 1500 s: 99%, Continue
// resumes it at its end) and SPOKEN_MARGINS_UI_TEST_PODCAST_COMPLETED marks it complete by hand. The relaunch with
// SPOKEN_MARGINS_UI_TEST_KEEP_LIBRARY and SPOKEN_MARGINS_UI_TEST_COOP imports one Margin from "Sam" five minutes in,
// the way a co-op packet would, so the script does not cover the import path itself (an agent step in J14).
// What the voices sound like stays with the owner. A moving clock or a card on screen does not prove audio.
final class J14ComeBackToAFriendsMarginsJourneyUITests: XCTestCase {
    private var app: XCUIApplication!
    private let episodeTitle = "J14: An episode a friend added to"
    private let itemId = "item-ui-podcast"
    /// Where the imported Margin sits (`UITestingLaunchSeed.coopMarginMediaTimeMs`).
    private let friendMarginAt = 300

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // "all": a completed episode is not in the Library's default "unfinished" view (#3794, J14 step 5 "fails today"),
        // which a script can't settle; this proves the episode is findable once the filter allows it.
        app.launchArguments = ["--ui-testing",
            "-libraryContentTypeFilter", "all", "-libraryListeningStateFilter", "all",
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

    /// Row 1: the listener heard the episode to its end (a saved place at 99%). Continue on the Library row asks
    /// before it drops them at the end past the friend's Margin; hearing it first plays it in place.
    func testSavedPlaceAtTheEndAsksBeforeContinueSkipsTheFriendsMargins() throws {
        seedThenFriendArrives(history: "J14 row 1", placeSeconds: 1_490, completed: false)

        XCTContext.runActivity(named: "J14 row 1, step 4: Continue on the Library row asks about the new Margins") { _ in
            tap("queue.start.\(itemId)")
            let hear = offerButton("newMarginsOffer.review", orLabel: "Hear new Margins first")
            XCTAssertTrue(hear.waitForExistence(timeout: 5), "Continue did not offer the friend's Margin first")
            XCTAssertFalse(element("playback.screen").exists, "Continue skipped past the friend's Margin without asking")
            XCTAssertTrue(offerButton("newMarginsOffer.skip", orLabel: "Listen without them").exists,
                          "The offer has no way to carry on without the Margin")
            hear.tap()
        }

        hearTheMarginThenFindTheEpisode(history: "J14 row 1", hearStep: 3, leaveStep: 5)
    }

    /// Row 1 again, from the item screen: the episode's own screen offers the Margins whatever the listener's place.
    func testSavedPlaceAtTheEndOffersTheFriendsMarginsOnTheItemScreen() throws {
        seedThenFriendArrives(history: "J14 row 1b", placeSeconds: 1_490, completed: false)
        openTheItemAndChooseTheMargins(history: "J14 row 1b")
        hearTheMarginThenFindTheEpisode(history: "J14 row 1b", hearStep: 3, leaveStep: 5)
    }

    /// Row 1, from the item screen's "Play" (owner, 2026-11-12: he expects Play to play the Margins he hasn't heard).
    /// Play must not drop the listener at the end past the friend's Margin: it plays the Margin or asks first. Fails on
    /// `main` until #4125 is fixed (J14 step 2, "fails today"); on probation, so it can't turn an integration run red.
    func testItemScreenPlayDoesNotSkipAFriendsMarginsBehindTheSavedPlace() throws {
        seedThenFriendArrives(history: "J14 row 1c", placeSeconds: 1_490, completed: false)

        XCTContext.runActivity(named: "J14 row 1c, step 2: Play on the item screen does not skip the friend's Margin (fails today, #4125)") { _ in
            tap("library.row.\(itemId)")
            XCTAssertTrue(element("item.screen").waitForExistence(timeout: 8), "The item screen did not open")
            let play = app.buttons["item.start.button"].firstMatch
            XCTAssertTrue(play.waitForExistence(timeout: 5), "The big button is missing")
            play.tap()
            waitUntil("Play went past the friend's Margin without playing it or asking; clock shows \(clockText())", timeout: 10) {
                self.app.buttons["newMarginsOffer.review"].firstMatch.exists
                    || self.app.buttons["Hear new Margins first"].firstMatch.exists
                    || self.element("review.comingUp").exists
                    || self.element("review.playing").exists
            }
        }
    }

    /// Row 2: the listener marked the episode complete by hand. It has no saved place, and the Margins are still
    /// offered on its screen.
    func testMarkedCompleteStillOffersTheFriendsMargins() throws {
        seedThenFriendArrives(history: "J14 row 2", placeSeconds: nil, completed: true)
        openTheItemAndChooseTheMargins(history: "J14 row 2")
        hearTheMarginThenFindTheEpisode(history: "J14 row 2", hearStep: 3, leaveStep: 5)
    }

    /// Row 3: the listener never started the episode (J9's item screen, with a step to find the episode after).
    func testNotStartedOffersTheFriendsMargins() throws {
        seedThenFriendArrives(history: "J14 row 3", placeSeconds: nil, completed: false)
        openTheItemAndChooseTheMargins(history: "J14 row 3")
        hearTheMarginThenFindTheEpisode(history: "J14 row 3", hearStep: 3, leaveStep: 5)
    }

    // MARK: - Steps

    /// Steps 1 and 2: the episode is in the Library with the listener's history, then a friend's Margin arrives.
    private func seedThenFriendArrives(history: String, placeSeconds: Int?, completed: Bool) {
        if let placeSeconds { app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_PODCAST_PLACE"] = String(placeSeconds) }
        if completed { app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_PODCAST_COMPLETED"] = "1" }

        XCTContext.runActivity(named: "\(history), setup: The episode is in the Library with the listener's history (offline seed)") { _ in
            app.launch()
            XCTAssertTrue(revealLibraryRow(), "Seeded episode did not appear in the Library")
        }

        XCTContext.runActivity(named: "\(history), setup: Force-quit; a friend's Margin arrives (the import itself is not scripted)") { _ in
            app.terminate()
            app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_KEEP_LIBRARY"] = "1"
            app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_COOP"] = "1"
            app.launch()
            XCTAssertTrue(revealLibraryRow(), "The episode left the Library after the friend's Margin arrived")
        }
    }

    /// Step 3 from the item screen: open the episode, see the two choices, choose the Margins.
    private func openTheItemAndChooseTheMargins(history: String) {
        XCTContext.runActivity(named: "\(history), step 2: Open the episode; it offers the friend's Margins") { _ in
            tap("library.row.\(itemId)")
            XCTAssertTrue(element("item.screen").waitForExistence(timeout: 8), "The item screen did not open")
            let marginsOnly = app.buttons["item.reviewNewMargins.button"].firstMatch
            XCTAssertTrue(marginsOnly.waitForExistence(timeout: 5), "The item screen does not offer the friend's Margins")
            XCTAssertTrue(marginsOnly.label.hasPrefix("Skip to "), "The Margins choice reads \(marginsOnly.label)")
            XCTAssertTrue(app.buttons["item.start.button"].firstMatch.exists, "The big button is missing")
            marginsOnly.tap()
        }
    }

    /// The doc's step 3 (the Margin is where it should be) and step 5 (leave playback, find the episode in the Library).
    /// Row 1's Library-row Continue is the doc's step 4, between them.
    private func hearTheMarginThenFindTheEpisode(history: String, hearStep: Int, leaveStep: Int) {
        XCTContext.runActivity(named: "\(history), step \(hearStep): Choose the Margins; the friend's Margin is next, with a lead-in before it") { _ in
            XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8), "Now Playing did not open")
            XCTAssertEqual(app.buttons["playback.itemTitle.button"].label, episodeTitle, "A different item is playing")
            XCTAssertTrue(element("marginCard").waitForExistence(timeout: 8), "The Margin card did not appear")
            XCTAssertTrue(element("review.comingUp").waitForExistence(timeout: 8), "No lead-in before the friend's Margin")
            // The Margin sits at 5:00; the lead-in starts a short way before it. Past it is the fault: a start at the
            // end of the episode, with the Margin behind.
            waitUntil("The episode did not go to the friend's Margin; clock shows \(clockText())", timeout: 10) {
                self.currentPosition().map { (self.friendMarginAt - 30)...(self.friendMarginAt + 5) ~= $0 } ?? false
            }
            XCTAssertFalse(element("item.lastFailure").exists, "A playback problem was reported")
        }

        XCTContext.runActivity(named: "\(history), step \(leaveStep): Leave playback; the episode can be found in the Library (filter All)") { _ in
            tap("playback.exit.button")
            XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8), "Leaving playback did not reach the Library")
            XCTAssertTrue(revealLibraryRow(), "The episode cannot be found in the Library after leaving playback")
        }
    }

    // MARK: - Helpers

    /// Scrolls the Library until the episode's row exists (#3919): a Live session an earlier test left running keeps its
    /// row at the top and the list builds no row below the first screen.
    private func revealLibraryRow() -> Bool {
        guard element("home.screen").waitForExistence(timeout: 8) else { return false }
        let row = element("library.row.\(itemId)")
        if row.waitForExistence(timeout: 3) { return true }
        for _ in 0..<6 {
            app.swipeUp()
            if row.waitForExistence(timeout: 1) { return true }
        }
        return false
    }

    /// The identifier is what the app sets; some iOS versions drop it from a dialog's buttons, so fall back to its words.
    private func offerButton(_ identifier: String, orLabel label: String) -> XCUIElement {
        let byIdentifier = app.buttons[identifier].firstMatch
        return byIdentifier.waitForExistence(timeout: 5) ? byIdentifier : app.buttons[label].firstMatch
    }

    /// The clock's words for a failure message, which is built before the wait: "no clock" when Now Playing isn't up.
    private func clockText() -> String {
        let label = element("playback.progress.label")
        return label.exists ? label.label : "no clock"
    }

    /// The episode's elapsed-time label in seconds, without waiting, for use inside a predicate.
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
