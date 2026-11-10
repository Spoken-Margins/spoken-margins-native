import XCTest
import UIKit

final class Gate1FlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing",
            "-libraryContentTypeFilter", "all", "-libraryListeningStateFilter", "unfinished",
            "-libraryOfflineStateFilter", "all", "-librarySort", "recently_added",
            "-libraryUnfinishedDefaultApplied", "YES"]
        app.launchEnvironment["SPOKEN_MARGINS_UI_TESTING"] = "1"
        launchAllowingOneStall()
    }

    /// #3479 (and #2806), widened by #3097: a launch on a fresh simulator sometimes stalls for 130 to 200 seconds and
    /// fails with "Timed out while launching application via Xcode", "Simulator device failed to launch ... No such
    /// process" or "does not have a process ID". #3479 saw it on the first launch of a run. The first-attempt failure
    /// of the AX5 editor journey on 8356f56 (hosted run 42017300552) was the same stall on the relaunch inside the
    /// test: setUp launched in 19 s, `terminate()` and `launch()` with the AX5 size then hung for 130 s and failed with
    /// "does not have a process ID" at line 656, and xcodebuild's retry passed. The launch is the flake, not the code
    /// under test, so each test may have one launch, setUp's or an in-test relaunch, fail in those three ways; that
    /// launch is then tried again as a real launch. Any other failure, a second stalled launch in the same test, and a
    /// failure of the retried launch still fail the test. Use this for every launch in this class.
    private var stalledLaunchStillAllowed = true

    private func launchAllowingOneStall() {
        guard stalledLaunchStillAllowed else { return app.launch() }
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        var stalled = false
        options.issueMatcher = { issue in
            let isStall = ["Timed out while launching", "Failed to launch", "Failed to get launch progress", "does not have a process ID"]
                .contains { issue.compactDescription.contains($0) }
            if isStall { stalled = true }
            return isStall
        }
        let keepGoing = continueAfterFailure
        continueAfterFailure = true
        XCTExpectFailure("A launch can stall on a hosted simulator (#3479, #3097)", options: options) {
            app.launch()
        }
        continueAfterFailure = keepGoing
        // The allowance is spent when a stall was seen, whatever state the app ended in.
        if stalled { stalledLaunchStillAllowed = false }
        if stalled || app.state != .runningForeground { app.launch() }
    }

    func testListeningEditionPreviewShowsSuppliedScenesBeforeImport() throws {
        openLibrarySettings()
        scrollToButton(containingLabel: "Import Listening Edition").tap()
        let editor = app.textViews["Listening edition JSON"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText(#"{"schemaVersion":"spoken-margins.listening-edition.v1","title":"Portable test article","text":"A short source.","generator":"Fixture author","overview":"An overview","scenes":[{"title":"A scene","description":"Orientation text","summary":"Summary text","startBlock":1,"endBlock":1}]}"#)
        scrollToButton(containingLabel: "Preview").tap()
        let keyboardDismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter().wait(for: [keyboardDismissed], timeout: 3), .completed)
        XCTAssertTrue(app.staticTexts["Portable test article"].waitForExistence(timeout: 5))
        // The Import button is pinned to the bottom of the screen, so it is hittable without scrolling (#1472).
        let importButton = app.buttons["listeningEdition.import"]
        XCTAssertTrue(importButton.isHittable)
        XCTAssertEqual(importButton.label, "Import 1 edition")
        captureScreen(named: "listening-edition-preview")
    }

    /// #2063: a failed import answers next to the Import button, with no scrolling.
    func testListeningEditionImportErrorShowsBesideTheImportButton() throws {
        openLibrarySettings()
        scrollToButton(containingLabel: "Import Listening Edition").tap()
        let editor = app.textViews["Listening edition JSON"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("not json at all")
        let importButton = app.buttons["listeningEdition.import"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
        importButton.tap()
        let result = element("listeningEdition.result")
        XCTAssertTrue(result.waitForExistence(timeout: 5), "The import's answer must show without scrolling")
        XCTAssertTrue(result.isHittable)
        XCTAssertLessThanOrEqual(result.frame.maxY, importButton.frame.minY + 1, "The answer sits just above the Import button")
        captureScreen(named: "listening-edition-import-error")
    }

    func testLongTimelineResponseKeepsActionAboveEditorAndStartsPlayback() throws {
        app.buttons["queue.start.item-pill"].tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8))
        pausePlaybackIfNeeded()
        openTimelineExperience()
        let editor = scrollToElement("timeline.reflection.editor")
        editor.tap()
        app.typeText(String(repeating: "This is a substantial response with a useful argument. ", count: 25))
        app.buttons["timeline.keyboard.done"].tap()
        let action = scrollToElement("timeline.reflection.import.button")
        XCTAssertTrue(action.isHittable)
        XCTAssertLessThan(editor.frame.height, 320, "Response length must not expand the editor")
        XCTAssertLessThanOrEqual(action.frame.maxY, editor.frame.minY)
        captureScreen(named: "long-response-action-and-editor")
        action.tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8))
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Pause"), object: app.buttons["playback.play.button"])
        XCTAssertEqual(XCTWaiter().wait(for: [playing], timeout: 15), .completed)
    }

    func testPlaybackScrubberAcceptsPhysicalDrag() throws {
        app.terminate()
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_TEXT"] = String(repeating: "A long source passage lets us seek forward and backward while playback continues. ", count: 115)
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SUPERTONIC"] = "1"
        launchAllowingOneStall()
        openLibrarySettings()
        scrollToButton(containingLabel: "Developer tools").tap()
        let record = scrollToElement("settings.developer.recordDiagnostics")
        record.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(record.value as? String, "1", "Diagnostic recording must be enabled")
        tapRoot("Library")
        let start = app.buttons["queue.start.item-ui-text-regression"]
        XCTAssertTrue(start.waitForExistence(timeout: 8))
        start.tap()
        let slider = app.sliders["playback.scrubber"]
        XCTAssertTrue(slider.waitForExistence(timeout: 8), app.debugDescription)
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Pause"), object: app.buttons["playback.play.button"])
        XCTAssertEqual(XCTWaiter().wait(for: [playing], timeout: 60), .completed)
        func percent() -> Double {
            Double((slider.value as? String ?? "").components(separatedBy: " ").first ?? "") ?? -1
        }
        func positionCoordinate(_ fraction: Double) -> XCUICoordinate {
            let inset = slider.frame.height / 2
            let x = inset + (slider.frame.width - 2 * inset) * fraction
            return slider.coordinate(withNormalizedOffset: CGVector(dx: x / slider.frame.width, dy: 0.5))
        }
        for target in [0.70, 0.22, 0.85] {
            let from = positionCoordinate(percent() / 100)
            let to = positionCoordinate(target)
            from.press(forDuration: 0.2, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.2)
            let expected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                abs(percent() - target * 100) < 5
            }, object: nil)
            XCTAssertEqual(XCTWaiter().wait(for: [expected], timeout: 5), .completed,
                           "Actual drag to \(target) ended at \(String(describing: slider.value))")
            let landed = percent()
            let advances = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                percent() >= landed + 1 && percent() < landed + 8
            }, object: nil)
            XCTAssertEqual(XCTWaiter().wait(for: [advances], timeout: 25), .completed,
                           "Position stopped following playback after release at \(landed)%")
            captureScreen(named: "scrub-\(target)")
        }
        pausePlaybackIfNeeded()
        positionCoordinate(percent() / 100)
            .press(forDuration: 0.05, thenDragTo: positionCoordinate(0.4), withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertLessThan(abs(percent() - 40), 5, "Quick paused drag lost its destination")
        XCTAssertEqual(app.buttons["playback.play.button"].label, "Play", "Paused seek unexpectedly started playback")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.45))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.45)))
        XCTAssertTrue(element("library.screen").waitForExistence(timeout: 5), "Edge back stopped working")
    }

    func testSeededGate1FlowHasPlaybackMiniPlayerExportAndSettings() throws {
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8))
        XCTAssertTrue(element("library.screen").exists)

        let seededStart = app.buttons["queue.start.item-pill"]
        XCTAssertTrue(seededStart.waitForExistence(timeout: 4), app.debugDescription)
        seededStart.tap()

        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8))
        XCTAssertTrue(scrollToElement("playback.timeline.button").exists)
        openTimelineExperience()
        XCTAssertTrue(element("timeline.rail").exists)
        XCTAssertTrue(scrollToButton(containingLabel: "Chapter").exists)
        XCTAssertTrue(scrollToButton(containingLabel: "Assistant response").exists)
        returnToNowPlayingFromTimelineIfNeeded()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8))

        app.buttons["playback.forward.button"].tap()
        app.buttons["playback.back.button"].tap()

        openPlaybackExport()
        XCTAssertTrue(element("export.screen").waitForExistence(timeout: 4))
        XCTAssertTrue(element("export.preview").waitForExistence(timeout: 4))

        app.buttons["export.home.button"].tap()
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 4))
        XCTAssertTrue(element("miniPlayer.bar").waitForExistence(timeout: 4))
        XCTAssertTrue(element("miniPlayer.close.button").exists)
        XCTAssertTrue(element("miniPlayer.interject.button").exists)
        XCTAssertTrue(element("miniPlayer.playPause.button").exists)
        let hero = element("library.row.item-pill")
        XCTAssertTrue(hero.waitForExistence(timeout: 4), app.debugDescription)
        app.swipeUp()
        XCTAssertLessThanOrEqual(hero.frame.maxY, element("miniPlayer.bar").frame.minY,
                                 "The single Continue Listening card must scroll clear of the mini-player")
        openLibrarySettings()

        XCTAssertTrue(element("settings.screen").waitForExistence(timeout: 4))
        scrollToButton(containingLabel: "About & Legal").tap()
        XCTAssertTrue(scrollToElement("settings.ai.processing").exists)
        XCTAssertTrue(scrollToElement("settings.ai.releaseBoundary").exists)
        XCTAssertFalse(element("provider.name").exists)
        XCTAssertFalse(element("provider.apiKey.field").exists)
    }

    /// #1938: at AX5 the Margins item heading keeps its width, with Share and Share as Markdown on a row below,
    /// and the scope row's count sits under the scope menu.
    func testMarginsHeadingAndScopeRowStackAtAccessibilitySizes() throws {
        app.terminate()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue]
        launchAllowingOneStall()
        scrollToElement("queue.start.item-pill").tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8))
        pausePlaybackIfNeeded()
        scrollToElement("playback.write.button").tap()
        let editor = app.textViews["writtenMargin.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 4))
        editor.tap()
        editor.typeText("A thought to find again.")
        element("writtenMargin.save.button").tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 5))
        openRootMarginsFromPlayback()
        let open = element("margins.openItem.item-pill")
        let share = element("margins.shareItem.item-pill")
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        XCTAssertTrue(share.exists)
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(share.frame.minY, open.frame.maxY - 1, "Share still sits beside the item title")
        XCTAssertGreaterThanOrEqual(share.frame.height + 0.001, 44)
        XCTAssertLessThanOrEqual(share.frame.maxX, window.maxX + 1)
        XCTAssertGreaterThan(open.frame.width, window.width * 0.6, "The item title is squeezed beside the buttons")
        captureScreen(named: "margins-heading-accessibility")
    }

    /// #1935: at AX5 the banner gives its message the full width and puts Undo on its own row, 44 pt tall.
    func testFeedbackBannerPutsItsButtonsOnTheirOwnRowAtAccessibilitySizes() throws {
        app.terminate()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue]
        launchAllowingOneStall()
        // At AX5 the seeded row can sit below the fold, so scroll to it before the long press (#2717).
        XCTAssertTrue(app.buttons["library.row.item-pill"].waitForExistence(timeout: 8))
        let row = scrollToButtonIdentified("library.row.item-pill")
        row.press(forDuration: 0.8)
        app.buttons["Mark Complete"].tap()
        let undo = element("completion.undo.button")
        XCTAssertTrue(undo.waitForExistence(timeout: 4))
        let banner = element("app.feedback.banner")
        XCTAssertTrue(banner.exists)
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(undo.frame.minY, banner.frame.maxY - 1, "Undo still sits beside the message")
        XCTAssertGreaterThanOrEqual(undo.frame.height + 0.001, 44, "Undo is under 44 pt")
        XCTAssertLessThanOrEqual(undo.frame.maxX, window.maxX + 1, "Undo runs off the right edge")
        XCTAssertGreaterThan(banner.frame.width, window.width * 0.6, "The message is squeezed beside the buttons")
        captureScreen(named: "feedback-banner-accessibility")
    }

    func testLibraryUnfinishedCompletionUndoAndSearchDiscovery() throws {
        app.terminate()
        launchAllowingOneStall()
        let row = app.buttons["library.row.item-pill"]
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Completed hidden"].exists)
        let search = app.textFields["library.search.field"]
        XCTAssertTrue(search.waitForExistence(timeout: 4))
        let searchTop = search.frame.minY
        row.press(forDuration: 0.8)
        app.buttons["Mark Complete"].tap()
        // #1149: the completion banner is the app's shared one and floats over the list.
        XCTAssertTrue(element("completion.undo.button").waitForExistence(timeout: 4))
        XCTAssertTrue(element("app.feedback.banner").exists)
        XCTAssertEqual(search.frame.minY, searchTop, accuracy: 1, "The banner must not push the Library down")
        XCTAssertFalse(row.exists)
        element("completion.undo.button").tap()
        XCTAssertTrue(row.waitForExistence(timeout: 4))
        XCTAssertEqual(search.frame.minY, searchTop, accuracy: 1, "Undo must not move the Library")
        row.press(forDuration: 0.8)
        app.buttons["Mark Complete"].tap()
        XCTAssertTrue(element("completion.undo.button").waitForExistence(timeout: 4))
        captureScreen(named: "library-completion-banner")
        // The banner dismisses itself (#123); it also covers the top of the list while it shows.
        XCTAssertTrue(element("app.feedback.banner").waitForNonExistence(timeout: 12))
        XCTAssertEqual(search.frame.minY, searchTop, accuracy: 1, "The Library must not move when the banner goes")
        captureScreen(named: "library-completion-notice-expired")
        search.tap()
        search.typeText("pill")
        XCTAssertFalse(row.exists)
        app.buttons["Include in search"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Everything"].exists)
        captureScreen(named: "library-completed-search-and-undo")
        app.buttons["Clear search"].tap()
        element("library.filters.reset").tap()
        XCTAssertTrue(app.staticTexts["Completed hidden"].exists)
    }

    func testLibraryCompactRowStaysDense() throws {
        XCTAssertTrue(element("library.screen").waitForExistence(timeout: 8))
        let open = app.buttons["library.row.item-pill"]
        let play = app.buttons["queue.start.item-pill"]
        XCTAssertTrue(open.waitForExistence(timeout: 4), app.debugDescription)
        XCTAssertTrue(play.isHittable)
        XCTAssertLessThanOrEqual(open.frame.height, 60, "The compact Library label stack expanded beyond its content")
        XCTAssertLessThanOrEqual(abs(open.frame.midY - play.frame.midY), 8, "The compact Library row controls are vertically misaligned")
        captureScreen(named: "library-compact-row")
    }

    func testDeveloperListeningMapJSONCanBeAppliedFromSettings() throws {
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8))

        let seededItem = app.buttons["library.row.item-pill"]
        XCTAssertTrue(seededItem.waitForExistence(timeout: 4))
        seededItem.tap()
        XCTAssertTrue(element("item.screen").waitForExistence(timeout: 4))
        app.buttons["item.home.button"].tap()
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 4))
        openLibrarySettings()
        XCTAssertTrue(element("settings.screen").waitForExistence(timeout: 4))

        let editor = scrollToElement("settings.developer.mapJSON.editor")
        editor.tap()
        editor.typeText(Self.manualListeningMapJSON)

        let apply = scrollToElement("settings.developer.mapJSON.apply")
        apply.tap()
        // The keyboard covers the tab bar; at the cuts of 275ceea and 6b118db it stayed up after Apply, the Library
        // tab had no hit point and the Library never opened (#3924).
        XCTAssertTrue(waitForDisappearance(app.keyboards.firstMatch, timeout: 4), "Apply left the keyboard over the tab bar")

        tapRoot("Library")
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 4))
        app.buttons["library.row.item-pill"].tap()
        XCTAssertTrue(element("item.screen").waitForExistence(timeout: 4))
        XCTAssertTrue(scrollToElement("chapter.jump.manual-process").exists)
    }

    func testItemScreenShowsListeningActionBeforeAtMostOneMapGenerator() throws {
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8))

        let seededItem = app.buttons["library.row.item-pill"]
        XCTAssertTrue(seededItem.waitForExistence(timeout: 4))
        seededItem.tap()
        XCTAssertTrue(element("item.screen").waitForExistence(timeout: 4))

        let listen = app.buttons["item.start.button"]
        XCTAssertTrue(listen.waitForExistence(timeout: 4))
        XCTAssertTrue(listen.isHittable, "Start or Continue Listening should be available before scrolling.")
        // #149: pinned in the lower third, within thumb reach, and still there after scrolling.
        XCTAssertGreaterThan(listen.frame.midY, app.windows.firstMatch.frame.height * 2 / 3)
        captureScreen(named: "item-listen-pinned-top")
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertTrue(listen.isHittable, "The listening button should stay pinned while the page scrolls.")
        XCTAssertGreaterThan(listen.frame.midY, app.windows.firstMatch.frame.height * 2 / 3)
        captureScreen(named: "item-listen-pinned-scrolled")
        XCTAssertLessThanOrEqual(app.buttons.matching(identifier: "item.generateMap.button").count, 1)
        XCTAssertEqual(app.buttons.matching(identifier: "chapters.generateMap.button").count, 0)
    }

    func testPlaybackPullsIntoTimelineAndReflectionControlsClearTheMiniPlayerAndKeyboard() throws {
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8))
        let seededStart = app.buttons["queue.start.item-pill"]
        XCTAssertTrue(seededStart.waitForExistence(timeout: 4))
        seededStart.tap()

        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8))
        let timelineButton = scrollToElement("playback.timeline.button")
        XCTAssertEqual(timelineButton.label, "Timeline")
        XCTAssertFalse(timelineButton.label.contains("\n"))
        app.buttons["playback.options.button"].tap()
        // Listening options opens at a medium height, so Export can sit below the fold; scroll to it (#2717).
        XCTAssertTrue(scrollToButtonIdentified("playback.export.button").isHittable)
        app.buttons["Done"].tap()

        let playbackScroll = app.scrollViews.firstMatch
        let playbackControls = element("playback.controls")
        XCTAssertTrue(playbackControls.waitForExistence(timeout: 4))
        // The persistent controls are inside the reported scroll-view frame.
        // Pull the actual content, never the transport or scrubber beneath it.
        for _ in 0..<5 {
            if element("timeline.screen").exists { break }
            let origin = playbackScroll.coordinate(withNormalizedOffset: .zero)
            let visibleBottom = playbackControls.frame.minY - playbackScroll.frame.minY
            XCTAssertGreaterThan(visibleBottom, 160)
            let pullStart = origin.withOffset(CGVector(dx: playbackScroll.frame.width * 0.5, dy: visibleBottom - 20))
            let pullEnd = origin.withOffset(CGVector(dx: playbackScroll.frame.width * 0.5, dy: 140))
            pullStart.press(forDuration: 0.1, thenDragTo: pullEnd)
        }
        XCTAssertTrue(element("timeline.screen").waitForExistence(timeout: 4))

        let editor = scrollToElement("timeline.reflection.editor")
        editor.tap()
        app.typeText("Keyboard dismissal probe.")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 4))
        XCTAssertTrue(element("timeline.screen").exists)
        XCTAssertTrue(editor.isHittable, "Focusing the reflection editor blanked or displaced the Timeline content")
        app.buttons["timeline.keyboard.done"].tap()
        XCTAssertTrue(waitForDisappearance(app.keyboards.firstMatch, timeout: 4))
        XCTAssertTrue(editor.isHittable, "Dismissing the keyboard left the Timeline scrolled into an empty region")

        let importButton = scrollToElement("timeline.reflection.import.button")
        XCTAssertTrue(importButton.isHittable, "The floating Now Playing bar covers the import action")
        captureScreen(named: "timeline-reflection-clearance")

        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 4))
        app.buttons["timeline.nowPlaying.button"].tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 4))
        XCTAssertTrue(waitForDisappearance(app.keyboards.firstMatch, timeout: 4))
    }

    func testFailedLocalSummaryShowsPersistentRetryAndRetryCompletes() throws {
        app.terminate()
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_TITLE"] = "Summary Retry Probe"
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_TEXT"] = String(
            repeating: "A bounded source sentence provides context for the listener note. ",
            count: 20
        )
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_URL"] = "https://example.com/summary-retry"
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_INTERJECTION"] = "The app should condense one interjection into its substantive claims instead of lightly cleaning up the transcript."
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_LOCAL_SUMMARY"] = "fail_once"
        launchAllowingOneStall()

        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8))
        let start = app.buttons["queue.start.item-ui-text-regression"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8))

        openTimelineExperience()
        let summarize = scrollToElement("timeline.summary.button")
        XCTAssertTrue(summarize.isEnabled)
        summarize.tap()

        // A failure about the playing listen is the playback screen's one-line tag, not the top banner (#430).
        let failure = element("playback.feedbackTag")
        XCTAssertTrue(failure.waitForExistence(timeout: 8))
        XCTAssertTrue(failure.label.contains("Summary couldn’t finish"))
        XCTAssertTrue(app.buttons["playback.feedbackTag.retry"].isEnabled)
        XCTAssertFalse(element("app.feedback.banner").exists)

        XCTAssertTrue(summarize.waitForExistence(timeout: 4))
        XCTAssertTrue(summarize.label.contains("Retry summary"))
        XCTAssertTrue(summarize.isEnabled)
        summarize.tap()

        XCTAssertTrue(
            scrollToStaticText(containing: "Each interjection should be condensed into its substantive claims instead of receiving a cleaned transcript.")
                .waitForExistence(timeout: 8)
        )
        XCTAssertFalse(element("timeline.summary.button").exists)
    }

    func testPermanentDeleteDoesNotRestoreRecentlyDeletedItem() throws {
        let itemTitle = "Permanent Delete \(UUID().uuidString.prefix(8))"
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8))
        app.buttons["home.addSource.button"].tap()
        scrollToElement("addSource.route.pastedText").tap()
        let title = element("create.title.field")
        XCTAssertTrue(title.waitForExistence(timeout: 4))
        title.tap()
        title.typeText(itemTitle)
        let text = element("create.text.editor")
        text.tap()
        text.typeText("This item exists only to verify permanent deletion.")
        let keyboardDone = app.buttons["Done"].firstMatch
        XCTAssertTrue(keyboardDone.waitForExistence(timeout: 3))
        keyboardDone.tap()
        XCTAssertTrue(waitForDisappearance(app.keyboards.firstMatch, timeout: 4))
        scrollToElement("create.start.button").tap()
        XCTAssertTrue(waitForDisappearance(element("addSource.sheet"), timeout: 8))
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 4))

        // The "Added ... to Library" banner's label holds the title too and comes first, so match Library rows only (#2717).
        let libraryRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "library.row.", itemTitle)).firstMatch
        XCTAssertTrue(libraryRow.waitForExistence(timeout: 4))
        libraryRow.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Move to Recently Deleted"].waitForExistence(timeout: 3))
        app.buttons["Move to Recently Deleted"].tap()
        // Library deletion is recoverable immediately; permanent deletion below requires confirmation.
        XCTAssertTrue(waitForDisappearance(libraryRow, timeout: 4))

        openLibrarySettings()
        // Delete Permanently sits behind the row's menu, away from Restore (#3206).
        scrollToButton(containingLabel: "More options for \(itemTitle)").tap()
        let delete = app.buttons["Delete Permanently"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 2))
        delete.tap()
        let confirmation = app.alerts["Delete Permanently?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 2))
        confirmation.buttons["Delete Permanently"].tap()

        XCTAssertTrue(waitForDisappearance(app.buttons["Restore \(itemTitle)"], timeout: 2))
        XCTAssertFalse(app.staticTexts[itemTitle].exists)

        // Settings is not where a restored item would show up, and a Library row is a button whose label only contains
        // the title, so the checks above could not see one. Look in the Library, then again after a relaunch (#3716).
        tapRoot("Library")
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 4), "The Library did not open")
        XCTAssertFalse(libraryRow.exists, "The permanently deleted item is back in the Library")

        app.terminate()
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_KEEP_LIBRARY"] = "1"
        app.launch()
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8), "The Library did not reopen")
        XCTAssertFalse(libraryRow.waitForExistence(timeout: 3), "The permanently deleted item came back after a relaunch")
    }

    func testAddSourcePresentsEveryTypedIntakeRoute() throws {
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8))
        app.buttons["home.addSource.button"].tap()

        // Every way in is on screen at once, with no scrolling (#3217).
        XCTAssertTrue(element("addSource.sheet").waitForExistence(timeout: 4))
        let screenBottom = app.windows.firstMatch.frame.maxY
        for route in ["linkOrPodcast", "findPodcast", "pastedText", "importFromFiles", "quickFolder", "liveSession", "spokenNote"] {
            let tile = element("addSource.route.\(route)")
            XCTAssertTrue(tile.waitForExistence(timeout: 4), "Missing typed intake route \(route)")
            XCTAssertTrue(tile.isHittable, "\(route) needs scrolling to reach")
            XCTAssertLessThanOrEqual(tile.frame.maxY, screenBottom, "\(route) runs past the bottom of the screen")
        }
        // Documents, books, audiobooks and packets share one Files tile; there is no separate document or audiobook one.
        XCTAssertFalse(element("addSource.route.documentOrBook").exists)
        XCTAssertFalse(element("addSource.route.audiobook").exists)
        element("addSource.route.quickFolder").tap()
        XCTAssertTrue(scrollToElement("quickFolder.choose.button").exists)
    }

    func testAmbiguousPodcastImportImmediatelyReplacesAddSourceWithEpisodePicker() throws {
        app.terminate()
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_AMBIGUOUS_SOURCE_LINK"] = "1"
        launchAllowingOneStall()

        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8))
        app.buttons["home.addSource.button"].tap()
        scrollToElement("addSource.route.linkOrPodcast").tap()
        let link = element("sourceLink.url.field")
        XCTAssertTrue(link.waitForExistence(timeout: 4))
        link.tap()
        link.typeText("https://open.spotify.com/episode/ambiguous-ui-test")
        app.buttons["sourceLink.import.button"].tap()

        XCTAssertTrue(
            element("sourceLink.candidateReview.sheet").waitForExistence(timeout: 4),
            "The episode picker did not replace Add Source when the first import required review."
        )
        XCTAssertTrue(app.buttons["sourceLink.candidate.0"].exists)
        XCTAssertTrue(app.buttons["sourceLink.candidate.1"].exists)

        app.buttons["Cancel"].tap()
        XCTAssertTrue(element("sourceLink.url.field").waitForExistence(timeout: 4))
        app.buttons["Close"].tap()
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 4))

        let seededStart = app.buttons["queue.start.item-pill"]
        XCTAssertTrue(seededStart.waitForExistence(timeout: 4))
        seededStart.tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8))
        app.buttons["playback.home.button"].tap()

        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 4))
        let miniPlayer = element("miniPlayer.bar")
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 4))
        XCTAssertEqual(app.keyboards.count, 0, "The source-link field kept keyboard focus after the picker closed.")

        let window = app.windows.firstMatch
        XCTAssertTrue(window.exists)
        let bottomGap = window.frame.maxY - miniPlayer.frame.maxY
        XCTAssertLessThan(
            bottomGap,
            96,
            "The mini-player remained displaced by a stale keyboard safe-area (bottom gap: \(bottomGap))."
        )
    }

    /// #1436: only the words of the row were tappable. A tap beside them, at the row's right edge,
    /// starts it too.
    func testShareDiagnosticsRowTakesATapBesideTheWords() throws {
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8))
        openLibrarySettings()
        let share = scrollToElement("settings.shareDiagnostics.button")
        XCTAssertGreaterThan(
            share.frame.width, app.windows.firstMatch.frame.width * 0.55,
            "The Share Diagnostics button is only as wide as its words."
        )

        share.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()

        let shareSheet = element("ActivityListView")
        XCTAssertTrue(shareSheet.waitForExistence(timeout: 8), "A tap beside the words did not open the share sheet.")
        dismissTopSystemSheet()
        XCTAssertTrue(waitForDisappearance(shareSheet, timeout: 5))
    }

    func testPrivateExperienceRootsPreserveNowPlayingAndStateConsentBoundaries() throws {
        XCTAssertTrue(element("library.screen").waitForExistence(timeout: 8))
        let seededStart = app.buttons["queue.start.item-pill"]
        XCTAssertTrue(seededStart.waitForExistence(timeout: 4), app.debugDescription)
        seededStart.tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8))
        app.buttons["playback.home.button"].tap()
        XCTAssertTrue(element("miniPlayer.bar").waitForExistence(timeout: 4))
        assertMiniPlayerClearsRootNavigation()

        tapRoot("Following")
        XCTAssertTrue(element("sources.screen").waitForExistence(timeout: 4))
        // Following opens on its entries; the feed field lives on the Follow sheet (#141, #3205).
        XCTAssertFalse(element("sources.follow.url").exists)
        // The identifier appears twice on iOS 26.5 (a wrapper and the Button), so a descendants query finds
        // "multiple matches"; ask for the Button (#2717).
        app.buttons["sources.manageFeeds"].firstMatch.tap()
        XCTAssertTrue(element("sources.follow.url").waitForExistence(timeout: 4))
        XCTAssertTrue(element("sources.follow.paste").exists)
        XCTAssertTrue(element("sources.follow.button").exists)
        XCTAssertTrue(element("sources.browseCatalog").exists)
        // Read Later and Listening Edition imports are in Settings, not on this sheet.
        XCTAssertFalse(app.buttons["Read Later Services"].exists)
        XCTAssertFalse(app.buttons["Import Listening Edition"].exists)
        app.buttons["sources.follow.cancel"].firstMatch.tap()
        XCTAssertTrue(app.buttons["sources.manageFeeds"].firstMatch.waitForExistence(timeout: 4))
        tapRoot("Settings")
        XCTAssertTrue(element("settings.screen").waitForExistence(timeout: 5))
        captureScreen(named: "following-settings-opened")
        tapRoot("Following")
        XCTAssertFalse(app.staticTexts["Follow is not Add"].exists)
        XCTAssertTrue(element("miniPlayer.bar").exists)
        assertMiniPlayerClearsRootNavigation()

        tapRoot("Margins")
        XCTAssertTrue(element("margins.screen").waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Margins"].exists)
        XCTAssertTrue(element("miniPlayer.bar").exists)
        assertMiniPlayerClearsRootNavigation()

        tapRoot("Library")
        XCTAssertTrue(element("library.screen").waitForExistence(timeout: 4))
        XCTAssertTrue(element("miniPlayer.bar").exists)
        assertMiniPlayerClearsRootNavigation()
    }

    func testRecordingExclusivelyOwnsTheAccessibleExperience() throws {
        app.terminate()
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_RECORDING"] = "1"
        launchAllowingOneStall()

        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8))
        let seededStart = app.buttons["queue.start.item-pill"]
        XCTAssertTrue(seededStart.waitForExistence(timeout: 4), app.debugDescription)
        seededStart.tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8))
        scrollToElement("playback.interject.button").tap()

        XCTAssertTrue(element("recording.screen").waitForExistence(timeout: 4))
        XCTAssertTrue(element("recording.anchor").exists)
        XCTAssertTrue(element("recording.finish.button").exists)
        XCTAssertTrue(element("recording.cancel.button").exists)
        XCTAssertFalse(element("playback.screen").exists)
        XCTAssertFalse(element("miniPlayer.bar").exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        XCTAssertFalse(app.buttons["Following"].exists)
        XCTAssertFalse(app.buttons["Margins"].exists)

        let finish = element("recording.finish.button")
        XCTAssertGreaterThan(finish.frame.minY, app.frame.midY, "Save & resume sits in the bottom row, where Add a Margin was (#148)")
        XCTAssertLessThan(element("recording.cancel.button").frame.maxX, finish.frame.minX, "Cancel is the small button to the left of Save")
        // Save ignores taps for 0.5 s after the recording screen appears (#148), so wait past that window.
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "recording save guard window")], timeout: 0.6)
        finish.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8))
        XCTAssertFalse(element("recording.screen").exists, "A second finish tap started another Margin")
        XCTAssertEqual(element("playback.play.button").label, "Pause", "Saving a voice Margin did not resume playback")
        pausePlaybackIfNeeded()
        openRootMarginsFromPlayback()
        XCTAssertTrue(element("margins.screen").waitForExistence(timeout: 4))
        XCTAssertTrue(element("miniPlayer.bar").exists)
        let savedMargin = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "margins.rowDetails.")).firstMatch
        XCTAssertTrue(savedMargin.waitForExistence(timeout: 4))
        savedMargin.tap()
        XCTAssertTrue(element("marginDetail.screen").waitForExistence(timeout: 4), "Tapping the saved Margin row did not open its detail")
        let timelineAction = app.buttons["Open the source"]
        let pinnedMoment = app.buttons["marginDetail.playMoment.button"]
        let detailList = element("marginDetail.screen").collectionViews.firstMatch
        for _ in 0..<5 {
            if timelineAction.isHittable && timelineAction.frame.maxY < pinnedMoment.frame.minY - 12 { break }
            detailList.swipeUp()
        }
        XCTAssertTrue(timelineAction.isHittable)
        XCTAssertLessThan(timelineAction.frame.maxY, pinnedMoment.frame.minY - 12,
                          "The detail action cannot clear its fixed playback control")
        captureScreen(named: "second-edition-margin-detail-timeline-clearance")
        timelineAction.tap()
        XCTAssertTrue(element("item.screen").waitForExistence(timeout: 4), "A Margin must open its owning Item without replacing playback")
        XCTAssertFalse(app.buttons["Open in Timeline"].exists)
        element("miniPlayer.open.button").tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 4))
        element("playback.interject.button").tap()
        XCTAssertTrue(element("recording.screen").waitForExistence(timeout: 4))
        element("recording.cancel.button").tap()
        app.alerts.buttons["Discard recording"].tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8))
        XCTAssertFalse(element("recording.screen").exists)
        XCTAssertEqual(element("playback.play.button").label, "Pause", "Voice capture cancellation did not resume the source")
    }

    /// #1942: at AX5 with the keyboard up, the editor keeps a usable height and sits inside the screen.
    func testWrittenMarginEditorStaysUsableAtAccessibilitySizesWithTheKeyboardUp() throws {
        app.terminate()
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_TITLE"] = "A listener's notebook about the art of paying attention, ordinary streets, familiar voices, and everything we might otherwise forget"
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_TEXT"] = String(repeating: "Notice the small details along the way. ", count: 80)
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue]
        launchAllowingOneStall()
        startSeededLibraryItem()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8))
        pausePlaybackIfNeeded()
        scrollToElement("playback.write.button").tap()
        XCTAssertTrue(element("writtenMargin.screen").waitForExistence(timeout: 4))
        let editor = app.textViews["writtenMargin.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 4))
        editor.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 4))
        XCTAssertGreaterThanOrEqual(editor.frame.height, 100, "The editor was squeezed")
        XCTAssertLessThanOrEqual(editor.frame.maxY, keyboard.frame.minY + 1, "The editor sits under the keyboard")
        XCTAssertGreaterThanOrEqual(editor.frame.minY, app.windows.firstMatch.frame.minY, "The editor was pushed off the top")
        captureScreen(named: "written-margin-accessibility-keyboard")
    }

    /// #3547: on the Live session setup form, Done closes the keyboard, and Start Session is tappable with the
    /// keyboard still up (no scroll first).
    func testLiveSessionSetupDoneClosesTheKeyboardAndStartIsReachableWithItUp() throws {
        app.buttons["home.addSource.button"].tap()
        scrollToElement("addSource.route.liveSession").tap()
        let title = element("liveSession.setup.title")
        XCTAssertTrue(title.waitForExistence(timeout: 6))
        title.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 4))
        let done = element("liveSession.keyboard.done")
        XCTAssertTrue(done.waitForExistence(timeout: 4), "No Done on the setup keyboard")
        done.tap()
        XCTAssertTrue(waitForDisappearance(app.keyboards.firstMatch, timeout: 4), "Done left the keyboard up")
        title.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 4))
        let start = app.buttons["liveSession.start"]
        XCTAssertTrue(start.isHittable, "Start Session is behind the keyboard")
        start.tap()
        XCTAssertTrue(app.buttons["liveSession.addMargin.button"].waitForExistence(timeout: 6), "One tap did not start the session")
    }

    /// #3491: the pencil opens the normal writing sheet with the keyboard up, and Save puts a row on the Margins pane.
    func testLiveSessionPencilOpensTheWritingSheetAndSaveAddsARow() throws {
        startLiveSession()
        app.buttons["liveSession.write.button"].tap()
        let editor = element("writtenMargin.text")
        XCTAssertTrue(editor.waitForExistence(timeout: 6), "The pencil did not open the writing sheet")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 4), "The writing sheet opened with the keyboard down")
        editor.tap()
        editor.typeText("Johnny moved on to the budget.")
        let save = element("writtenMargin.save.keyboard.button")
        XCTAssertTrue(save.waitForExistence(timeout: 4) && save.isHittable, "Save is not reachable with the keyboard up")
        save.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'liveSession.margin.row.'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6), "Save did not add a Margin row")
        XCTAssertTrue(waitForDisappearance(element("writtenMargin.screen"), timeout: 4), "Save left the writing sheet up")
    }

    /// #3491: End is in the dock, so it is hittable without scrolling however many Margins the session has.
    func testLiveSessionEndIsHittableWithoutScrollingAfterManyMargins() throws {
        startLiveSession()
        for index in 0..<8 {
            app.buttons["liveSession.write.button"].tap()
            let editor = element("writtenMargin.text")
            XCTAssertTrue(editor.waitForExistence(timeout: 6))
            editor.tap()
            editor.typeText("Margin number \(index) with enough words to fill about two lines of the row on a phone.")
            element("writtenMargin.save.keyboard.button").tap()
            XCTAssertTrue(waitForDisappearance(element("writtenMargin.screen"), timeout: 4))
        }
        let end = app.buttons["liveSession.endSession"]
        XCTAssertTrue(end.waitForExistence(timeout: 4))
        XCTAssertTrue(end.isHittable, "End is not reachable without scrolling")
        let window = app.windows.firstMatch.frame
        XCTAssertLessThanOrEqual(end.frame.maxY, window.maxY, "End is below the screen")
    }

    /// #2831: the End sheet stays up until its own End or Cancel closes it; nothing on the screen redraws it away.
    func testLiveSessionEndSheetStaysUpForThreeSeconds() throws {
        startLiveSession()
        app.buttons["liveSession.endSession"].tap()
        let confirm = app.buttons["liveSession.confirmEnd"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 6), "End did not open its sheet")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(confirm.exists && app.buttons["liveSession.cancelEnd"].exists, "The End sheet closed by itself")
    }

    private func startLiveSession() {
        app.buttons["home.addSource.button"].tap()
        scrollToElement("addSource.route.liveSession").tap()
        let start = app.buttons["liveSession.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 6))
        start.tap()
        XCTAssertTrue(app.buttons["liveSession.addMargin.button"].waitForExistence(timeout: 6), "The session did not start")
    }

    func testWrittenMarginSaveSearchStarAndDiscardPreserveTheSource() throws {
        app.terminate()
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_TITLE"] = "A walk with room to think"
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_TEXT"] = String(repeating: "Notice the small details along the way. ", count: 80)
        launchAllowingOneStall()
        startSeededLibraryItem()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8))
        pausePlaybackIfNeeded()
        element("playback.write.button").tap()
        XCTAssertTrue(element("writtenMargin.screen").waitForExistence(timeout: 4))
        XCTAssertFalse(element("miniPlayer.bar").exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        XCTAssertFalse(element("writtenMargin.save.button").isEnabled)
        let editor = app.textViews["writtenMargin.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 4))
        editor.tap()
        editor.typeText("Remember the amber doorway.")
        // #1184: a button under the keyboard can still report isHittable, so compare frames.
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 4))
        let save = element("writtenMargin.save.button")
        XCTAssertTrue(save.isHittable, "The keyboard hides Save")
        XCTAssertLessThanOrEqual(save.frame.maxY, keyboard.frame.minY, "Save sits under the keyboard")
        captureScreen(named: "second-edition-written-capture-keyboard")
        element("writtenMargin.save.button").tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 5))
        XCTAssertEqual(element("playback.play.button").label, "Play", "Saving a pre-paused note started playback")
        openRootMarginsFromPlayback()
        let search = app.textFields["margins.search.field"]
        XCTAssertTrue(search.waitForExistence(timeout: 4))
        search.tap()
        search.typeText("amber doorway")
        let note = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "margins.rowDetails.")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 4))
        note.tap()
        XCTAssertTrue(element("marginDetail.screen").waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Remember the amber doorway."].exists)
        XCTAssertFalse(app.buttons["Hear my recording"].exists)
        let more = app.buttons["marginDetail.more.button"]
        XCTAssertTrue(more.waitForExistence(timeout: 3))
        more.tap()
        let copy = app.buttons["marginDetail.copyWithContext.button"]
        XCTAssertTrue(copy.waitForExistence(timeout: 3))
        captureScreen(named: "margin-detail-before-quick-tap")
        // Exercise a short touch; video evidence checks the transient button
        // highlight separately from the completion banner assertion below.
        copy.press(forDuration: 0.05)
        captureScreen(named: "margin-detail-after-quick-tap")
        XCTAssertTrue(element("app.feedback.banner").waitForExistence(timeout: 3), "Copy confirmation must be visible inside the Margin sheet")
        XCTAssertTrue(app.staticTexts["Copied Margin with its context."].exists)
        app.buttons["marginDetail.star.button"].tap()
        XCTAssertEqual(app.buttons["marginDetail.star.button"].label, "Unstar Margin")
        captureScreen(named: "second-edition-written-margin-detail")
        element("marginDetail.playMoment.button").tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["playback.itemTitle.button"].label.contains("A walk with room to think"))
        pausePlaybackIfNeeded()
        element("playback.write.button").tap()
        XCTAssertTrue(element("writtenMargin.screen").waitForExistence(timeout: 4))
        app.textViews["writtenMargin.text"].tap()
        app.textViews["writtenMargin.text"].typeText("Discard this thought")
        app.buttons["writtenMargin.cancel.button"].tap()
        app.alerts.buttons["Keep writing"].tap()
        XCTAssertTrue(element("writtenMargin.screen").exists)
        app.buttons["writtenMargin.cancel.button"].tap()
        app.alerts.buttons["Discard Margin"].tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 5))
        XCTAssertEqual(element("playback.play.button").label, "Play")
    }

    func testPlaybackPrimaryActionsRemainVisibleWithLongTitleAndAccessibilityText() throws {
        app.terminate()
        let longTitle = "A listener's notebook about the art of paying attention, ordinary streets, familiar voices, and everything we might otherwise forget on a long walk home"
        // Ensure ordinary scrolling is possible even in the wider iPad viewport.
        // Bottom overscroll has its own navigation test.
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_TITLE"] = Array(repeating: longTitle, count: 3).joined(separator: ". ")
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_TEXT"] = String(repeating: "A paragraph worth listening to. ", count: 80)
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue]
        launchAllowingOneStall()
        startSeededLibraryItem()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8))
        captureScreen(named: "second-edition-native-accessibility-size")
        XCTAssertFalse(element("playback.sleepTimer.button").exists, "Maximum native Dynamic Type did not activate the accessible control layout")
        let viewport = app.windows.firstMatch.frame
        for id in ["playback.play.button", "playback.interject.button", "playback.options.button"] {
            let control = element(id)
            XCTAssertTrue(control.waitForExistence(timeout: 4), id)
            XCTAssertTrue(control.isHittable, "\(id) requires scrolling past content")
            XCTAssertTrue(viewport.contains(control.frame), "\(id) is clipped outside the viewport")
        }
        captureScreen(named: "second-edition-long-title-accessibility-controls")
        let scroll = app.scrollViews.firstMatch
        let controls = element("playback.controls")
        let titleBeforeScroll = element("playback.title").frame.minY
        let origin = scroll.coordinate(withNormalizedOffset: .zero)
        let startY = controls.frame.minY - scroll.frame.minY - 20
        origin.withOffset(CGVector(dx: scroll.frame.width * 0.5, dy: startY))
            .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: scroll.frame.width * 0.5, dy: startY - 120)))
        XCTAssertLessThan(element("playback.title").frame.minY, titleBeforeScroll - 20,
                          "The content did not scroll independently of the fixed controls")
        XCTAssertTrue(element("playback.interject.button").isHittable, "Scrolling content moved capture away")
        XCTAssertTrue(element("playback.play.button").isHittable, "Scrolling content moved playback away")
    }

    /// #2056: at AX5 a Library row's title has the full width, with the play button on a line below it.
    func testLibraryRowTitleGetsFullWidthAtAccessibilitySizes() throws {
        app.terminate()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue]
        launchAllowingOneStall()
        let play = scrollToElement("queue.start.item-pill")
        XCTAssertTrue(play.isHittable)
        let open = element("library.row.item-pill")
        let viewport = app.windows.firstMatch.frame
        XCTAssertGreaterThan(open.frame.width, viewport.width * 0.8, "The row's title is squeezed beside the icon and the play button")
        XCTAssertGreaterThanOrEqual(play.frame.minY, open.frame.maxY - 1, "The play button sits below the title")
        XCTAssertGreaterThanOrEqual(play.frame.height + 0.001, 44)
        captureScreen(named: "library-row-accessibility-size")
    }

    func testOfflineStorageExplainsProtectionBeforeSafeClear() throws {
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8))
        openLibrarySettings()
        XCTAssertTrue(element("settings.screen").waitForExistence(timeout: 4))

        scrollToElement("settings.offlineStorage.button").tap()

        XCTAssertTrue(element("offlineStorage.screen").waitForExistence(timeout: 4))
        XCTAssertTrue(scrollToElement("offlineStorage.protected.row").exists)
        XCTAssertTrue(scrollToElement("offlineStorage.reproducible.row").exists)
        XCTAssertTrue(scrollToElement("offlineStorage.clearable.row").exists)
        let clear = scrollToElement("offlineStorage.clear.button")
        if clear.isEnabled {
            clear.tap()
            let confirmation = app.alerts["Clear reproducible audio?"]
            XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
            XCTAssertTrue(
                confirmation.staticTexts.matching(
                    NSPredicate(format: "label CONTAINS %@", "recordings, Margins, and protected active playback will remain")
                ).firstMatch.exists
            )
            confirmation.buttons["Cancel"].tap()
        }
    }

    func testBatchExportOffersPersistentJumpToDestination() throws {
        XCTAssertTrue(element("library.screen").waitForExistence(timeout: 8))
        app.buttons["queue.start.item-pill"].tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8))
        app.buttons["playback.home.button"].tap()
        XCTAssertTrue(element("library.screen").waitForExistence(timeout: 4))

        tapRoot("Margins")
        XCTAssertTrue(element("margins.scope.picker").waitForExistence(timeout: 4))
        captureScreen(named: "margins-scoped-workspace")
        let exportSessions = app.buttons["margins.export.button"]
        XCTAssertTrue(exportSessions.waitForExistence(timeout: 2))
        exportSessions.tap()
        XCTAssertTrue(element("batchExport.screen").waitForExistence(timeout: 4))

        let jump = app.buttons["batchExport.jumpToDestination.button"]
        XCTAssertFalse(jump.isEnabled)
        let filter = app.segmentedControls["batchExport.filter.picker"]
        XCTAssertTrue(filter.waitForExistence(timeout: 2))
        filter.buttons["All Sessions"].tap()
        element("batchExport.selectAll.button").tap()

        XCTAssertTrue(jump.isEnabled)
        jump.tap()
        XCTAssertTrue(element("batchExport.export.button").waitForExistence(timeout: 2))
        XCTAssertTrue(element("batchExport.export.button").isHittable)
        XCTAssertFalse(element("batchExport.chooseFolder.button").exists, "Export Sessions has no remembered folder (#1528)")
    }

    /// #1939: at AX5 the Export Sessions pickers become menus that stay inside the screen.
    func testBatchExportPickersBecomeMenusAtAccessibilitySizes() throws {
        app.terminate()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue]
        launchAllowingOneStall()
        scrollToElement("queue.start.item-pill").tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8))
        scrollToElement("playback.home.button").tap()
        XCTAssertTrue(element("library.screen").waitForExistence(timeout: 4))
        tapRoot("Margins")
        let exportSessions = scrollToElement("margins.export.button")
        exportSessions.tap()
        XCTAssertTrue(element("batchExport.screen").waitForExistence(timeout: 4))
        let filter = scrollToElement("batchExport.filter.picker")
        XCTAssertFalse(app.segmentedControls["batchExport.filter.picker"].exists, "Still a segmented control at AX5")
        let window = app.windows.firstMatch.frame
        XCTAssertLessThanOrEqual(filter.frame.maxX, window.maxX + 1)
        XCTAssertGreaterThanOrEqual(filter.frame.height + 0.001, 44)
        captureScreen(named: "batch-export-pickers-accessibility")
    }

    func testBuild23SenderStagesInvalidateStalePreviewAndUseSystemShare() throws {
        launchBuild23SharingFixture()

        XCTAssertTrue(element("build23.sender.stage.select").waitForExistence(timeout: 5))
        openBuild23Review()
        XCTAssertTrue(element("build23.sender.stage.review").waitForExistence(timeout: 5))
        buildBuild23RecipientPreview()
        XCTAssertTrue(element("build23.sender.stage.recipient-preview").waitForExistence(timeout: 8))
        XCTAssertTrue(element("build23.sender.recipient.verified-preview").exists)

        scrollToBuild23SenderElement("build23.sender.preview.edit").tap()
        XCTAssertTrue(element("build23.sender.stage.select").waitForExistence(timeout: 5))
        scrollToButton(containingLabel: "Sharing options").tap()
        let evidenceToggle = app.switches["Include acoustic evidence when available"]
        for _ in 0..<6 where !(evidenceToggle.exists && evidenceToggle.isHittable) {
            app.scrollViews["build23.sender.experience"].swipeUp()
        }
        XCTAssertTrue(evidenceToggle.isHittable)
        let previousEvidenceValue = evidenceToggle.value as? String
        evidenceToggle.tap()
        XCTAssertNotEqual(evidenceToggle.value as? String, previousEvidenceValue)
        XCTAssertFalse(element("build23.sender.recipient.verified-preview").exists)
        XCTAssertFalse(element("build23.sender.share.present").exists)

        openBuild23Review()
        // The primary Share action must build, verify and present in one tap.
        scrollToBuild23SenderElement("build23.sender.review.share").tap()

        XCTAssertTrue(element("build23.sender.stage.share").waitForExistence(timeout: 5))
        let nativeShareSurface = element("ActivityListView")
        XCTAssertTrue(
            nativeShareSurface.waitForExistence(timeout: 8),
            "The verified package did not reach the native system share surface."
        )

        dismissTopSystemSheet()
        XCTAssertTrue(waitForDisappearance(nativeShareSurface, timeout: 5))
        XCTAssertTrue(element("build23.sender.stage.review").waitForExistence(timeout: 8))
        buildBuild23RecipientPreview()
        XCTAssertTrue(element("build23.sender.recipient-test-session").exists)
    }

    func testBuild23RecipientMissingSourceReturnsWithoutAutoplayAndShowsProvenance() throws {
        launchBuild23SharingFixture(forceFirstSourceMiss: true, includeSourceURL: false)
        openBuild23Review()
        buildBuild23RecipientPreview()

        element("build23.sender.recipient-test-session").tap()
        XCTAssertTrue(element("build23.recipient.experience").waitForExistence(timeout: 8))
        XCTAssertTrue(element("build23.recipient.sender").exists)
        XCTAssertTrue(app.staticTexts["Add the source to continue"].exists)

        let addSource = element("build23.recipient.addToLibrary")
        XCTAssertTrue(addSource.waitForExistence(timeout: 4))
        let pinnedImport = app.buttons["Import"].firstMatch
        XCTAssertTrue(pinnedImport.waitForExistence(timeout: 4))
        // Import is the top button of the bar pinned over the content; the bar's divider and padding sit about 24 pt
        // above it. A drag must start on the content above the bar, or it presses the bar and moves nothing (#3952).
        func importBarTop() -> CGFloat { pinnedImport.frame.minY - 24 }
        let window = app.windows.firstMatch
        for _ in 0..<6 where addSource.frame.maxY >= importBarTop() {
            let origin = window.coordinate(withNormalizedOffset: .zero)
            let x = window.frame.width - 24
            let startY = importBarTop() - 24 - window.frame.minY
            let distance = min(addSource.frame.maxY - importBarTop() + 48, startY - 160)
            guard distance > 20 else { break }
            origin.withOffset(CGVector(dx: x, dy: startY))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: x, dy: startY - distance)),
                       withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTAssertLessThan(addSource.frame.maxY, importBarTop(),
                          "Add to Library remains covered by the pinned import actions.")
        addSource.tap()
        XCTAssertTrue(element("addSource.sheet").waitForExistence(timeout: 5))
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(waitForDisappearance(element("addSource.sheet"), timeout: 5))

        let importButton = app.buttons["Import"].firstMatch
        XCTAssertEqual(
            XCTWaiter().wait(
                for: [XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "exists == true AND enabled == true"),
                    object: importButton
                )],
                timeout: 8
            ),
            .completed,
            "Returning from Add Source did not resume the pending verified import."
        )
        importButton.tap()

        XCTAssertTrue(element("item.screen").waitForExistence(timeout: 10))
        XCTAssertFalse(element("playback.screen").exists)
        let miniPlayerControl = element("miniPlayer.playPause.button")
        XCTAssertTrue(miniPlayerControl.waitForExistence(timeout: 5))
        XCTAssertEqual(miniPlayerControl.label, "Play", "Import unexpectedly resumed playback.")

        let provenance = importedLayerElement(suffix: ".provenance")
        XCTAssertTrue(provenance.waitForExistence(timeout: 5))
        XCTAssertTrue(provenance.label.hasPrefix("From "))
        // Every import arrives guided, whatever the sender suggested (owner, 2026-10-31; e563e4135), so the layer's
        // play mode reads "Play as you reach them", not the companion mode's "A tone marks each one".
        XCTAssertTrue(provenance.label.localizedCaseInsensitiveContains("When Margins play: Play as you reach them"),
                      "The imported layer's provenance does not say it plays as you reach it: \(provenance.label)")
        captureScreen(named: "second-edition-item-shared-provenance")

        element("miniPlayer.open.button").tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 5))
        XCTAssertEqual(element("playback.play.button").label, "Play")
        let railTitle = String(provenance.label.prefix(while: { $0 != "." }))
        openTimelineExperience()
        scrollToButton(containingLabel: railTitle).tap()
        let timelineProvenance = importedLayerElement(suffix: ".provenance")
        _ = scrollTo(timelineProvenance)
        XCTAssertTrue(timelineProvenance.waitForExistence(timeout: 5))
    }

    func testBuild23LayoutRegressionsRemainOperableAtAccessibilityType() throws {
        // This multi-screen route took 120s on iOS 26 and exceeded the default
        // allowance on iOS 27; retain its assertions within the plan's 180s cap.
        executionTimeAllowance = 180
        app.terminate()
        app.launchArguments += [
            "-UIPreferredContentSizeCategoryName", UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue,
            "-UIAccessibilityDarkerSystemColorsEnabled", "YES",
            "-UIAccessibilityReduceMotionEnabled", "YES"
        ]
        launchAllowingOneStall()

        XCTAssertTrue(element("library.screen").waitForExistence(timeout: 8))
        let start = scrollTo(app.buttons["queue.start.item-pill"])
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8))
        pausePlaybackIfNeeded()
        app.buttons["playback.home.button"].tap()

        XCTAssertTrue(element("library.screen").waitForExistence(timeout: 5))
        XCTAssertTrue(element("miniPlayer.bar").waitForExistence(timeout: 5))
        assertMiniPlayerClearsRootNavigation()
        XCTAssertLessThan(element("miniPlayer.bar").frame.height, app.windows.firstMatch.frame.height * 0.25,
                          "The persistent player consumes more than a quarter of the reading viewport")
        let search = scrollToElementBidirectionally("library.search.field")
        let filter = element("library.filter.menu")
        XCTAssertTrue(search.isHittable)
        XCTAssertTrue(filter.exists)
        // The filter row sits under the search field, so whatever stands above it (a Live session row left by an
        // earlier test, #3967) can put it behind the mini-player. The claim is that the list lets it clear the bar.
        dragContent(above: element("miniPlayer.bar"), toReveal: filter)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(filter.frame))
        XCTAssertFalse(filter.frame.intersects(element("miniPlayer.bar").frame),
                       "The Library filter stays behind the mini-player however far the list scrolls")
        // iOS 18 reports a visible native Menu as non-hittable. Verify its actual
        // activation and selection instead of trusting that accessibility flag.
        filter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Text"].waitForExistence(timeout: 4))
        app.buttons["Text"].tap()
        XCTAssertTrue(filter.waitForExistence(timeout: 4))
        XCTAssertTrue(filter.label.contains("active filters"))
        // The filtered list is shorter and can settle lower; a tap on the bar would open playback instead.
        dragContent(above: element("miniPlayer.bar"), toReveal: filter)
        XCTAssertFalse(filter.frame.intersects(element("miniPlayer.bar").frame))
        filter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["All"].firstMatch.tap()
        XCTAssertEqual(filter.label, "Filter Library")

        app.buttons["home.addSource.button"].tap()
        scrollToElementBidirectionally("addSource.route.pastedText").tap()
        let editor = element("create.text.editor")
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("Build 23 keeps the final Add Source action above the keyboard and safe area.")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let addToLibrary = app.buttons["create.start.button"]
        XCTAssertTrue(addToLibrary.waitForExistence(timeout: 3))
        let keyboardDone = app.buttons["Done"].firstMatch
        XCTAssertTrue(keyboardDone.exists)
        let keyboardTop = min(app.keyboards.firstMatch.frame.minY, keyboardDone.frame.minY)
        XCTAssertTrue(addToLibrary.isHittable)
        XCTAssertLessThanOrEqual(
            addToLibrary.frame.maxY,
            keyboardTop,
            "The Add Source action is covered by the keyboard or its accessory toolbar."
        )
        XCTAssertTrue(keyboardDone.isHittable)
        XCTAssertLessThanOrEqual(
            keyboardDone.frame.maxY,
            app.keyboards.firstMatch.frame.minY,
            "The keyboard dismissal action must also remain above the keyboard."
        )
        captureScreen(named: "second-edition-add-text-keyboard-accessibility")
        keyboardDone.tap()
        XCTAssertTrue(waitForDisappearance(app.keyboards.firstMatch, timeout: 5))
        app.buttons["Close"].firstMatch.tap()

        element("miniPlayer.open.button").tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 5))
        openTimelineExperience()
        let reflectionAction = app.buttons["timeline.reflection.import.button"]
        XCTAssertTrue(reflectionAction.waitForExistence(timeout: 4))
        captureScreen(named: "second-edition-timeline-accessibility-content")
        let timelineMiniPlayer = element("miniPlayer.bar")
        XCTAssertTrue(timelineMiniPlayer.waitForExistence(timeout: 5))
        let timelineScroll = app.scrollViews.containing(.button, identifier: "timeline.reflection.import.button").firstMatch
        for _ in 0..<16 where reflectionAction.frame.maxY > timelineMiniPlayer.frame.minY {
            let visibleHeight = min(timelineScroll.frame.maxY, timelineMiniPlayer.frame.minY) - timelineScroll.frame.minY
            XCTAssertGreaterThan(visibleHeight, 40)
            let origin = timelineScroll.coordinate(withNormalizedOffset: .zero)
            // Stay inside the visible content, outside the nested editor and
            // the left-edge back gesture. Disabled actions need not be hittable.
            let swipeX = timelineScroll.frame.width - 30
            origin.withOffset(CGVector(dx: swipeX, dy: visibleHeight - 16))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: swipeX, dy: visibleHeight * 0.25)))
        }
        captureScreen(named: "second-edition-timeline-accessibility-clearance")
        XCTAssertLessThanOrEqual(
            reflectionAction.frame.maxY,
            timelineMiniPlayer.frame.minY,
            "Persistent playback obscures Timeline content."
        )
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func importedLayerElement(suffix: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
                "build23.imported.layer.",
                suffix
            ))
            .firstMatch
    }

    private func launchBuild23SharingFixture(
        forceFirstSourceMiss: Bool = false,
        includeSourceURL: Bool = true
    ) {
        app.terminate()
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_TITLE"] = "Build 23 Sharing Probe"
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_TEXT"] = String(
            repeating: "A stable source passage gives the shared Margin exact local context. ",
            count: 24
        )
        if includeSourceURL {
            app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_URL"] = "https://example.com/build-23-sharing-probe"
        } else {
            app.launchEnvironment.removeValue(forKey: "SPOKEN_MARGINS_UI_TEST_SOURCE_URL")
        }
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_INTERJECTION"] = "The recipient should notice the careful distinction between a claim and its evidence."
        if forceFirstSourceMiss {
            app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_FORCE_FIRST_SHARED_SOURCE_MISS"] = "1"
        }
        launchAllowingOneStall()

        XCTAssertTrue(element("library.screen").waitForExistence(timeout: 8))
        let start = app.buttons["queue.start.item-ui-text-regression"]
        XCTAssertTrue(start.waitForExistence(timeout: 5), app.debugDescription)
        start.tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8))
        pausePlaybackIfNeeded()
        // Share lives on the Margins tab (#3211: the Export screen is for taking Margins out for yourself).
        scrollToElement("playback.margins.button").tap()
        scrollToElement("playback.margins.collection.button").tap()
        let share = scrollToElement("margins.shareItem.item-ui-text-regression")
        XCTAssertTrue(share.isHittable, "The item's Share action is not reachable on the Margins tab")
        share.tap()
        XCTAssertTrue(element("build23.sender.experience").waitForExistence(timeout: 8))
    }

    private func openPlaybackExport() {
        element("playback.options.button").tap()
        let export = scrollToElement("playback.export.button")
        XCTAssertTrue(export.isHittable)
        export.tap()
    }

    /// Pauses the source if it is playing and waits for the button to read "Play".
    ///
    /// A tap that lands while the playback screen is still laying out is dropped: the hosted Mac logged "Failed to
    /// compute hit point ... {{inf, inf}, {0.0, 0.0}}" for the first tap, and the label then stayed "Pause" for the
    /// whole wait (#3097). So tap only when the button has a frame, read the label again after each try, and tap
    /// again only while it still says "Pause" (never when it already says "Play", which would start playback again).
    private func pausePlaybackIfNeeded() {
        let playPause = element("playback.play.button")
        XCTAssertTrue(playPause.waitForExistence(timeout: 8))
        _ = XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label == %@ OR label == %@", "Play", "Pause"),
                object: playPause
            )],
            timeout: 20
        )
        var paused = false
        for attempt in 0..<3 where !paused {
            if playPause.label == "Pause", isReadyToTap(playPause) {
                playPause.tap()
            }
            paused = XCTWaiter().wait(
                for: [XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "label == %@", "Play"),
                    object: playPause
                )],
                // The first try waits as long as the old single wait did, so a slow pause is not tapped a second time.
                timeout: attempt == 0 ? 8 : 5
            ) == .completed
        }
        XCTAssertTrue(paused, "Playback did not pause: the play button still reads \(playPause.label)")
    }

    private func openBuild23Review() {
        scrollToBuild23SenderElement("build23.sender.select.continue").tap()
        XCTAssertTrue(element("build23.sender.stage.review").waitForExistence(timeout: 5))
    }

    private func buildBuild23RecipientPreview() {
        let preview = scrollToBuild23SenderElement("build23.sender.preview.build")
        captureScreen(named: "second-edition-sender-preview-action")
        preview.tap()
        XCTAssertTrue(element("build23.sender.recipient.verified-preview").waitForExistence(timeout: 12))
    }

    private func scrollToBuild23SenderElement(_ identifier: String) -> XCUIElement {
        let candidate = element(identifier)
        let senderExperience = element("build23.sender.experience")
        XCTAssertTrue(senderExperience.waitForExistence(timeout: 5), "Build 23 sender experience is missing")
        let recipientFooter = element("build23.sender.recipient-test-session")
        // The bar pinned to the bottom of the sender screen (#3896) holds one or two buttons, depending on the stage
        // and on whether the build makes links. Content scrolls under it, so a drag must start above its topmost button
        // or it presses the bar and moves nothing (#3952). When the target is itself a bar button it is reachable where
        // it sits, so the bar does not shrink the visible area for that lookup.
        let pinnedBarIdentifiers = [
            "build23.sender.select.continue",
            "build23.sender.review.share",
            "build23.sender.review.share.file",
            "build23.sender.preview.share",
            "build23.sender.share.present",
        ]
        let pinnedBarButtons = pinnedBarIdentifiers.contains(identifier) ? [] : pinnedBarIdentifiers.map { element($0) }
        func visibleBottom() -> CGFloat {
            var bottom = min(senderExperience.frame.maxY - 8, app.windows.firstMatch.frame.maxY - 34)
            if recipientFooter.exists { bottom = min(bottom, recipientFooter.frame.minY - 12) }
            // Only a button in the lower half is in the bar: without share links "share.present" is an in-content
            // button near the top of the preview step, which must not count.
            let barFloor = senderExperience.frame.midY
            for button in pinnedBarButtons where button.exists && button.frame.minY > barFloor {
                bottom = min(bottom, button.frame.minY - 12)
            }
            return bottom
        }
        func fullyReachable() -> Bool {
            candidate.exists && candidate.isHittable
                && candidate.frame.minY >= senderExperience.frame.minY + 12
                && candidate.frame.maxY <= visibleBottom()
        }
        for _ in 0..<12 {
            if fullyReachable() { break }
            let origin = senderExperience.coordinate(withNormalizedOffset: .zero)
            let x = senderExperience.frame.width - 24
            let lower = visibleBottom() - senderExperience.frame.minY - 20
            let upper: CGFloat = 80
            XCTAssertGreaterThan(lower, upper)
            let moveDown = candidate.exists && candidate.frame.minY < senderExperience.frame.minY + 12
            origin.withOffset(CGVector(dx: x, dy: moveDown ? upper : lower))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: x, dy: moveDown ? lower : upper)))
        }
        XCTAssertTrue(
            candidate.waitForExistence(timeout: 5) && fullyReachable(),
            "Missing or unreachable Build 23 sender element: \(identifier)"
        )
        return candidate
    }

    private func dismissTopSystemSheet() {
        let close = app.buttons["Close"].firstMatch
        if close.waitForExistence(timeout: 2) {
            close.tap()
            return
        }

        let sheetCount = app.sheets.count
        XCTAssertGreaterThan(sheetCount, 0)
        let sheet = app.sheets.element(boundBy: sheetCount - 1)
        let start = sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
        let end = sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    private func scrollToElementBidirectionally(_ identifier: String) -> XCUIElement {
        scrollTo(element(identifier))
    }

    private func scrollTo(_ candidate: XCUIElement) -> XCUIElement {
        for _ in 0..<12 where !isReadyToTap(candidate) {
            app.swipeDown()
        }
        for _ in 0..<20 where !isReadyToTap(candidate) {
            app.swipeUp()
        }
        XCTAssertTrue(candidate.waitForExistence(timeout: 5), "Missing or unreachable element")
        return candidate
    }

    private func assertMiniPlayerClearsRootNavigation(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let miniPlayer = element("miniPlayer.bar")
        let tabBar = app.tabBars.firstMatch
        if tabBar.exists {
            XCTAssertLessThanOrEqual(
                miniPlayer.frame.maxY,
                tabBar.frame.minY,
                "The mini-player overlaps the Library, Following, Margins, and Settings controls",
                file: file,
                line: line
            )
        } else {
            // iPad's sidebar-adaptable TabView exposes tabs at the top rather
            // than a bottom UITabBar. Verify the actual controls in both axes.
            for identifier in ["navigation.tab.library", "navigation.tab.sources", "navigation.tab.margins", "navigation.tab.settings"] {
                let matches = app.descendants(matching: .any).matching(identifier: identifier).allElementsBoundByIndex
                guard let control = matches.first(where: { $0.isHittable }) else {
                    XCTFail("Root navigation is missing or unreachable: \(identifier)", file: file, line: line)
                    return
                }
                XCTAssertFalse(miniPlayer.frame.intersects(control.frame), "The mini-player overlaps \(identifier)", file: file, line: line)
            }
        }
    }

    private func captureScreen(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The Margins pane inside playback (`playback.margins.button`) lists only this source's Margins and has no search
    /// field, scope row or per-item heading since the playback shell redesign (#1475). Tests that look at the Margins
    /// page, with those parts, leave playback by its Home button and open the Margins root; the mini-player keeps the
    /// source playing. Repaired for #2717.
    private func openRootMarginsFromPlayback() {
        // Home sits in the secondary controls row, which can be below the fold at AX5.
        scrollToButtonIdentified("playback.home.button").tap()
        tapRoot("Margins")
        XCTAssertTrue(element("margins.screen").waitForExistence(timeout: 4), "The Margins root did not open")
    }

    private func openLibrarySettings() {
        tapRoot("Settings")
    }

    private func openTimelineExperience() {
        if element("playback.timeline.adjacent").exists {
            return
        }
        pullPlaybackDockDown(toReveal: app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Timeline")).firstMatch)
        let button = scrollToButton(containingLabel: "Timeline")
        XCTAssertTrue(button.isHittable, "Missing the iPhone Timeline route and iPad adjacent Timeline.")
        button.tap()
        XCTAssertTrue(element("timeline.screen").waitForExistence(timeout: 4))
    }

    /// At accessibility sizes the playback dock scrolls inside a capped height and opens scrolled to its bottom, so the
    /// pane switch at its top (Timeline, Margins, Now) starts out of view (`PlaybackBoundedDock`). Swiping up only moves
    /// it further off, which failed the AX5 layout test at the cut of 72ae8c3 (#3921). This drags the dock's content
    /// down from its right margin beside the transport row, clear of the scrubber and the buttons.
    private func pullPlaybackDockDown(toReveal target: XCUIElement) {
        let play = element("playback.play.button")
        guard play.exists else { return }
        let window = app.windows.firstMatch
        for _ in 0..<4 where !isReadyToTap(target) {
            let origin = window.coordinate(withNormalizedOffset: .zero)
            let x = window.frame.width - 16
            let startY = play.frame.midY - window.frame.minY
            let endY = min(window.frame.height - 20, startY + 240)
            guard endY - startY > 60 else { return }
            origin.withOffset(CGVector(dx: x, dy: startY))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: x, dy: endY)),
                       withVelocity: .slow, thenHoldForDuration: 0.1)
        }
    }

    /// Drags the screen's scroll content up in short, slow steps, starting just above `bar`, until `target` sits wholly
    /// above it. Each step moves only as far as the overlap needs, so the target is not flung past the top.
    private func dragContent(above bar: XCUIElement, toReveal target: XCUIElement) {
        let window = app.windows.firstMatch
        for _ in 0..<6 where target.frame.maxY > bar.frame.minY {
            let origin = window.coordinate(withNormalizedOffset: .zero)
            let x = window.frame.width - 16
            let startY = bar.frame.minY - 24 - window.frame.minY
            let distance = min(target.frame.maxY - bar.frame.minY + 48, startY - 120)
            guard distance > 20 else { return }
            origin.withOffset(CGVector(dx: x, dy: startY))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: x, dy: startY - distance)),
                       withVelocity: .slow, thenHoldForDuration: 0.1)
        }
    }

    private func returnToNowPlayingFromTimelineIfNeeded() {
        // The top-left arrow only returns to Now while the Timeline editor hides the tab switch (#4027); otherwise the
        // Now tab does.
        let button = app.buttons["timeline.nowPlaying.button"]
        if button.exists {
            button.tap()
        } else if element("timeline.screen").exists {
            app.buttons["playback.now.button"].firstMatch.tap()
        } else {
            XCTAssertTrue(element("playback.timeline.adjacent").exists)
        }
    }

    private func tapRoot(_ name: String) {
        let button = app.buttons[name].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 4), "Missing \(name) root control")
        button.tap()
    }

    /// `isHittable` does not answer false for an element with no frame yet, as it does for one off screen: it fails
    /// the test ("Failed to determine hittability ... Activation point invalid"). That failed the first scroll after a
    /// launch at AX5 on the hosted Mac twice in a week (#2760). An element with no usable frame is not ready to tap,
    /// so the scroll loops go on and look again.
    ///
    /// The row can also go away between two reads when the list redraws after a launch: `exists`, then `frame`, are two
    /// lookups, and `frame` fails the test ("Failed to get matching snapshot: No matches found") if the element left in
    /// between (#2922). `snapshot()` is one lookup that throws instead, so a vanished element means "not ready".
    ///
    /// A frame that is valid in one lookup can still have no hit point a moment later while the screen is laying out
    /// (#3097: "Activation point invalid" from `isHittable` on the start button, 88 s into a slow hosted launch). So
    /// the frame must read the same in two lookups before `isHittable` is asked.
    private func isReadyToTap(_ candidate: XCUIElement) -> Bool {
        func usableFrame() -> CGRect? {
            guard let frame = (try? candidate.snapshot())?.frame else { return nil }
            guard !frame.isNull, !frame.isInfinite, !frame.isEmpty else { return nil }
            return frame
        }
        guard let first = usableFrame(), let second = usableFrame(), first == second else { return false }
        return candidate.isHittable
    }

    /// Starts the seeded text item from the Library's everyday view (#3424).
    ///
    /// The launch arguments in `setUpWithError` pin the Library filters, yet one hosted run found this Library on the
    /// "Completed" filter with "No matches", so the Start button was hidden behind a filter and a 60 s hunt for it
    /// failed (frame {inf, inf}). How the filter got there is not proven. A test that is about the editor, the
    /// keyboard or the playback screen should not depend on it, so the helper resets any active filter first and
    /// writes the filter it found into the test log, which will show whether it keeps happening.
    private func startSeededLibraryItem() {
        let libraryScreen = element("library.screen")
        XCTAssertTrue(libraryScreen.waitForExistence(timeout: 20), "The Library did not appear after launch")
        let reset = element("library.filters.reset")
        if reset.exists {
            let found = element("library.filter.summary").label
            XCTContext.runActivity(named: "Library opened on a filter (\(found)); resetting it (#3424)") { _ in
                reset.tap()
            }
        }
        scrollToElement("queue.start.item-ui-text-regression").tap()
    }

    /// Like `scrollToElement`, for an identifier that a wrapper and its Button can share on iOS 26.5: the Button only.
    private func scrollToButtonIdentified(_ identifier: String) -> XCUIElement {
        let candidate = app.buttons[identifier].firstMatch
        for _ in 0..<12 where !isReadyToTap(candidate) {
            app.swipeUp()
        }
        XCTAssertTrue(candidate.waitForExistence(timeout: 4), "Missing \(identifier)")
        return candidate
    }

    private func scrollToElement(_ identifier: String) -> XCUIElement {
        let candidate = element(identifier)
        for _ in 0..<12 where !isReadyToTap(candidate) {
            app.swipeUp()
        }
        XCTAssertTrue(candidate.waitForExistence(timeout: 4), "Missing \(identifier)")
        return candidate
    }

    private func scrollToStaticText(_ text: String) -> XCUIElement {
        let candidate = app.staticTexts[text]
        for _ in 0..<12 where !isReadyToTap(candidate) {
            app.swipeUp()
        }
        XCTAssertTrue(candidate.waitForExistence(timeout: 4), "Missing \(text)")
        return candidate
    }

    private func scrollToStaticText(containing text: String) -> XCUIElement {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let candidate = app.staticTexts.matching(predicate).firstMatch
        for _ in 0..<12 where !isReadyToTap(candidate) {
            app.swipeUp()
        }
        XCTAssertTrue(candidate.waitForExistence(timeout: 4), "Missing static text containing \(text)")
        return candidate
    }

    private func scrollToButton(containingLabel text: String) -> XCUIElement {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let candidate = app.buttons.matching(predicate).firstMatch
        for _ in 0..<12 where !isReadyToTap(candidate) {
            app.swipeUp()
        }
        XCTAssertTrue(candidate.waitForExistence(timeout: 4), "Missing button containing \(text)")
        return candidate
    }

    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitUntil(_ object: Any, _ format: String, _ args: Any..., timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, argumentArray: args), object: object)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private static let manualListeningMapJSON = """
    {"schemaVersion":"listening-map.v1","overview":"Manual validation map.","chapters":[{"id":"manual-opening","title":"Manual Opening","description":"The item grants distrust.","anchor":"Opening distrust is reasonable."},{"id":"manual-process","title":"Manual Process","description":"The item shifts the inspection target.","anchor":"The paper trail around the medicine is what can be inspected."}]}
    """
}
