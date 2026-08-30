import XCTest

final class Gate1FlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["SPOKEN_MARGINS_UI_TESTING"] = "1"
        app.launch()
    }

    func testSeededGate1FlowHasPlaybackMiniPlayerExportAndSettings() throws {
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Library"].exists)

        let seededStart = app.buttons["queue.start.item-pill"]
        XCTAssertTrue(seededStart.waitForExistence(timeout: 4), app.debugDescription)
        seededStart.tap()

        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8))
        XCTAssertTrue(scrollToElement("playback.timeline.button").exists)
        openTimelineExperience()
        XCTAssertTrue(element("timeline.rail").exists)
        XCTAssertTrue(scrollToButton(containingLabel: "Source").exists)
        XCTAssertTrue(scrollToButton(containingLabel: "Assistant response").exists)
        returnToNowPlayingFromTimelineIfNeeded()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8))

        app.buttons["playback.forward.button"].tap()
        app.buttons["playback.back.button"].tap()

        app.buttons["playback.export.button"].tap()
        XCTAssertTrue(element("export.screen").waitForExistence(timeout: 4))
        XCTAssertTrue(element("export.preview").waitForExistence(timeout: 4))

        app.buttons["export.home.button"].tap()
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 4))
        XCTAssertTrue(element("miniPlayer.bar").waitForExistence(timeout: 4))
        XCTAssertTrue(element("miniPlayer.close.button").exists)
        XCTAssertTrue(element("miniPlayer.interject.button").exists)
        XCTAssertTrue(element("miniPlayer.playPause.button").exists)
        openLibrarySettings()

        XCTAssertTrue(element("settings.screen").waitForExistence(timeout: 4))
        XCTAssertTrue(scrollToElement("settings.ai.processing").exists)
        XCTAssertTrue(scrollToElement("settings.ai.releaseBoundary").exists)
        XCTAssertFalse(element("provider.name").exists)
        XCTAssertFalse(element("provider.apiKey.field").exists)
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

    func testExperienceOverhaulVisualEvidence() throws {
        XCTAssertTrue(element("library.screen").waitForExistence(timeout: 8))
        captureScreen(named: "01-library")

        let seededStart = app.buttons["queue.start.item-pill"]
        XCTAssertTrue(seededStart.waitForExistence(timeout: 4), app.debugDescription)
        seededStart.tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8))
        captureScreen(named: "02-now-playing")

        openTimelineExperience()
        captureScreen(named: "03-timeline")
        returnToNowPlayingFromTimelineIfNeeded()
        app.buttons["playback.home.button"].tap()
        XCTAssertTrue(element("library.screen").waitForExistence(timeout: 4))
        app.buttons["home.addSource.button"].tap()
        XCTAssertTrue(element("addSource.sheet").waitForExistence(timeout: 4))
        captureScreen(named: "04-add-source")
        app.buttons["Close"].tap()

        app.terminate()
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_RECORDING"] = "1"
        app.launch()
        XCTAssertTrue(element("library.screen").waitForExistence(timeout: 8))
        app.buttons["queue.start.item-pill"].tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8))
        scrollToElement("playback.interject.button").tap()
        XCTAssertTrue(element("recording.screen").waitForExistence(timeout: 4))
        captureScreen(named: "05-recording")
        element("recording.cancel.button").tap()
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

        app.buttons["settings.home.button"].tap()
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 4))
        app.buttons["library.row.item-pill"].tap()
        XCTAssertTrue(element("item.screen").waitForExistence(timeout: 4))
        XCTAssertTrue(scrollToElement("chapter.jump.manual-process").exists)
    }

    func testItemScreenShowsListeningActionBeforeAtMostOneMapGenerator() throws {
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8))

        let seededItem = app.buttons["queue.row.item-pill"]
        XCTAssertTrue(seededItem.waitForExistence(timeout: 4))
        seededItem.tap()
        XCTAssertTrue(element("item.screen").waitForExistence(timeout: 4))

        let listen = app.buttons["item.start.button"]
        XCTAssertTrue(listen.waitForExistence(timeout: 4))
        XCTAssertTrue(listen.isHittable, "Start or Continue Listening should be available before scrolling.")
        XCTAssertLessThanOrEqual(app.buttons.matching(identifier: "item.generateMap.button").count, 1)
        XCTAssertEqual(app.buttons.matching(identifier: "chapters.generateMap.button").count, 0)
    }

    func testGeneratedTurnTimelineRowsAreLabeledAndTappable() throws {
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8))
        let seededStart = app.buttons["queue.start.item-pill"]
        XCTAssertTrue(seededStart.waitForExistence(timeout: 4), app.debugDescription)
        seededStart.tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8))

        openTimelineExperience()

        XCTAssertTrue(scrollToButton(containingLabel: "My response").exists)
        XCTAssertTrue(scrollToButton(containingLabel: "Assistant response").exists)
        XCTAssertFalse(app.staticTexts["Play full generated response"].exists)

        let aiResponse = scrollToButton(containingLabel: "Assistant response")
        aiResponse.tap()
        XCTAssertTrue(element("playback.title").waitForExistence(timeout: 4))

        openTimelineExperience()
        let aiChapter = scrollToButton(containingLabel: "Timeline Navigation")
        aiChapter.tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 4))
        XCTAssertFalse(element("timeline.screen").exists)
    }

    func testExportAfterTwoSessionsStaysSessionIsolated() throws {
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8))
        let seededStart = app.buttons["queue.start.item-pill"]
        XCTAssertTrue(seededStart.waitForExistence(timeout: 4), app.debugDescription)
        seededStart.tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8))
        app.buttons["playback.export.button"].tap()
        XCTAssertTrue(element("export.screen").waitForExistence(timeout: 4))
        configureFullSessionExport()
        let firstExport = element("export.preview").label
        XCTAssertFalse(firstExport.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        app.buttons["export.home.button"].tap()
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 4))
        let seededItem = app.buttons["library.row.item-pill"]
        XCTAssertTrue(seededItem.waitForExistence(timeout: 4))
        seededItem.tap()
        XCTAssertTrue(element("item.screen").waitForExistence(timeout: 4))
        let startNew = scrollToElement("item.startNew.button")
        startNew.tap()
        let confirmStartNew = app.sheets.buttons["Start New Session"].firstMatch
        XCTAssertTrue(confirmStartNew.waitForExistence(timeout: 4))
        confirmStartNew.tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8))
        app.buttons["playback.export.button"].tap()
        XCTAssertTrue(element("export.screen").waitForExistence(timeout: 4))
        configureFullSessionExport()
        let secondExport = element("export.preview").label

        XCTAssertFalse(secondExport.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(firstExport.contains("bytes"))
        XCTAssertEqual(secondExport, firstExport, "The second session export accumulated data from the first session")
    }

    func testNowPlayingDoesNotExposeCompactTestHarnessControls() throws {
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8))
        let seededStart = app.buttons["queue.start.item-pill"]
        XCTAssertTrue(seededStart.waitForExistence(timeout: 4))
        seededStart.tap()

        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["Compact Controls"].exists)
        XCTAssertFalse(element("gate2.compact.chapter").exists)
        XCTAssertFalse(element("gate2.compact.playPause.button").exists)
        app.buttons["playback.forward.button"].tap()
        app.buttons["playback.back.button"].tap()
        XCTAssertTrue(element("playback.play.button").exists)
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
        XCTAssertTrue(element("playback.export.button").isHittable)

        let playbackScroll = app.scrollViews.firstMatch
        let pullStart = playbackScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
        let pullEnd = playbackScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
        pullStart.press(forDuration: 0.1, thenDragTo: pullEnd)
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

    func testNativeTextPublishesVisibleSimulatorSystemPlaybackState() throws {
        let title = "Now Playing Simulator Probe"
        app.terminate()
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_TITLE"] = title
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_TEXT"] = String(
            repeating: "This native text playback probe must remain long enough to inspect the system media controls. ",
            count: 200
        )
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_URL"] = "https://example.com/now-playing-probe"
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SUPERTONIC"] = "1"
        app.launch()

        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8))
        let start = app.buttons["queue.start.item-ui-text-regression"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8))
        let playPause = app.buttons["playback.play.button"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 8))
        let nativePlaybackConfirmed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@ AND enabled == true", "Pause"),
            object: playPause
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [nativePlaybackConfirmed], timeout: 60),
            .completed,
            "Native text playback never advanced from starting to playing."
        )
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 5))
        let topCenter = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.01))
        let notificationCenter = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.72))
        topCenter.press(forDuration: 0.1, thenDragTo: notificationCenter)

        // On current simulator runtimes the lock-screen playback card is hosted
        // by MediaRemoteUI rather than SpringBoard. Query both because the host
        // process changed across supported iOS versions.
        let mediaRemoteUI = XCUIApplication(bundleIdentifier: "com.apple.MediaRemoteUI")
        _ = mediaRemoteUI.wait(for: .runningForeground, timeout: 5)
        let playbackTitlePredicate = NSPredicate(format: "label CONTAINS[c] %@", title)
        let systemPlaybackTitleExists = springboard.descendants(matching: .any)
            .matching(playbackTitlePredicate).firstMatch.waitForExistence(timeout: 8)
            || mediaRemoteUI.descendants(matching: .any)
                .matching(playbackTitlePredicate).firstMatch.waitForExistence(timeout: 8)
        XCTAssertTrue(
            systemPlaybackTitleExists,
            "Native text playback did not become visible on the Simulator system playback surface.\nSPRINGBOARD:\n\(springboard.debugDescription)\nMEDIA REMOTE UI:\n\(mediaRemoteUI.debugDescription)"
        )
        let pauseButtonPredicate = NSPredicate(format: "label CONTAINS[c] %@", "pause")
        let playingStatePredicate = NSPredicate(format: "label ==[c] %@", "playing")
        let systemPlayingStateExists = springboard.staticTexts
            .matching(playingStatePredicate).firstMatch.exists
            || mediaRemoteUI.staticTexts
                .matching(playingStatePredicate).firstMatch.exists
        var systemPauseControlExists = springboard.buttons.matching(pauseButtonPredicate).firstMatch.exists
            || mediaRemoteUI.buttons.matching(pauseButtonPredicate).firstMatch.exists
        if !systemPauseControlExists {
            // iOS 18 simulators can render only the compact notification card on
            // the cover sheet. Probe Control Center before concluding that the
            // native transport command is unavailable.
            XCUIDevice.shared.press(.home)
            let controlCenterTopRight = springboard.coordinate(
                withNormalizedOffset: CGVector(dx: 0.98, dy: 0.01)
            )
            let controlCenterBody = springboard.coordinate(
                withNormalizedOffset: CGVector(dx: 0.72, dy: 0.62)
            )
            controlCenterTopRight.press(forDuration: 0.1, thenDragTo: controlCenterBody)
            systemPauseControlExists = springboard.buttons
                .matching(pauseButtonPredicate).firstMatch.waitForExistence(timeout: 5)
                || mediaRemoteUI.buttons
                    .matching(pauseButtonPredicate).firstMatch.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(
            systemPauseControlExists || systemPlayingStateExists,
            "The Simulator system playback surface exposed neither a pause control nor a truthful playing state for active native text playback.\nSPRINGBOARD:\n\(springboard.debugDescription)\nMEDIA REMOTE UI:\n\(mediaRemoteUI.debugDescription)"
        )
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
        app.launch()

        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8))
        let start = app.buttons["queue.start.item-ui-text-regression"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8))

        openTimelineExperience()
        let summarize = scrollToElement("timeline.summary.button")
        XCTAssertTrue(summarize.isEnabled)
        summarize.tap()

        let failure = element("app.feedback.banner")
        XCTAssertTrue(failure.waitForExistence(timeout: 8))
        XCTAssertTrue(failure.label.contains("On-device summary failed"))
        XCTAssertTrue(failure.label.contains("Retry Summary"))

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
        scrollToElement("create.start.button").tap()
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 4))

        let libraryRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", itemTitle)).firstMatch
        XCTAssertTrue(libraryRow.waitForExistence(timeout: 4))
        libraryRow.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Move to Recently Deleted"].waitForExistence(timeout: 3))
        app.buttons["Move to Recently Deleted"].tap()
        let trashConfirmation = app.alerts["Move to Recently Deleted?"]
        XCTAssertTrue(trashConfirmation.waitForExistence(timeout: 3))
        trashConfirmation.buttons["Move to Recently Deleted"].tap()
        XCTAssertTrue(waitForDisappearance(libraryRow, timeout: 4))

        openLibrarySettings()
        let delete = scrollToButton(containingLabel: "Delete \(itemTitle) Permanently")
        delete.tap()
        let confirmation = app.alerts["Delete Permanently?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 2))
        confirmation.buttons["Delete Permanently"].tap()

        XCTAssertTrue(waitForDisappearance(app.buttons["Restore \(itemTitle)"], timeout: 2))
        XCTAssertFalse(app.staticTexts[itemTitle].exists)
    }

    func testAddSourcePresentsEveryTypedIntakeRoute() throws {
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8))
        app.buttons["home.addSource.button"].tap()

        for route in ["linkOrPodcast", "pastedText", "documentOrBook", "audiobook", "quickFolder"] {
            XCTAssertTrue(scrollToElement("addSource.route.\(route)").exists, "Missing typed intake route \(route)")
        }
        scrollToElement("addSource.route.documentOrBook").tap()
        XCTAssertTrue(scrollToElement("obsidian.import.button").exists)
        XCTAssertTrue(scrollToElement("epub.import.button").exists)
        element("addSource.route.back").tap()
        scrollToElement("addSource.route.audiobook").tap()
        XCTAssertTrue(scrollToElement("audiobook.import.button").exists)
        element("addSource.route.back").tap()
        scrollToElement("addSource.route.quickFolder").tap()
        XCTAssertTrue(scrollToElement("quickFolder.choose.button").exists)
    }

    func testAmbiguousPodcastImportImmediatelyReplacesAddSourceWithEpisodePicker() throws {
        app.terminate()
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_AMBIGUOUS_SOURCE_LINK"] = "1"
        app.launch()

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

    func testDiagnosticsCopyShowsLocalConfirmation() throws {
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8))
        openLibrarySettings()
        let copy = scrollToElement("settings.copyDiagnostics.button")

        copy.tap()

        XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: 2))
        XCTAssertTrue(element("app.feedback.banner").waitForExistence(timeout: 2))
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

        tapRoot("Sources")
        XCTAssertTrue(element("sources.screen").waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Add a source"].exists)
        XCTAssertTrue(element("sources.follow.url").waitForExistence(timeout: 4))
        XCTAssertTrue(element("sources.follow.button").exists)
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
        app.launch()

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
        XCTAssertFalse(app.buttons["Sources"].exists)
        XCTAssertFalse(app.buttons["Margins"].exists)

        element("recording.cancel.button").tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8))
        XCTAssertFalse(element("recording.screen").exists)
    }

    func testRootsRemainUsableWithLargeTypeDarkContrastAndReducedMotion() throws {
        app.terminate()
        app.launchArguments += [
            "-AppleInterfaceStyle", "Dark",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
            "-UIAccessibilityDarkerSystemColorsEnabled", "YES",
            "-UIAccessibilityReduceMotionEnabled", "YES"
        ]
        app.launch()

        XCTAssertTrue(element("library.screen").waitForExistence(timeout: 8))
        tapRoot("Sources")
        XCTAssertTrue(element("sources.screen").waitForExistence(timeout: 4))
        tapRoot("Margins")
        XCTAssertTrue(element("margins.screen").waitForExistence(timeout: 4))
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

        app.buttons["home.settings.button"].tap()
        let exportSessions = app.buttons["Export Sessions"]
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
        XCTAssertTrue(element("batchExport.chooseFolder.button").waitForExistence(timeout: 2))
        XCTAssertTrue(element("batchExport.chooseFolder.button").isHittable)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func assertMiniPlayerClearsRootNavigation(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let miniPlayer = element("miniPlayer.bar")
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.exists, "Root navigation is missing", file: file, line: line)
        XCTAssertLessThanOrEqual(
            miniPlayer.frame.maxY,
            tabBar.frame.minY,
            "The mini-player overlaps the Library, Sources, and Margins controls",
            file: file,
            line: line
        )
    }

    private func captureScreen(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openLibrarySettings() {
        app.buttons["home.settings.button"].tap()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 2), "Library options did not expose Settings")
        settings.tap()
    }

    private func openTimelineExperience() {
        if element("playback.timeline.adjacent").exists {
            return
        }
        let button = scrollToButton(containingLabel: "Timeline")
        XCTAssertTrue(button.isHittable, "Missing the iPhone Timeline route and iPad adjacent Timeline.")
        button.tap()
        XCTAssertTrue(element("timeline.screen").waitForExistence(timeout: 4))
    }

    private func returnToNowPlayingFromTimelineIfNeeded() {
        let button = app.buttons["timeline.nowPlaying.button"]
        if button.exists {
            button.tap()
        } else {
            XCTAssertTrue(element("playback.timeline.adjacent").exists)
        }
    }

    private func tapRoot(_ name: String) {
        let button = app.buttons[name].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 4), "Missing \(name) root control")
        button.tap()
    }

    private func scrollToElement(_ identifier: String) -> XCUIElement {
        let candidate = element(identifier)
        for _ in 0..<12 where !candidate.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(candidate.waitForExistence(timeout: 4), "Missing \(identifier)")
        return candidate
    }

    private func scrollToStaticText(_ text: String) -> XCUIElement {
        let candidate = app.staticTexts[text]
        for _ in 0..<12 where !candidate.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(candidate.waitForExistence(timeout: 4), "Missing \(text)")
        return candidate
    }

    private func scrollToStaticText(containing text: String) -> XCUIElement {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let candidate = app.staticTexts.matching(predicate).firstMatch
        for _ in 0..<12 where !candidate.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(candidate.waitForExistence(timeout: 4), "Missing static text containing \(text)")
        return candidate
    }

    private func scrollToButton(containingLabel text: String) -> XCUIElement {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let candidate = app.buttons.matching(predicate).firstMatch
        for _ in 0..<12 where !candidate.isHittable {
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

    private func configureFullSessionExport() {
        let fullSession = app.buttons["Full Session"]
        XCTAssertTrue(fullSession.waitForExistence(timeout: 4))
        if !fullSession.isSelected {
            fullSession.tap()
        }

        let includeTurns = scrollToElement("export.includeTurns.toggle")
        if includeTurns.value as? String == "0" {
            includeTurns.tap()
        }
        XCTAssertEqual(includeTurns.value as? String, "1")
    }

    private static let manualListeningMapJSON = """
    {"schemaVersion":"listening-map.v1","overview":"Manual validation map.","chapters":[{"id":"manual-opening","title":"Manual Opening","description":"The item grants distrust.","anchor":"Opening distrust is reasonable."},{"id":"manual-process","title":"Manual Process","description":"The item shifts the inspection target.","anchor":"The paper trail around the medicine is what can be inspected."}]}
    """
}
