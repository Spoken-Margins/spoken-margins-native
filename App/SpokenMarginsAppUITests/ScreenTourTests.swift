import UIKit
import XCTest

/// Opens each main screen from the seeded launch and attaches one named screenshot per screen, in
/// light and dark appearance, so an unattended integration run can hand the critics the whole app
/// (#381). It only checks that each screen appears; what the screens show may change freely.
/// The sharing loop (#3237) runs on the generated podcast: add, record and share a Margin, open Sam's packet the way a
/// listener's tap does, hear his Margin, then open his reply. Sam's packets are checked-in fixtures with a synthetic voice
/// (`App/TestFixtures/sharing-loop-*.spokenmargins`, plans in `Packages/SessionKitTools/Plans/sharing-loop`).
///
/// Each test also attaches `tour-index-<appearance>-<test>`, a tab-separated line per screenshot with what it shows;
/// `verify-tests.py --plan tour` turns them into `screens/INDEX.md`.
///
/// Export the screenshots from the result bundle with
/// `xcrun xcresulttool export attachments --path <run>.xcresult --output-path <folder>`;
/// `verify-tests.py --plan tour` does that itself and lists them in its manifest.
final class ScreenTourTests: XCTestCase {
    private var app: XCUIApplication!
    private var appearance = "light"
    /// The screenshots this test took, with what each shows, for the run's INDEX.md.
    private var index: [(name: String, shows: String)] = []
    /// Dark captures whose pixels are mostly light, with the share of light pixels (#3838).
    private var lightDarkCaptures: [(name: String, lightShare: Double)] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        // The simulator keeps its appearance between runs; leave it as the other UI tests expect.
        XCUIDevice.shared.appearance = .light
        // Added here so a test that stops halfway still lists what it took.
        if !index.isEmpty {
            let lines = index.map { "\($0.name)\t\($0.shows)" }.joined(separator: "\n") + "\n"
            let attachment = XCTAttachment(data: Data(lines.utf8), uniformTypeIdentifier: "public.plain-text")
            attachment.name = "tour-index-\(appearance)-\(name.split(separator: " ").last?.dropLast() ?? "test")"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testTourInLightAppearance() throws {
        tour(.light, named: "light")
    }

    func testTourInDarkAppearance() throws {
        tour(.dark, named: "dark")
        assertDarkCapturesAreDark()
    }

    func testSharingLoopInLightAppearance() throws {
        try sharingLoop(.light, named: "light")
    }

    func testSharingLoopInDarkAppearance() throws {
        try sharingLoop(.dark, named: "dark")
        assertDarkCapturesAreDark()
    }

    /// #3838: the dark captures of the tabs were light for weeks while the tour reported "light and dark". The check that
    /// stops that has to be able to fail, so this feeds it the cream of the light theme, the near-black of the dark one,
    /// and a dark screen with a bright block, and asks which of them it calls light. It launches nothing.
    func testTheDarkCaptureCheckTellsALightScreenFromADarkOne() throws {
        func image(_ background: UIColor, brightBlockShare: CGFloat = 0) -> CGImage {
            let size = CGSize(width: 390, height: 844)
            return UIGraphicsImageRenderer(size: size).image { context in
                background.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                UIColor.white.setFill()
                context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height * brightBlockShare))
            }.cgImage!
        }
        let cream = RenderedBrightness.lightShare(of: image(UIColor(red: 0.96, green: 0.94, blue: 0.88, alpha: 1)))
        let nearBlack = RenderedBrightness.lightShare(of: image(UIColor(red: 0.07, green: 0.08, blue: 0.08, alpha: 1)))
        let darkWithCard = RenderedBrightness.lightShare(
            of: image(UIColor(red: 0.07, green: 0.08, blue: 0.08, alpha: 1), brightBlockShare: 0.25))
        XCTAssertGreaterThan(cream, RenderedBrightness.mostlyLightShare, "the light theme's cream must read as a light screen")
        XCTAssertLessThan(nearBlack, 0.05, "a dark screen has no light pixels")
        XCTAssertLessThan(darkWithCard, RenderedBrightness.mostlyLightShare,
                          "a dark screen with a bright card on a quarter of it is still a dark screen")
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
            capture("10-live-activity-\(size)", "Live Activity Lock Screen card, paused and playing, at text size \(size)")
        }
    }

    private func tour(_ style: XCUIDevice.Appearance, named name: String) {
        XCUIDevice.shared.appearance = style
        appearance = name
        launch()

        XCTAssertTrue(element("library.screen").waitForExistence(timeout: 10), "Library did not appear")
        capture("01-library", "Library with the seeded article")

        let row = app.buttons["library.row.item-pill"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The seeded item is missing from Library")
        row.tap()
        XCTAssertTrue(element("item.screen").waitForExistence(timeout: 5), "Item did not appear")
        capture("02-item", "Item screen of the seeded article")
        app.buttons["item.home.button"].tap()
        XCTAssertTrue(element("library.screen").waitForExistence(timeout: 5))

        app.buttons["queue.start.item-pill"].tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 10), "The text player did not appear")
        pausePlaybackIfPlaying()
        capture("03-player-text", "Now Playing for an article, paused")

        element("playback.options.button").tap()
        scrollTo("playback.export.button").tap()
        XCTAssertTrue(element("export.screen").waitForExistence(timeout: 5), "Share/Export did not appear")
        capture("04-share-export", "Share/Export from the player's options")
        app.buttons["export.home.button"].tap()
        XCTAssertTrue(element("library.screen").waitForExistence(timeout: 5))

        tapRoot("Margins")
        XCTAssertTrue(element("margins.screen").waitForExistence(timeout: 5), "Margins did not appear")
        capture("05-margins", "Margins tab")

        tapRoot("Following")
        XCTAssertTrue(element("sources.screen").waitForExistence(timeout: 5), "Following did not appear")
        capture("06-following", "Following tab")

        // The first-run drawer opens by itself only on an empty Library; Manage Feeds (Following's plus) opens the same
        // drawer. Browse used to sit on Following itself, and the tour failed there on every run until #3237.
        button("sources.manageFeeds").tap()
        scrollTo("sources.browseCatalog").tap()
        XCTAssertTrue(element("catalog.drawer.done").waitForExistence(timeout: 5), "The first-run drawer did not appear")
        capture("07-first-run-drawer", "Browse podcasts and writers drawer, from Manage Feeds")
        element("catalog.drawer.done").tap()
        XCTAssertTrue(element("sources.screen").waitForExistence(timeout: 5))

        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(element("settings.screen").waitForExistence(timeout: 5), "Settings did not appear")
        capture("08-settings", "Settings")

        openPodcastPlayer()
        capture("09-player-podcast", "Now Playing for a podcast episode added by link")
    }

    /// The sharing loop on the generated 25-minute podcast (#3237), numbered from 11. Screens a listener meets only
    /// sometimes are captured as `-missing` when they don't come, so the set never pretends to show what it doesn't.
    private func sharingLoop(_ style: XCUIDevice.Appearance, named name: String) throws {
        XCUIDevice.shared.appearance = style
        appearance = name
        let podcast = "item-ui-podcast" // UITestingLaunchSeed.podcastItemId
        loopEnvironment = ["SPOKEN_MARGINS_UI_TEST_PODCAST": "1", "SPOKEN_MARGINS_UI_TEST_RECORDING": "1"]
        launch()

        // Adding a podcast: the sheet opens at half height, as the 11-02 storyboard did not draw it.
        XCTAssertTrue(element("library.screen").waitForExistence(timeout: 10), "Library did not appear")
        app.buttons["home.addSource.button"].tap()
        let sheet = element("addSource.sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "The Add sheet did not open")
        capture("11-add-sheet-half", "Library + : the Add sheet as it first opens, at its half-height detent")
        sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04)))
        capture("12-add-sheet-full", "The Add sheet dragged to full height")
        scrollTo("addSource.route.linkOrPodcast").tap()
        XCTAssertTrue(element("sourceLink.url.field").waitForExistence(timeout: 5), "Link or Podcast did not open")
        capture("13-link-form-top", "Link or Podcast form, as it opens")
        app.swipeUp()
        capture("14-link-form-bottom", "Link or Podcast form, scrolled to the bottom")

        // The listener's own Margin at about 20:00, then Share for the item, up to the system share sheet.
        relaunchKeepingLibrary()
        tapButton("queue.start.\(podcast)")
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 10), "Now Playing did not open")
        waitFor(playPause, label: "Pause", "The episode never started playing")
        scrub(to: 0.8)
        tapButton("playback.interject.button")
        XCTAssertTrue(element("recording.screen").waitForExistence(timeout: 5), "Recording did not open")
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "record")], timeout: 4)
        tapButton("recording.finish.button")
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8), "Did not return to Now Playing")
        pausePlaybackIfPlaying()
        // The pane lists this item's Margins; the Share action sits on the Margins tab it links to (#3237, as
        // VoiceOverAuditUITests does). Hosted run 41576228151 looked for it on the pane and never found it.
        tapButton("playback.margins.button")
        tapButton("playback.margins.collection.button")
        let share = element("margins.shareItem.\(podcast)")
        XCTAssertTrue(share.waitForExistence(timeout: 5), "The item's Share action is missing")
        capture("15-share-action", "The Margins tab with the episode's Share action")
        share.tap()
        XCTAssertTrue(element("build23.sender.experience").waitForExistence(timeout: 5), "Share Margins did not open")
        let cleanUp = app.alerts["Clean selected Margins automatically?"]
        if cleanUp.waitForExistence(timeout: 2) {
            capture("16-share-clean-up-question", "First share only: the clean-up question")
            cleanUp.buttons["Not now"].tap()
        }
        XCTAssertTrue(element("build23.sender.select.continue").waitForExistence(timeout: 5), "Choose Margins has no Review")
        capture("17-share-choose", "Share: Choose Margins")
        element("build23.sender.select.continue").tap()
        XCTAssertTrue(element("build23.sender.stage.review").waitForExistence(timeout: 5), "Share's Review did not open")
        capture("18-share-review", "Share: Review, with Share pinned at the bottom")
        element("build23.sender.review.share").tap()
        captureWhenPresent(element("ActivityListView"), timeout: 12, "19-share-system-sheet",
                           "The iOS share sheet with the packet")

        // Sam's packet, opened the way a listener's tap opens it: straight onto the episode, no Import sheet (#3291).
        try relaunchOpening("sharing-loop-sam-margin")
        XCTAssertTrue(element("item.screen").waitForExistence(timeout: 20), "Sam's packet did not open its episode")
        XCTAssertFalse(element("build23.recipient.experience").exists, "a friend's packet opened the Import sheet")
        capture("20-arrival", "Sam's packet: the episode's screen as it opens")
        capture("23-item-top", "The episode's item screen after Sam's packet, top")
        app.swipeUp()
        app.swipeUp()
        capture("24-item-bottom", "The episode's item screen, scrolled to the bottom")
        for _ in 0..<3 { app.swipeDown() }

        // The item offers two choices (#3219): the big Play starts the episode without asking, and "Hear only …"
        // reviews Sam's Margin in place. Hear it on its own first.
        let hearOnly = scrollTo("item.reviewNewMargins.button")
        capture("25-item-two-choices", "The item's two choices: Play, and Hear only Sam's new Margin")
        hearOnly.tap()
        if !element("playback.screen").waitForExistence(timeout: 8) { tapButton("miniPlayer.open.button") }
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8), "Now Playing did not open")
        // The story depends on the review starting, running through and ending, so they fail the tour when they don't
        // happen (#3713). Sam's fixture voice is about 2 s, too short a window for a poll to be sure of catching
        // review.playing, so that capture stays cosmetic; the lead-in card (about 20 s) is what proves the review began,
        // and the reply step below fails unless this Margin was heard, because then it would count two new Margins.
        captureRequired(element("review.comingUp"), timeout: 12, "26-now-review-lead-in",
                        "Now tab during the review's lead-in, the pinned card above the title (#3220)",
                        failure: "The review never started after Hear only Sam's new Margin")
        captureWhenPresent(element("review.playing"), timeout: 40, "27-now-review-sam",
                           "Now tab while Sam's Margin plays in the review, the pinned card above the title (#3220)")
        XCTAssertTrue(waitForDisappearance(element("review.comingUp"), timeout: 40), "The review's lead-in never ended")
        XCTAssertTrue(waitForDisappearance(element("review.playing"), timeout: 40), "The review card stayed after Sam's Margin")

        // Normal playback just before 5:00, where Sam's Margin sits: the same pinned card, with Next Margin (#3220). The
        // review marked his Margin heard, so the card says it is up next rather than playing it by itself.
        pausePlaybackIfPlaying()
        scrub(to: 0.19)
        if playPause.label == "Play" { playPause.tap() }
        let pinnedCard = element("marginCard")
        captureWhenPresent(pinnedCard, timeout: 30, "28-now-sam-up-next",
                           "Now tab in normal playback before Sam's Margin: the pinned card above the title (#3220)")
        // Next Margin's two presses (#460): the first goes to the lead-in, the second straight to the Margin.
        let nextMargin = button("marginCard.next")
        XCTAssertTrue(nextMargin.waitForExistence(timeout: 5), "The pinned card has no Next Margin in normal playback")
        nextMargin.tap()
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "lead-in")], timeout: 2)
        capture("29-now-next-margin-lead-in", "Now tab after one press of Next Margin: the lead-in to Sam's Margin")
        XCTAssertTrue(nextMargin.waitForExistence(timeout: 5), "Next Margin was gone after its first press, so there was no second press")
        nextMargin.tap()
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "margin")], timeout: 2)
        capture("29-now-next-margin-again", "Now tab after a second press of Next Margin: Sam's Margin itself")
        pausePlaybackIfPlaying()

        // Sam's reply to the listener's Margin comes back.
        try relaunchOpening("sharing-loop-sam-reply", markingListenerMarginShared: true)
        XCTAssertTrue(element("item.screen").waitForExistence(timeout: 20), "Sam's reply did not open its episode")
        XCTAssertFalse(element("build23.recipient.experience").exists, "Sam's reply opened the Import sheet")
        // The reply is the one Margin from Sam that hasn't been heard: the item says so (#3219).
        let replyCount = element("item.friendIntro.count")
        XCTAssertTrue(replyCount.waitForExistence(timeout: 10), "The item doesn't say a new Margin from Sam is waiting")
        XCTAssertTrue(replyCount.label.hasPrefix("1 Margin"), "Sam's reply is not the one new Margin: \(replyCount.label)")
        capture("30-reply-arrival", "Sam's reply: the episode's screen as it opens (\"1 new Margin from Sam\")")
        // The packet opened the item on its own, with no tab bar under it: back to the tabs first.
        tapButton("item.home.button")
        tapRoot("Margins")
        XCTAssertTrue(element("margins.screen").waitForExistence(timeout: 5), "Margins did not appear")
        capture("32-margins-with-reply", "Margins tab after Sam's reply")
        openItem(podcast)
        capture("33-item-with-reply-top", "The episode's item screen after Sam's reply, top")
        app.swipeUp()
        app.swipeUp()
        capture("34-item-with-reply-bottom", "The episode's item screen after Sam's reply, bottom")
    }

    /// Launch values the sharing loop keeps across its relaunches.
    private var loopEnvironment: [String: String] = [:]

    private func relaunchKeepingLibrary(_ extra: [String: String] = [:], opensOnLibrary: Bool = true) {
        app.terminate()
        app.launchEnvironment = [:]
        for (key, value) in loopEnvironment.merging(extra, uniquingKeysWith: { $1 }) { app.launchEnvironment[key] = value }
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_KEEP_LIBRARY"] = "1"
        launch()
        guard opensOnLibrary else { return }
        XCTAssertTrue(element("library.screen").waitForExistence(timeout: 10), "Library did not reopen")
    }

    /// Relaunches with a fixture packet that the app opens through the same entry point as a listener's tap. The bytes
    /// travel in the launch because the app can't read this test bundle. A packet opens straight onto its episode
    /// (#3291), so the Library never shows; the caller waits for the item screen. The desk's tour of
    /// 26f30d4 and hosted run 41974955912 stopped here waiting for the Library.
    private func relaunchOpening(_ fixture: String, markingListenerMarginShared: Bool = false) throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: fixture, withExtension: "spokenmargins"),
                                "\(fixture).spokenmargins is not in the test bundle")
        var extra = ["SPOKEN_MARGINS_UI_TEST_OPEN_PACKET": try Data(contentsOf: url).base64EncodedString(),
                     "SPOKEN_MARGINS_UI_TEST_OPEN_PACKET_NAME": fixture]
        if markingListenerMarginShared { extra["SPOKEN_MARGINS_UI_TEST_LISTENER_SHARED"] = "1" }
        relaunchKeepingLibrary(extra, opensOnLibrary: false)
    }

    private func openItem(_ itemId: String) {
        if !element("item.screen").exists {
            tapRoot("Library")
            let row = app.buttons["library.row.\(itemId)"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 8), "The episode is missing from Library")
            row.tap()
        }
        XCTAssertTrue(element("item.screen").waitForExistence(timeout: 5), "The item screen did not appear")
    }

    /// Captures `screen` when `target` appears in time, else `<screen>-missing`, so a screen that didn't come is named.
    private func captureWhenPresent(_ target: XCUIElement, timeout: TimeInterval, _ screen: String, _ shows: String) {
        if target.waitForExistence(timeout: timeout) {
            capture(screen, shows)
        } else {
            capture("\(screen)-missing", "Expected but did not appear within \(Int(timeout)) s: \(shows)")
        }
    }

    /// Captures `screen` when `target` appears in time; fails the test when it doesn't, for a screen the tour's story needs.
    private func captureRequired(_ target: XCUIElement, timeout: TimeInterval, _ screen: String, _ shows: String, failure: String) {
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "\(failure) (\(screen) did not appear within \(Int(timeout)) s)")
        capture(screen, shows)
    }

    private var playPause: XCUIElement { app.buttons["playback.play.button"].firstMatch }

    private func tapButton(_ identifier: String) {
        let control = app.buttons[identifier].firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 5), "Missing control: \(identifier)")
        control.tap()
    }

    /// Taps the position slider at a fraction of its width, as a listener would.
    private func scrub(to fraction: CGFloat) {
        let scrubber = element("playback.scrubber")
        XCTAssertTrue(scrubber.waitForExistence(timeout: 5), "Episode scrubber is missing")
        scrubber.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: 0.5)).tap()
    }

    private func waitFor(_ target: XCUIElement, label: String, _ message: String) {
        let met = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: target)
        XCTAssertEqual(XCTWaiter().wait(for: [met], timeout: 15), .completed, message)
    }

    private func waitFor(_ target: XCUIElement, enabled: Bool, _ message: String) {
        let met = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == %@", NSNumber(value: enabled)), object: target
        )
        XCTAssertEqual(XCTWaiter().wait(for: [met], timeout: 15), .completed, message)
    }

    private func waitForDisappearance(_ target: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: target)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
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
        if app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_KEEP_LIBRARY"] == nil {
            for (key, value) in loopEnvironment { app.launchEnvironment[key] = value }
        }
        app.launch()
    }

    /// Attaches a screenshot named `tour-<appearance>-<screen>` and lists it with what it `shows`.
    private func capture(_ screen: String, _ shows: String) {
        // Let the navigation transition finish so the screenshot shows the screen, not the push.
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "settle")], timeout: 0.8)
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "tour-\(appearance)-\(screen)"
        attachment.lifetime = .keepAlways
        add(attachment)
        index.append((attachment.name ?? screen, shows))
        // A `-missing` capture is a screen that did not come; it shows whatever is behind it, which another capture samples.
        if appearance == "dark", !screen.hasSuffix("-missing"), let pixels = screenshot.image.cgImage {
            let share = RenderedBrightness.lightShare(of: pixels)
            if share > RenderedBrightness.mostlyLightShare { lightDarkCaptures.append((attachment.name ?? screen, share)) }
        }
    }

    /// Fails the dark tour when a capture that claims to be dark rendered light (#3838). It runs after the whole tour,
    /// so every screen is still captured and the failure names all of them. If the tabs really ignore dark mode, that is
    /// an app bug for its own issue; if the simulator did not apply the appearance, it is this test's.
    private func assertDarkCapturesAreDark() {
        let named = lightDarkCaptures.map { "\($0.name) (\(Int($0.lightShare * 100))% light)" }.joined(separator: ", ")
        XCTAssertTrue(lightDarkCaptures.isEmpty,
                      "Dark captures that rendered mostly light, so they do not show dark mode: \(named)")
    }

    /// SwiftUI can put one identifier on a wrapper (`Other`) and the `Button` inside it, so the bare query matches
    /// two nodes: a tap fails with "Multiple matching elements" and an `exists AND enabled` wait never passes (#3237).
    /// `.firstMatch` takes the outermost node, the one that is present as soon as the screen is.
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// The `Button` node itself, for taps and for waits on whether it is enabled (the wrapper does not carry that).
    private func button(_ identifier: String) -> XCUIElement {
        app.buttons[identifier].firstMatch
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

/// How light a rendered screen is, read from its pixels, so a capture can be told apart from the appearance that was asked
/// for (#3838).
private enum RenderedBrightness {
    /// A capture with more than this share of light pixels is a light screen. A dark screen with a bright card or image
    /// stays well under it; the light theme's cream is about 0.95.
    static let mostlyLightShare = 0.5

    /// The share of the image's pixels, averaged down to a 24 by 48 grid, whose luma is above 0.6.
    static func lightShare(of image: CGImage) -> Double {
        let width = 24
        let height = 48
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        // A context that cannot be made says nothing about the screen; the self-test would catch it failing every time.
        guard drawn else { return 0 }
        var light = 0
        for pixel in 0..<(width * height) {
            let red = Double(bytes[pixel * 4]) / 255
            let green = Double(bytes[pixel * 4 + 1]) / 255
            let blue = Double(bytes[pixel * 4 + 2]) / 255
            if 0.2126 * red + 0.7152 * green + 0.0722 * blue > 0.6 { light += 1 }
        }
        return Double(light) / Double(width * height)
    }
}
