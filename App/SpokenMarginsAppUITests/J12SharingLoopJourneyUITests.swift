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
            flowMapCapture("PlaybackScreen")
            try scrub(to: 0.8)
            waitUntil("Scrub did not land near 20:00; clock shows \(element("playback.progress.label").label)", timeout: 10) {
                self.currentPosition().map { (17 * 60...23 * 60).contains($0) } ?? false
            }
            try recordAMargin(seconds: 3)
            try recordAMargin(seconds: 3)
            endStep("two Margins recorded")
            assertOwnMargins(2) // checking, not listening: step 3 counts its own taps
        }

        XCTContext.runActivity(named: "J12 step 3: Send them: the packet is built and its size is shown") { _ in
            beginStep()
            // Tap 1 (#1507): Share on the playback screen opens the sheet on its review, with Share pinned.
            tap("playback.shareMargins.button")
            XCTAssertTrue(element("build23.sender.experience").waitForExistence(timeout: 8), "The Share Margins sheet did not open")
            let cleanUpQuestion = app.alerts["Remove ums and long pauses?"]
            if cleanUpQuestion.waitForExistence(timeout: 2) { cleanUpQuestion.buttons["Not now"].tap() } // first share only
            // One list for every share that isn't a reply (#4647), with Share pinned.
            XCTAssertTrue(element("build23.sender.stage.list").waitForExistence(timeout: 8), "Share did not open on the Share Margins list")
            flowMapCapture("Build23SenderSharingExperience")
            // Tap 2 is Share here, which opens the iOS share sheet. It has to be on screen without scrolling.
            let share = element("build23.sender.review.share")
            XCTAssertTrue(share.waitForExistence(timeout: 5) && share.isHittable, "Share is not reachable on the review step without scrolling")
            // The package details are built without opening the iOS share sheet, which a script can't dismiss, so
            // this tap stands in for Share and counts as the second. The pinned share buttons cover it at rest (#5008).
            tapClearOfPinnedShare("build23.sender.preview.build")
            XCTAssertLessThanOrEqual(taps - tapsAtStepStart, 2, "Sharing from the playback screen took more than two taps")
            XCTAssertTrue(element("build23.sender.stage.recipient-preview").waitForExistence(timeout: 10), "The recipient preview did not open")
            // The size sits below the fold, so this waits on its existence, not on it being on screen. Its identifier
            // is on both the icon and the text of a Label, so read the text, which names the packet and its size.
            let size = app.staticTexts.matching(identifier: "build23.sender.preview.packetSize").firstMatch
            let builtAt = Date()
            XCTAssertTrue(size.waitForExistence(timeout: 60), "The packet was not built, or its size is not shown")
            XCTAssertTrue(size.label.contains(".spokenmargins"), "The packet size line does not name the packet: \(size.label)")
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
            flowMapCapture("ExperienceLibraryScreen", "new-margins-offer")
            endStep("offer shown")
            beginStep()
            hear.tap()
            taps += 1
            XCTAssertTrue(element("review.playing").waitForExistence(timeout: 40), "The friend's Margin never started playing")
            flowMapCapture("PlaybackScreen", "friend-margin")
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
            // This episode was never started, so Continue plays from the beginning and reaches the friend's Margin on
            // its own: `PlayRule` asks only about Margins behind a saved place (`PlayRuleTests`, "not open, a row with no
            // session"; J14 row 3). The offer belongs to an episode with a place past the Margin, which step 4 of the
            // other test covers, so here it is taken if it shows and is not required (#4253).
            let skip = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "newMarginsOffer.skip", "Listen without them")).firstMatch
            let nowPlaying = element("playback.screen")
            waitUntil("Continue neither offered the friend's Margin nor opened Now Playing", timeout: 10) { skip.exists || nowPlaying.exists }
            if skip.exists { skip.tap() } // listen on: the answer below is made on the friend's item either way
            XCTAssertTrue(nowPlaying.waitForExistence(timeout: 8), "Now Playing did not open")
            try waitUntilPlaying("Episode never reached the playing state")
            try recordAMargin(seconds: 3)
        }

        XCTContext.runActivity(named: "J12 reply, step 3: Share opens the reply sheet on its receipt") { _ in
            beginStep()
            tap("playback.shareMargins.button") // tap 1
            XCTAssertTrue(element("build23.sender.experience").waitForExistence(timeout: 8), "The Share sheet did not open")
            XCTAssertFalse(app.alerts["Remove ums and long pauses?"].waitForExistence(timeout: 2),
                           "The cleanup question showed on the reply sheet")
            XCTAssertTrue(element("build23.sender.stage.review").waitForExistence(timeout: 8), "The reply sheet did not open on its review")
            flowMapCapture("Build23SenderSharingExperience", "reply")
            let heading = element("build23.sender.heading").label // "Share replies with <friend>", or "Share your Margins with <friend>" when none is linked as a reply (#3906)
            XCTAssertTrue(heading.hasPrefix("Share replies with") || heading.hasPrefix("Share your Margins with"), "The sheet is not the reply sheet: \(element("build23.sender.heading").label)")
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

    /// #4688: the item screen's Share, as `main` has it (#4517). One Margin recorded on the episode, then from the item
    /// screen: the header's Share opens the Share Margins sheet on its review in two taps; the ⋯ menu lists Share Margins
    /// above Export; and Export opens the Export screen, never the friend sheet. The player's Share is step 3 of the other
    /// test, so this is the route from the Library's row.
    func testTheItemScreenSharesYourMarginsInTwoTaps() throws {
        try XCTContext.runActivity(named: "J12 item, step 1: Listen and record one Margin") { _ in
            app.launch()
            XCTAssertTrue(element("library.row.\(itemId)").waitForExistence(timeout: 8), "Seeded episode did not appear in the Library")
            tap("queue.start.\(itemId)")
            XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8), "Now Playing did not open")
            try waitUntilPlaying("Episode never reached the playing state")
            try recordAMargin(seconds: 3)
            assertOwnMargins(1) // saved before the relaunch below, and counted before step 3 counts its own taps
        }

        XCTContext.runActivity(named: "J12 item, step 2: Reopen the app and open the episode's item screen") { _ in
            app.terminate()
            app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_KEEP_LIBRARY"] = "1"
            app.launch()
            XCTAssertTrue(element("library.row.\(itemId)").waitForExistence(timeout: 8), "Episode is missing from the Library after relaunch")
            tap("library.row.\(itemId)")
            XCTAssertTrue(element("item.screen").waitForExistence(timeout: 8), "The item screen did not open")
            flowMapCapture("ExperienceItemDetailScreen")
        }

        XCTContext.runActivity(named: "J12 item, step 3: Share in the header opens the review in two taps") { _ in
            // Checked before any tap: the `tap` helper swipes up to four times, which would hide a Share that needs scrolling.
            let share = element("item.share.button")
            XCTAssertTrue(share.waitForExistence(timeout: 5) && share.isHittable, "The item screen's Share is not reachable without scrolling")
            beginStep()
            tap("item.share.button") // tap 1
            XCTAssertTrue(element("build23.sender.experience").waitForExistence(timeout: 8), "The Share Margins sheet did not open")
            let cleanUpQuestion = app.alerts["Remove ums and long pauses?"]
            if cleanUpQuestion.waitForExistence(timeout: 2) { cleanUpQuestion.buttons["Not now"].tap() } // first share only
            XCTAssertTrue(element("build23.sender.stage.list").waitForExistence(timeout: 8), "Share did not open on the Share Margins list")
            let sheetShare = element("build23.sender.review.share")
            XCTAssertTrue(sheetShare.waitForExistence(timeout: 5) && sheetShare.isHittable, "Share is not reachable on the review step without scrolling")
            // As step 3 of the first test: building the package details stands in for Share, the second tap.
            tapClearOfPinnedShare("build23.sender.preview.build") // tap 2
            XCTAssertLessThanOrEqual(taps - tapsAtStepStart, 2, "Sharing from the item screen took more than two taps")
            // A tap that missed fails here, not after the minute's wait for the packet below.
            XCTAssertTrue(element("build23.sender.stage.recipient-preview").waitForExistence(timeout: 10), "The recipient preview did not open")
            XCTAssertTrue(app.staticTexts.matching(identifier: "build23.sender.preview.packetSize").firstMatch.waitForExistence(timeout: 60),
                          "The packet was not built, or its size is not shown")
            endStep("item screen to the packet details (the system share sheet is not scripted)")
            tap("build23.sender.cancel")
            waitUntil("The Share Margins sheet did not close on Cancel") { !self.element("build23.sender.experience").exists }
            XCTAssertTrue(element("item.screen").waitForExistence(timeout: 8), "Cancel did not return to the item screen")
        }

        XCTContext.runActivity(named: "J12 item, step 4: The menu lists Share Margins above Export; Export opens the Export screen") { _ in
            // The menu has no identifier, and its label follows the item's noun ("Episode options", "PDF options").
            let options = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", " options")).firstMatch
            XCTAssertTrue(options.waitForExistence(timeout: 5), "The item screen's options menu is missing")
            options.tap()
            let menuShare = element("item.menu.share.button")
            let export = app.buttons["Export"].firstMatch
            XCTAssertTrue(menuShare.waitForExistence(timeout: 5), "The menu has no Share Margins row")
            XCTAssertTrue(export.waitForExistence(timeout: 5), "The menu has no Export row")
            XCTAssertLessThan(menuShare.frame.minY, export.frame.minY, "Share Margins is not above Export in the menu")
            export.tap()
            XCTAssertTrue(element("export.format.picker").waitForExistence(timeout: 8), "Export did not open the Export screen")
            XCTAssertFalse(element("build23.sender.experience").exists, "Export opened the friend sheet")
        }

        // #5306: one tap from Export to Share and one tap back, for the same episode.
        XCTContext.runActivity(named: "J12 item, step 5: Share on the Export screen opens the Share Margins sheet in one tap") { _ in
            let exportShare = element("export.friendShare.button")
            XCTAssertTrue(exportShare.waitForExistence(timeout: 5) && exportShare.isHittable, "The Export screen has no Share button on screen")
            beginStep()
            exportShare.tap(); taps += 1
            XCTAssertTrue(element("build23.sender.experience").waitForExistence(timeout: 8), "Share on the Export screen did not open the Share Margins sheet")
            XCTAssertEqual(taps - tapsAtStepStart, 1, "Export to Share took more than one tap")
            endStep("Export screen to the Share Margins sheet")
        }

        XCTContext.runActivity(named: "J12 item, step 6: Export on the Share Margins sheet goes back to Export for the same episode") { _ in
            let cleanUpQuestion = app.alerts["Remove ums and long pauses?"]
            if cleanUpQuestion.waitForExistence(timeout: 2) { cleanUpQuestion.buttons["Not now"].tap() }
            let sheetExport = element("build23.sender.export")
            XCTAssertTrue(sheetExport.waitForExistence(timeout: 5) && sheetExport.isHittable, "The Share Margins sheet has no Export button on screen")
            beginStep()
            sheetExport.tap(); taps += 1
            waitUntil("The Share Margins sheet did not close on Export", timeout: 8) { !self.element("build23.sender.experience").exists }
            XCTAssertTrue(element("export.format.picker").waitForExistence(timeout: 8), "Export on the Share Margins sheet did not open the Export screen")
            XCTAssertTrue(app.staticTexts[episodeTitle].firstMatch.exists, "The Export screen is not on the episode Share was for")
            XCTAssertEqual(taps - tapsAtStepStart, 1, "Share to Export took more than one tap")
            endStep("Share Margins sheet back to the Export screen")
        }

        // Steps 5 and 6 leave the Export screen under the sheet, so they pass even if the sheet's Export only closed it.
        // Here the sheet opens from the item screen, so only the sheet's Export can bring up the Export screen.
        XCTContext.runActivity(named: "J12 item, step 7: Export on a sheet opened from the item screen opens the Export screen") { _ in
            tap("export.item.button")
            XCTAssertTrue(element("item.screen").waitForExistence(timeout: 8), "Details on the Export screen did not open the item screen")
            tap("item.share.button")
            XCTAssertTrue(element("build23.sender.experience").waitForExistence(timeout: 8), "The Share Margins sheet did not open")
            let cleanUpQuestion = app.alerts["Remove ums and long pauses?"]
            if cleanUpQuestion.waitForExistence(timeout: 2) { cleanUpQuestion.buttons["Not now"].tap() }
            let sheetExport = element("build23.sender.export")
            XCTAssertTrue(sheetExport.waitForExistence(timeout: 5) && sheetExport.isHittable, "The Share Margins sheet has no Export button on screen")
            sheetExport.tap(); taps += 1
            waitUntil("The Share Margins sheet did not close on Export", timeout: 8) { !self.element("build23.sender.experience").exists }
            XCTAssertTrue(element("export.screen").waitForExistence(timeout: 8), "Export on the sheet did not open the Export screen")
            XCTAssertFalse(element("item.screen").exists, "Export on the sheet left the item screen showing")
        }
    }

    /// #4688: with only a friend's Margins on the item, Share says why instead of opening a sheet with nothing to send.
    /// The launch seed holds none of the listener's own Margins; the co-op relaunch imports one from "Sam".
    func testTheItemScreenSaysWhyWithOnlyAFriendsMargins() throws {
        XCTContext.runActivity(named: "J12 friend-only, step 1: The episode is in the Library (offline seed)") { _ in
            app.launch()
            XCTAssertTrue(element("library.row.\(itemId)").waitForExistence(timeout: 8), "Seeded episode did not appear in the Library")
        }

        XCTContext.runActivity(named: "J12 friend-only, step 2: A friend's packet arrives (fixture); open the item") { _ in
            app.terminate()
            app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_KEEP_LIBRARY"] = "1"
            app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_COOP"] = "1"
            app.launch()
            XCTAssertTrue(element("library.row.\(itemId)").waitForExistence(timeout: 8), "Episode is missing from the Library after relaunch")
            tap("library.row.\(itemId)")
            XCTAssertTrue(element("item.screen").waitForExistence(timeout: 8), "The item screen did not open")
        }

        XCTContext.runActivity(named: "J12 friend-only, step 3: Share says why, and OK returns to the item") { _ in
            tap("item.share.button")
            let alert = app.alerts["Nothing to share yet"]
            XCTAssertTrue(alert.waitForExistence(timeout: 8), "Share with only a friend's Margins did not explain itself")
            // A UI test can't import SessionKit, so the words are typed here: the first sentence of
            // `ItemShareStart.onlyFriendMarginsMessage`.
            let words = "Share sends your own Margins, not the ones a friend sent you."
            let said = alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch
            XCTAssertTrue(said.exists, "The alert does not say that Share sends your own Margins: \(alert.staticTexts.allElementsBoundByIndex.map(\.label))")
            XCTAssertFalse(element("build23.sender.experience").exists, "A Share sheet opened with nothing of the listener's own to send")
            alert.buttons["OK"].tap()
            waitUntil("The alert did not close on OK") { !alert.exists }
            XCTAssertTrue(element("item.screen").waitForExistence(timeout: 8), "OK did not leave the listener on the item screen")
        }
    }

    /// #3788: the number the Design asks for. The time from the item screen's first frame, on a friend's arrival, to the
    /// first Margin's audio starting after one tap on "Skip to …" made as soon as the button shows (about 10 s is the
    /// goal; the PR that reads this reports the number and files a speed issue when it is over). It is attached and
    /// logged, never asserted: a slower build is a finding for the desk, not a failed test (see the top of this file).
    /// The friend's packet is the launch fixture, so the episode is already in the Library: this is the arrival path
    /// with placement and download out of the way. Opening a packet from Files with the episode absent can't be scripted
    /// (it needs the Files app), so that case stays with the agent run (docs/journeys.md, J12 step 4).
    func testFriendArrivalToFirstMarginSeconds() throws {
        XCTContext.runActivity(named: "J12 arrival, step 1: The episode is in the Library (offline seed)") { _ in
            app.launch()
            XCTAssertTrue(element("library.row.\(itemId)").waitForExistence(timeout: 8), "Seeded episode did not appear in the Library")
        }

        XCTContext.runActivity(named: "J12 arrival, step 2: Force-quit; a friend's Margin arrives; open the item and skip to it") { _ in
            app.terminate()
            app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_KEEP_LIBRARY"] = "1"
            app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_COOP"] = "1"
            app.launch()
            XCTAssertTrue(element("library.row.\(itemId)").waitForExistence(timeout: 8), "Episode is missing from the Library after relaunch")
            tap("library.row.\(itemId)")
            let opened = Date()
            XCTAssertTrue(element("item.screen").waitForExistence(timeout: 8), "The item screen did not open")
            let skip = app.buttons["item.reviewNewMargins.button"].firstMatch
            XCTAssertTrue(skip.waitForExistence(timeout: 30), "The item screen never offered \"Skip to …\"")
            flowMapCapture("ExperienceItemDetailScreen", "friend-arrival")
            let skipShownAt = Date().timeIntervalSince(opened)
            note(String(format: "item screen to \"Skip to …\" shown: %.1fs", skipShownAt))
            // The intro first, never "Mark complete" or a placement status, on the first frame the choice shows (#3788).
            XCTAssertTrue(element("item.friendIntro.sender").exists, "The item doesn't say who sent the Margins")
            for words in ["Mark complete", "Placing in your copy", "Matching positions in your episode"] {
                let shown = NSPredicate(format: "label CONTAINS[c] %@", words)
                XCTAssertEqual(app.descendants(matching: .any).matching(shown).count, 0, "\"\(words)\" shows on arrival")
            }
            skip.tap()
            taps += 1
            XCTAssertTrue(element("review.playing").waitForExistence(timeout: 60), "The friend's Margin never started playing")
            let seconds = Date().timeIntervalSince(opened)
            note(String(format: "item screen to the friend's Margin playing: %.1fs (%@ the 10 s goal); %d taps from the Library",
                        seconds, seconds <= 10 ? "within" : "over", taps))
            XCTAssertFalse(element("item.lastFailure").exists, "A playback problem was reported")
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

    /// The Margins tab, on Mine, lists exactly `expected` of the listener's own Margins, by its count and by its rows
    /// (#4315: the step that recorded two never counted them). Back to Now afterwards, where Share is.
    private func assertOwnMargins(_ expected: Int) {
        tap("playback.margins.button")
        tap("playback.margins.filter.mine")
        let count = element("playback.margins.count")
        XCTAssertTrue(count.waitForExistence(timeout: 5), "The Margins count is missing")
        waitUntil("The Margins tab does not count \(expected) of your Margins") { count.label == "Margins: \(expected)" }
        XCTAssertEqual(count.label, "Margins: \(expected)", "The Margins tab miscounts your Margins")
        let ownRows = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND NOT (identifier ENDSWITH %@)", "margins.row.", ".play"
        ))
        XCTAssertEqual(ownRows.count, expected, "The Margins tab lists \(ownRows.count) of your Margins, not \(expected)")
        note("Margins tab after recording: \(count.label)")
        tap("playback.now.button")
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

    /// Taps a control the pinned bar under the Share Margins list can cover. `isHittable` doesn't see that overlap, so
    /// the centre tap lands on a share button, which opens the iOS share sheet (#5008), or on a line above them, which
    /// does nothing (#4688). Scrolls from mid-screen until the control's bottom is above the top of the whole bar, then
    /// taps it. The bar is the step line, the count, the link's status lines and the share buttons, top to bottom
    /// (`Build23SenderSharingExperience`'s `safeAreaInset`); a line added there needs its identifier here.
    private func tapClearOfPinnedShare(_ identifier: String) {
        let control = element(identifier)
        XCTAssertTrue(control.waitForExistence(timeout: 8), "Missing control: \(identifier)")
        let pinned = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier IN %@ OR identifier BEGINSWITH %@",
            ["build23.sender.review.placementStep", "build23.sender.bar.count", "build23.sender.review.share"],
            "build23.sender.share.link."
        ))
        func clear() -> Bool {
            let barTop = pinned.allElementsBoundByIndex.filter { $0.exists && !$0.frame.isEmpty }.map { $0.frame.minY }.min()
            return barTop.map { control.frame.maxY <= $0 } ?? true
        }
        for _ in 0..<6 where !clear() {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            from.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
        }
        guard clear() else {
            XCTFail("\(identifier) stays under the pinned bar after 6 swipes (its frame \(control.frame))")
            return
        }
        XCTAssertTrue(control.isHittable, "Control can't be tapped: \(identifier)")
        control.tap()
        taps += 1
    }

    /// A screenshot for Design/flow-map (#5280), named for the map's screen id. `scripts/flow-map-captures.py`
    /// copies these from a cut's journey attachments onto the map, with the commit the run was taken at.
    private func flowMapCapture(_ screenID: String, _ variant: String? = nil) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "flowmap-" + screenID + (variant.map { "--" + $0 } ?? "")
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) {
        let met = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [met], timeout: timeout), .completed, message)
    }
}
