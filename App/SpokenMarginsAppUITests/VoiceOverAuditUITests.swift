import XCTest

// VoiceOver audit (#207): Xcode's accessibility audit over the screens a listener meets in J1 (listen to an
// article), J3 (record a Margin), J5 (share) and adding an item. It does not drive VoiceOver and can't hear it;
// the by-ear pass stays with the owner and gates any outreach to blind or low-vision listeners.
//
// Every finding of every type, on every screen, goes into one attached report ("VoiceOver audit findings"), so
// the report lists them all before a fix. Only the types in `mustFix` fail a test: a control VoiceOver can't
// name (sufficientElementDescription) and a control too small to tap (hitRegion). Contrast, Dynamic Type and
// clipped text are reported and become their own issues when they need a design change.
final class VoiceOverAuditUITests: XCTestCase {
    private var app: XCUIApplication!
    private var report: [String] = []

    private static let mustFix: XCUIAccessibilityAuditType = [.sufficientElementDescription, .hitRegion]
    private let podcastItemId = "item-ui-podcast"

    override func setUpWithError() throws {
        continueAfterFailure = false
        report = []
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing",
            "-libraryContentTypeFilter", "all", "-libraryListeningStateFilter", "unfinished",
            "-libraryOfflineStateFilter", "all", "-librarySort", "recently_added",
            "-libraryUnfinishedDefaultApplied", "YES"]
        app.launchEnvironment["SPOKEN_MARGINS_UI_TESTING"] = "1"
    }

    override func tearDownWithError() throws {
        let attachment = XCTAttachment(string: report.isEmpty ? "No findings." : report.joined(separator: "\n"))
        attachment.name = "VoiceOver audit findings"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
        app = nil
    }

    // MARK: - Adding an item

    func testLibraryAndAddItemScreens() throws {
        launchPodcast()
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8), "Library did not open")
        audit("Library")

        let add = app.buttons["home.addSource.button"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "Add Source control is missing")
        assertSpokenName(of: add)
        add.tap()
        XCTAssertTrue(element("addSource.sheet").waitForExistence(timeout: 5), "Add Source did not open")
        audit("Add item: choose a source type")

        let pasted = element("addSource.route.pastedText")
        for _ in 0..<8 where !pasted.isHittable { app.swipeUp() }
        XCTAssertTrue(pasted.waitForExistence(timeout: 5), "The pasted text route is missing")
        pasted.tap()
        XCTAssertTrue(element("create.title.field").waitForExistence(timeout: 5), "The pasted text form did not open")
        audit("Add item: pasted text form")
    }

    // MARK: - J1: listen to an article

    func testArticleNowPlaying() throws {
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_TITLE"] = "J1: A short walk"
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_TEXT"] = [
            "The path begins beside a quiet wooden gate.",
            "Morning light reaches the old oak tree.",
            "A small bird lands on the stone wall.",
            "The river bends toward the distant bridge."
        ].joined(separator: " ")
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_URL"] = "https://example.com/j1-article"
        app.launch()
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8), "Library did not open")
        let start = app.buttons["queue.start.item-ui-text-regression"]
        XCTAssertTrue(start.waitForExistence(timeout: 5), "The article's start control is missing")
        assertSpokenName(of: start)
        start.tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8), "Now Playing did not open")
        pausePlayback()
        assertTransportControlsAreNamed()
        audit("Now Playing, article")
    }

    // MARK: - J3: record a Margin

    func testNowPlayingAndRecordingScreens() throws {
        launchPodcast()
        startPodcast()
        assertTransportControlsAreNamed()
        audit("Now Playing, podcast")

        let record = app.buttons["playback.interject.button"]
        XCTAssertTrue(record.waitForExistence(timeout: 5), "The record control is missing")
        XCTAssertEqual(record.label, "Record a Margin", "Recording has no clear spoken name")
        record.tap()
        XCTAssertTrue(element("recording.screen").waitForExistence(timeout: 5), "Recording did not open")
        let duration = element("recording.duration.label")
        XCTAssertTrue(duration.waitForExistence(timeout: 5), "Recording clock is missing")
        let finish = app.buttons["recording.finish.button"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5), "The stop control is missing")
        XCTAssertTrue(finish.label.contains("Save"), "Stopping a recording has no clear spoken name: \(finish.label)")
        assertSpokenName(of: app.buttons["recording.cancel.button"])
        attachDump("Recording screen elements")
        audit("Recording")

        finish.tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8), "Did not return to Now Playing")
        pausePlayback()

        app.buttons["playback.timeline.button"].tap()
        XCTAssertTrue(element("timeline.screen").waitForExistence(timeout: 5), "Timeline did not open")
        audit("Timeline")
        app.buttons["playback.margins.button"].tap()
        XCTAssertTrue(element("margins.screen").waitForExistence(timeout: 5), "Margins did not open")
        audit("Margins")
    }

    // MARK: - J5: share

    func testShareScreens() throws {
        launchPodcast()
        startPodcast()
        app.buttons["playback.interject.button"].tap()
        XCTAssertTrue(element("recording.screen").waitForExistence(timeout: 5), "Recording did not open")
        let duration = element("recording.duration.label")
        XCTAssertTrue(duration.waitForExistence(timeout: 5), "Recording clock is missing")
        // The fixture recorder saves a tone as long as the recording lasted, so let it run a few seconds.
        let ranAFewSeconds = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            duration.label.hasSuffix("00:03") || duration.label.hasSuffix("00:04")
        }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [ranAFewSeconds], timeout: 15), .completed, "Recording clock did not advance")
        app.buttons["recording.finish.button"].tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8), "Did not return to Now Playing")
        pausePlayback()

        app.buttons["playback.margins.button"].tap()
        let share = app.buttons["margins.shareItem.\(podcastItemId)"]
        XCTAssertTrue(share.waitForExistence(timeout: 5), "The item's share control is missing")
        assertSpokenName(of: share)
        share.tap()
        XCTAssertTrue(element("build23.sender.experience").waitForExistence(timeout: 5), "Share Margins did not open")
        let cleanUpQuestion = app.alerts["Clean selected Margins automatically?"]
        if cleanUpQuestion.waitForExistence(timeout: 2) { cleanUpQuestion.buttons["Not now"].tap() } // first share only
        audit("Share: choose Margins")

        let review = element("build23.sender.select.continue")
        XCTAssertTrue(review.waitForExistence(timeout: 5), "Review is missing")
        review.tap()
        XCTAssertTrue(element("build23.sender.stage.review").waitForExistence(timeout: 5), "Review did not open")
        audit("Share: review")
    }

    // MARK: - Helpers

    private func launchPodcast() {
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_PODCAST"] = "1"
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_RECORDING"] = "1"
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_TITLE"] = "VoiceOver audit: An episode to talk over"
        app.launch()
    }

    private func startPodcast() {
        XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8), "Library did not open")
        let start = app.buttons["queue.start.\(podcastItemId)"]
        XCTAssertTrue(start.waitForExistence(timeout: 5), "The episode's start control is missing")
        start.tap()
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8), "Now Playing did not open")
        pausePlayback()
    }

    /// A moving clock would change the screen under the audit.
    private func pausePlayback() {
        let playPause = app.buttons["playback.play.button"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 5), "The play control is missing")
        if playPause.label == "Pause" { playPause.tap() }
        let paused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Play"), object: playPause)
        XCTAssertEqual(XCTWaiter().wait(for: [paused], timeout: 8), .completed, "Playback did not pause")
    }

    private func assertTransportControlsAreNamed() {
        for identifier in ["playback.back.button", "playback.play.button", "playback.forward.button",
                           "playback.interject.button", "playback.write.button"] {
            assertSpokenName(of: app.buttons[identifier])
        }
    }

    /// The control has a name a listener can understand: not empty, and not the identifier or a symbol name.
    private func assertSpokenName(of control: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(control.waitForExistence(timeout: 5), "Missing control: \(control)", file: file, line: line)
        let label = control.label
        XCTAssertFalse(label.trimmingCharacters(in: .whitespaces).isEmpty,
                       "A control has no spoken name: \(control.identifier)", file: file, line: line)
        XCTAssertFalse(label.contains(control.identifier) && !control.identifier.isEmpty,
                       "A control is named by its identifier: \(label)", file: file, line: line)
        XCTAssertFalse(label.contains(".fill") || label.contains("systemName"),
                       "A control is named by its symbol: \(label)", file: file, line: line)
    }

    /// Runs the whole audit on the current screen. Every finding is reported; only `mustFix` ones fail the test,
    /// and they don't stop the audits that follow.
    private func audit(_ screen: String) {
        let previous = continueAfterFailure
        continueAfterFailure = true
        defer { continueAfterFailure = previous }
        XCTContext.runActivity(named: "VoiceOver audit: \(screen)") { _ in
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Audit screen — \(screen)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            do {
                try app.performAccessibilityAudit(for: .all) { issue in
                    let element = issue.element
                    let target = [element?.identifier, element?.label].compactMap { $0 }.first { !$0.isEmpty } ?? "unnamed element"
                    self.report.append("\(screen) | \(Self.name(of: issue.auditType)) | \(target) | \(issue.compactDescription)")
                    // Returning true means "handled": the finding is listed above and doesn't fail the test.
                    return !Self.mustFix.contains(issue.auditType)
                }
            } catch {
                XCTFail("The audit could not run on \(screen): \(error)")
            }
        }
    }

    private static func name(of type: XCUIAccessibilityAuditType) -> String {
        switch type {
        case .sufficientElementDescription: return "missing label"
        case .hitRegion: return "tap target"
        case .elementDetection: return "element not exposed"
        case .contrast: return "contrast"
        case .dynamicType: return "dynamic type"
        case .textClipped: return "text clipped"
        case .trait: return "trait"
        default: return "audit type \(type.rawValue)"
        }
    }

    /// The elements VoiceOver would reach on the current screen, with their labels.
    private func attachDump(_ name: String) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
