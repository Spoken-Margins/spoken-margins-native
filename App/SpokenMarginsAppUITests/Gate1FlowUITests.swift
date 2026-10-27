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
        app.launch()
    }

    func testMarginsItemShareOpensShareSheetAndChapterJumpUpdatesTimeline() throws {
        app.buttons["queue.start.item-pill"].tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8))
        pausePlaybackIfNeeded()
        let next = element("playback.nextChapter.button")
        XCTAssertTrue(next.waitForExistence(timeout: 4))
        next.tap()
        pausePlaybackIfNeeded()
        openTimelineExperience()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Current chapter.")).firstMatch.waitForExistence(timeout: 5))
        captureScreen(named: "qol-current-chapter")
        returnToNowPlayingFromTimelineIfNeeded()
        element("playback.write.button").tap()
        let editor = app.textViews["writtenMargin.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 4))
        editor.tap()
        editor.typeText("A final thought to share with this item.")
        element("writtenMargin.save.button").tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 5))
        element("playback.margins.button").tap()
        let share = element("margins.shareItem.item-pill")
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        captureScreen(named: "qol-item-share-action")
        share.tap()
        // #147: straight to the Share Margins sheet, with Review pinned at the bottom.
        XCTAssertTrue(element("build23.sender.experience").waitForExistence(timeout: 5))
        let cleanUpQuestion = app.alerts["Clean selected Margins automatically?"]
        if cleanUpQuestion.waitForExistence(timeout: 2) { cleanUpQuestion.buttons["Not now"].tap() } // first share only
        let review = element("build23.sender.select.continue")
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        XCTAssertTrue(review.isHittable)
        captureScreen(named: "qol-item-share-sheet")
        review.tap()
        XCTAssertTrue(element("build23.sender.stage.review").waitForExistence(timeout: 5))
        let shareAction = element("build23.sender.review.share")
        XCTAssertTrue(shareAction.waitForExistence(timeout: 5))
        XCTAssertTrue(shareAction.isHittable)
        captureScreen(named: "qol-item-share-review")
        // Third tap: Share is pinned at the bottom of Review and builds, verifies and presents the iOS share sheet.
        shareAction.tap()
        let nativeShareSurface = element("ActivityListView")
        XCTAssertTrue(
            nativeShareSurface.waitForExistence(timeout: 8),
            "Share, Review, Share did not reach the iOS share sheet from the Margins tab."
        )
        captureScreen(named: "qol-item-share-ios-sheet")
        dismissTopSystemSheet()
        XCTAssertTrue(waitForDisappearance(nativeShareSurface, timeout: 5))
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
        app.launch()
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
        app.launch()
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
        scrollToElement("playback.margins.button").tap()
        let open = element("margins.openItem.item-pill")
        let share = element("margins.shareItem.item-pill")
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        XCTAssertTrue(share.exists)
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(share.frame.minY, open.frame.maxY - 1, "Share still sits beside the item title")
        XCTAssertGreaterThanOrEqual(share.frame.height, 44)
        XCTAssertLessThanOrEqual(share.frame.maxX, window.maxX + 1)
        XCTAssertGreaterThan(open.frame.width, window.width * 0.6, "The item title is squeezed beside the buttons")
        captureScreen(named: "margins-heading-accessibility")
    }

    /// #1935: at AX5 the banner gives its message the full width and puts Undo on its own row, 44 pt tall.
    func testFeedbackBannerPutsItsButtonsOnTheirOwnRowAtAccessibilitySizes() throws {
        app.terminate()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue]
        app.launch()
        let row = app.buttons["library.row.item-pill"]
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.press(forDuration: 0.8)
        app.buttons["Mark Complete"].tap()
        let undo = element("completion.undo.button")
        XCTAssertTrue(undo.waitForExistence(timeout: 4))
        let banner = element("app.feedback.banner")
        XCTAssertTrue(banner.exists)
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(undo.frame.minY, banner.frame.maxY - 1, "Undo still sits beside the message")
        XCTAssertGreaterThanOrEqual(undo.frame.height, 44, "Undo is under 44 pt")
        XCTAssertLessThanOrEqual(undo.frame.maxX, window.maxX + 1, "Undo runs off the right edge")
        XCTAssertGreaterThan(banner.frame.width, window.width * 0.6, "The message is squeezed beside the buttons")
        captureScreen(named: "feedback-banner-accessibility")
    }

    func testLibraryUnfinishedCompletionUndoAndSearchDiscovery() throws {
        app.terminate()
        app.launch()
        let row = app.buttons["library.row.item-pill"]
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Completed items hidden"].exists)
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
        XCTAssertTrue(app.staticTexts["All items"].exists)
        captureScreen(named: "library-completed-search-and-undo")
        app.buttons["Clear search"].tap()
        element("library.filters.reset").tap()
        XCTAssertTrue(app.staticTexts["Completed items hidden"].exists)
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
        app.alerts.buttons["Discard recording"].tap()
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

    func testExportPreviewRemainsReachableAfterStartingAnotherSession() throws {
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8))
        let seededStart = app.buttons["queue.start.item-pill"]
        XCTAssertTrue(seededStart.waitForExistence(timeout: 4), app.debugDescription)
        seededStart.tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8))
        openPlaybackExport()
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
        openPlaybackExport()
        XCTAssertTrue(element("export.screen").waitForExistence(timeout: 4))
        configureFullSessionExport()
        let secondExport = element("export.preview").label

        XCTAssertFalse(secondExport.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(firstExport.contains("bytes"))
        XCTAssertTrue(secondExport.contains("bytes"), "The new session has an accessible export size summary; content isolation is asserted against exported data in SessionKit tests.")
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
        app.buttons["playback.options.button"].tap()
        XCTAssertTrue(element("playback.export.button").waitForExistence(timeout: 4))
        XCTAssertTrue(element("playback.export.button").isHittable)
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

        let libraryRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", itemTitle)).firstMatch
        XCTAssertTrue(libraryRow.waitForExistence(timeout: 4))
        libraryRow.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Move to Recently Deleted"].waitForExistence(timeout: 3))
        app.buttons["Move to Recently Deleted"].tap()
        // Library deletion is recoverable immediately; permanent deletion below requires confirmation.
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

    func testShareDiagnosticsOpensTheShareSheet() throws {
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8))
        openLibrarySettings()
        let share = scrollToElement("settings.shareDiagnostics.button")

        share.tap()

        // The exported file's payload is verified by testDiagnosticsExportFileCarriesSafePayload.
        let shareSheet = element("ActivityListView")
        XCTAssertTrue(shareSheet.waitForExistence(timeout: 8), "Share Diagnostics did not open the system share sheet.")
        dismissTopSystemSheet()
        XCTAssertTrue(waitForDisappearance(shareSheet, timeout: 5))
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
        // Following opens on its entries; the feed field lives on Manage Feeds (#141).
        XCTAssertFalse(element("sources.follow.url").exists)
        element("sources.manageFeeds").tap()
        XCTAssertTrue(element("sources.follow.url").waitForExistence(timeout: 4))
        XCTAssertTrue(element("sources.follow.button").exists)
        XCTAssertTrue(element("sources.browseCatalog").exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(element("sources.manageFeeds").waitForExistence(timeout: 4))
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
        element("playback.margins.button").tap()
        XCTAssertTrue(element("margins.screen").waitForExistence(timeout: 4))
        XCTAssertTrue(element("miniPlayer.bar").exists)
        let savedMargin = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "margins.rowDetails.")).firstMatch
        XCTAssertTrue(savedMargin.waitForExistence(timeout: 4))
        savedMargin.tap()
        XCTAssertTrue(element("marginDetail.screen").waitForExistence(timeout: 4), "Tapping the saved Margin row did not open its detail")
        let timelineAction = app.buttons["Open Item"]
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
        app.launch()
        scrollToElement("queue.start.item-ui-text-regression").tap()
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

    func testWrittenMarginSaveSearchStarAndDiscardPreserveTheSource() throws {
        app.terminate()
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_TITLE"] = "A walk with room to think"
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_TEXT"] = String(repeating: "Notice the small details along the way. ", count: 80)
        app.launch()
        scrollToElement("queue.start.item-ui-text-regression").tap()
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
        element("playback.margins.button").tap()
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
        XCTAssertTrue(app.buttons["playback.title"].label.contains("A walk with room to think"))
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
        app.launch()
        let start = scrollToElement("queue.start.item-ui-text-regression")
        XCTAssertTrue(start.isHittable)
        start.tap()
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
        app.launch()
        let play = scrollToElement("queue.start.item-pill")
        XCTAssertTrue(play.isHittable)
        let open = element("library.row.item-pill")
        let viewport = app.windows.firstMatch.frame
        XCTAssertGreaterThan(open.frame.width, viewport.width * 0.8, "The row's title is squeezed beside the icon and the play button")
        XCTAssertGreaterThanOrEqual(play.frame.minY, open.frame.maxY - 1, "The play button sits below the title")
        XCTAssertGreaterThanOrEqual(play.frame.height, 44)
        captureScreen(named: "library-row-accessibility-size")
    }

    func testRootsRemainUsableWithLargeTypeDarkContrastAndReducedMotion() throws {
        app.terminate()
        app.launchArguments += [
            "-AppleInterfaceStyle", "Dark",
            "-UIPreferredContentSizeCategoryName", UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue,
            "-UIAccessibilityDarkerSystemColorsEnabled", "YES",
            "-UIAccessibilityReduceMotionEnabled", "YES"
        ]
        app.launch()

        XCTAssertTrue(element("library.screen").waitForExistence(timeout: 8))
        captureScreen(named: "second-edition-library-dark-accessibility")
        tapRoot("Following")
        XCTAssertTrue(element("sources.screen").waitForExistence(timeout: 4))
        captureScreen(named: "second-edition-following-dark-accessibility")
        tapRoot("Margins")
        XCTAssertTrue(element("margins.screen").waitForExistence(timeout: 4))
        captureScreen(named: "second-edition-margins-dark-accessibility")
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
        app.launch()
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
        XCTAssertGreaterThanOrEqual(filter.frame.height, 44)
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
        let integrity = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "integrity checked")
        ).firstMatch
        XCTAssertTrue(integrity.exists)
        XCTAssertTrue(app.staticTexts["Add the source to continue"].exists)

        let addSource = app.buttons["Add Source"].firstMatch
        XCTAssertTrue(addSource.waitForExistence(timeout: 4))
        let pinnedImport = app.buttons["Import"].firstMatch
        for _ in 0..<6 where addSource.frame.maxY >= pinnedImport.frame.minY {
            app.scrollViews["build23.recipient.experience"].swipeUp()
        }
        XCTAssertLessThan(addSource.frame.maxY, pinnedImport.frame.minY,
                          "Add Source remains covered by the pinned import actions.")
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
        XCTAssertTrue(provenance.label.localizedCaseInsensitiveContains("separate shared layer"))
        XCTAssertTrue(provenance.label.localizedCaseInsensitiveContains("Reveal mode Companion"))
        captureScreen(named: "second-edition-item-shared-provenance")

        element("miniPlayer.open.button").tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 5))
        XCTAssertEqual(element("playback.play.button").label, "Play")
        openTimelineExperience()
        scrollToButton(containingLabel: "Shared Margins").tap()
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
        app.launch()

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
        XCTAssertTrue(app.windows.firstMatch.frame.contains(filter.frame))
        XCTAssertFalse(filter.frame.intersects(element("miniPlayer.bar").frame))
        // iOS 18 reports a visible native Menu as non-hittable. Verify its actual
        // activation and selection instead of trusting that accessibility flag.
        filter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Text"].waitForExistence(timeout: 4))
        app.buttons["Text"].tap()
        XCTAssertTrue(filter.waitForExistence(timeout: 4))
        XCTAssertTrue(filter.label.contains("active filters"))
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
        app.launch()

        XCTAssertTrue(element("library.screen").waitForExistence(timeout: 8))
        let start = app.buttons["queue.start.item-ui-text-regression"]
        XCTAssertTrue(start.waitForExistence(timeout: 5), app.debugDescription)
        start.tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8))
        pausePlaybackIfNeeded()
        openPlaybackExport()
        XCTAssertTrue(element("export.screen").waitForExistence(timeout: 5))
        scrollToButton(containingLabel: "Share Margins").tap()
        XCTAssertTrue(element("build23.sender.experience").waitForExistence(timeout: 8))
    }

    private func openPlaybackExport() {
        element("playback.options.button").tap()
        let export = scrollToElement("playback.export.button")
        XCTAssertTrue(export.isHittable)
        export.tap()
    }

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
        if playPause.label == "Pause" {
            playPause.tap()
        }
        XCTAssertEqual(
            XCTWaiter().wait(
                for: [XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "label == %@", "Play"),
                    object: playPause
                )],
                timeout: 8
            ),
            .completed
        )
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
        func visibleBottom() -> CGFloat {
            let screenBottom = min(senderExperience.frame.maxY - 8, app.windows.firstMatch.frame.maxY - 34)
            return recipientFooter.exists ? min(screenBottom, recipientFooter.frame.minY - 12) : screenBottom
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

    private func openLibrarySettings() {
        tapRoot("Settings")
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

    /// `isHittable` does not answer false for an element with no frame yet, as it does for one off screen: it fails
    /// the test ("Failed to determine hittability ... Activation point invalid"). That failed the first scroll after a
    /// launch at AX5 on the hosted Mac twice in a week (#2760). An element with no usable frame is not ready to tap,
    /// so the scroll loops go on and look again.
    private func isReadyToTap(_ candidate: XCUIElement) -> Bool {
        guard candidate.exists else { return false }
        let frame = candidate.frame
        guard !frame.isNull, !frame.isInfinite, !frame.isEmpty else { return false }
        return candidate.isHittable
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
