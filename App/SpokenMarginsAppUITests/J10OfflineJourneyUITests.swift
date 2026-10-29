import XCTest

// J10: everything local works with the product server unreachable (#1842).
// Every launch passes `-SMServerHost offline.invalid` (Debug only, #2058), so server
// config, the guided-tour manifest, share links, Listening Maps and the catalog all
// fail as if the server were down. Each test seeds its own item, because the seed
// hooks take one item per launch.
// What stays with the agent run: Kitten (UI testing forces the iOS voice), importing
// the packet on a second simulator, and a podcast's Listening Map, which is opt-in
// and needs a real episode. Audio itself stays with the owner.
final class J10OfflineJourneyUITests: XCTestCase {
    private var app: XCUIApplication!
    private let articleTitle = "J10: A walk with no server"
    private let articleId = "item-ui-text-regression"
    private let note = "J10: written with the server unreachable"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-SMServerHost", "offline.invalid",
            "-libraryContentTypeFilter", "all", "-libraryListeningStateFilter", "unfinished",
            "-libraryOfflineStateFilter", "all", "-librarySort", "recently_added",
            "-libraryUnfinishedDefaultApplied", "YES"]
        app.launchEnvironment["SPOKEN_MARGINS_UI_TESTING"] = "1"
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testArticlePlaysTakesBothMarginsAndBuildsAPacketOffline() throws {
        seedArticle()
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_RECORDING"] = "1"

        try XCTContext.runActivity(named: "J10 step 1: The article plays with the server unreachable") { _ in
            app.launch()
            XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8), "Library did not open")
            try startArticle()
        }

        try XCTContext.runActivity(named: "J10 step 2a: Record a spoken Margin") { _ in
            tap("playback.interject.button")
            XCTAssertTrue(element("recording.screen").waitForExistence(timeout: 5), "Recording did not open")
            let duration = element("recording.duration.label")
            XCTAssertTrue(duration.waitForExistence(timeout: 5), "Recording clock is missing")
            waitUntil("Recording clock did not reach 3 s", timeout: 10) {
                self.seconds(duration.label).map { $0 >= 3 } ?? false
            }
            tap("recording.finish.button")
            XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8), "Did not return to Now Playing")
            try waitUntilPlaying("The article did not resume after the spoken Margin")
            try waitUntilAdvancing("The article is stuck after the spoken Margin")
        }

        try XCTContext.runActivity(named: "J10 step 2b: Write a Margin; both Margins show on the item") { _ in
            tap("playback.write.button")
            XCTAssertTrue(element("writtenMargin.screen").waitForExistence(timeout: 5), "Write a Margin did not open")
            let field = element("writtenMargin.text")
            XCTAssertTrue(field.waitForExistence(timeout: 5), "The Margin's text field is missing")
            field.tap()
            field.typeText(note)
            tap("writtenMargin.save.button")
            XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8), "Did not return to Now Playing")

            tap("playback.timeline.button")
            XCTAssertTrue(element("timeline.screen").waitForExistence(timeout: 5), "Timeline did not open")
            // A row's open and star buttons share the prefix, so count the rows only.
            let margins = app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND NOT (identifier CONTAINS %@) AND NOT (identifier CONTAINS %@)",
                "timeline.interjection.", ".open.", ".star."))
            waitUntil("The item does not show both Margins", timeout: 8) { margins.count == 2 }
            screenshot("J10 Timeline with a spoken and a written Margin")
            tap("timeline.nowPlaying.button")
            XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 5), "Could not return to Now Playing")
        }

        try XCTContext.runActivity(named: "J10 step 3: Build and verify a .spokenmargins packet") { _ in
            // The Debug footer stages the exact verified file into the import review, which stands in for
            // the share sheet here. Importing it on a second simulator stays with the agent run.
            if playPause.label == "Pause" { playPause.tap() }
            waitUntil("The article did not pause before export") { self.playPause.label == "Play" }
            tap("playback.options.button")
            let export = element("playback.export.button")
            for _ in 0..<12 where !export.isHittable { app.swipeUp() }
            XCTAssertTrue(export.isHittable, "Export is not reachable from the playback options")
            export.tap()
            XCTAssertTrue(element("export.screen").waitForExistence(timeout: 5), "Export did not open")
            let shareMargins = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Share Margins")).firstMatch
            for _ in 0..<12 where !shareMargins.isHittable { app.swipeUp() }
            XCTAssertTrue(shareMargins.isHittable, "Share Margins is not reachable on Export")
            shareMargins.tap()
            XCTAssertTrue(element("build23.sender.experience").waitForExistence(timeout: 8), "The sender flow did not open")
            let cleanUpQuestion = app.alerts["Clean selected Margins automatically?"]
            if cleanUpQuestion.waitForExistence(timeout: 2) { cleanUpQuestion.buttons["Not now"].tap() } // first share only
            senderElement("build23.sender.select.continue").tap()
            XCTAssertTrue(element("build23.sender.stage.review").waitForExistence(timeout: 5), "The review stage did not open")
            senderElement("build23.sender.preview.build").tap()
            XCTAssertTrue(element("build23.sender.recipient.verified-preview").waitForExistence(timeout: 12),
                          "The packet was not written and verified with the server unreachable")
            let stage = element("build23.sender.recipient-test-session")
            XCTAssertTrue(stage.waitForExistence(timeout: 5), "The verified packet can't be staged for import")
            stage.tap()
            XCTAssertTrue(element("build23.recipient.experience").waitForExistence(timeout: 8),
                          "The verified packet did not open in the import review")
            let integrity = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "integrity checked")).firstMatch
            XCTAssertTrue(integrity.waitForExistence(timeout: 5), "The import review does not show the packet checked")
            screenshot("J10 import review of the packet built offline")
        }
    }

    func testPDFPlaysOffline() throws {
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_PDF"] = "1"

        try XCTContext.runActivity(named: "J10 step 1b: The imported PDF plays with the server unreachable") { _ in
            app.launch()
            XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8), "Library did not open")
            let row = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.row.item-obsidian-")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 20), "The PDF never finished importing into the Library")
            let itemId = String(row.identifier.dropFirst("library.row.".count))
            tap("queue.start.\(itemId)")
            XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8), "Now Playing did not open")
            let title = app.buttons["playback.itemTitle.button"].label
            XCTAssertTrue(title.contains("Walking Notes"), "A different item is playing: \(title)")
            try waitUntilPlaying("The PDF never reached the playing state")
            let first = try percent()
            waitUntil("The PDF's position did not advance while playing", timeout: 15) {
                self.currentPercent().map { $0 > first } ?? false
            }
            screenshot("J10 PDF playing offline")
        }
    }

    func testShareLinkFailsWithAMessageAndPlaybackKeepsGoing() throws {
        seedArticle()

        try XCTContext.runActivity(named: "J10 step 4: Open a share link while the article plays") { _ in
            app.launch()
            XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8), "Library did not open")
            try startArticle()
            // The real host, so the app recognises the link; the packet is fetched from the swapped host.
            // A link without its #key fails as damaged before asking the server, so it carries one
            // (ShareLinkOpeningTests pins this exact link).
            let link = try XCTUnwrap(URL(string:
                "https://spokenmargins.proximitytoprogress.com/l/0123456789abcdef0123456789abcdef#AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"))
            app.open(link)
            guard app.wait(for: .runningForeground, timeout: 5) else {
                // J10: if Safari takes the link, the universal link didn't route; neither a pass nor a fail.
                throw XCTSkip("The share link opened outside the app, so this simulator didn't route it")
            }
            let banner = element("app.feedback.banner")
            XCTAssertTrue(banner.waitForExistence(timeout: 20), "The share link showed no message")
            screenshot("J10 share link with the server unreachable")
            // "offline" means the fetch went to the swapped host; the real server would answer with a not-found.
            XCTAssertTrue(banner.label.localizedCaseInsensitiveContains("offline"),
                          "The share link did not fail as a network error: \(banner.label)")
            XCTAssertEqual(playPause.label, "Pause", "The failed share link stopped playback")
            try waitUntilAdvancing("The article is stuck after the failed share link")
        }
    }

    private var playPause: XCUIElement { app.buttons["playback.play.button"] }

    /// Long enough to keep playing through both Margins and the trip to Export.
    private func seedArticle() {
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_TITLE"] = articleTitle
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_TEXT"] = Array(repeating: [
            "The path begins beside a quiet wooden gate.",
            "Morning light reaches the old oak tree.",
            "A small bird lands on the stone wall.",
            "The river bends toward the distant bridge.",
            "Willows lean above the shallow water.",
            "A bicycle waits beside the village shop."
        ].joined(separator: " "), count: 6).joined(separator: " ")
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_URL"] = "https://example.com/j10-article"
    }

    private func startArticle() throws {
        tap("queue.start.\(articleId)")
        XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8), "Now Playing did not open")
        XCTAssertEqual(app.buttons["playback.itemTitle.button"].label, articleTitle, "A different item is playing")
        try waitUntilPlaying("The article never reached the playing state")
        try waitUntilAdvancing("The article's position did not advance while playing")
        screenshot("J10 article playing offline")
    }

    /// Scrolls the sender flow until `identifier` sits clear of its pinned footer, as Gate1FlowUITests does.
    private func senderElement(_ identifier: String) -> XCUIElement {
        let candidate = element(identifier)
        let sender = element("build23.sender.experience")
        XCTAssertTrue(sender.waitForExistence(timeout: 5), "The sender flow is missing")
        let footer = element("build23.sender.recipient-test-session")
        func visibleBottom() -> CGFloat {
            let screenBottom = min(sender.frame.maxY - 8, app.windows.firstMatch.frame.maxY - 34)
            return footer.exists ? min(screenBottom, footer.frame.minY - 12) : screenBottom
        }
        func reachable() -> Bool {
            candidate.exists && candidate.isHittable
                && candidate.frame.minY >= sender.frame.minY + 12 && candidate.frame.maxY <= visibleBottom()
        }
        for _ in 0..<12 where !reachable() {
            let origin = sender.coordinate(withNormalizedOffset: .zero)
            let x = sender.frame.width - 24
            let lower = visibleBottom() - sender.frame.minY - 20
            let upper: CGFloat = 80
            let moveDown = candidate.exists && candidate.frame.minY < sender.frame.minY + 12
            origin.withOffset(CGVector(dx: x, dy: moveDown ? upper : lower))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: x, dy: moveDown ? lower : upper)))
        }
        XCTAssertTrue(candidate.waitForExistence(timeout: 5) && reachable(), "Can't reach \(identifier) in the sender flow")
        return candidate
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitUntilPlaying(_ message: String) throws {
        XCTAssertTrue(playPause.waitForExistence(timeout: 5), "Playback control is missing")
        waitUntil(message, timeout: 10) { self.playPause.isEnabled && self.playPause.label == "Pause" }
    }

    /// The article or PDF shows its position as a percentage.
    private func waitUntilAdvancing(_ message: String) throws {
        let start = try percent()
        waitUntil(message, timeout: 15) { self.currentPercent().map { $0 > start } ?? false }
    }

    private func percent() throws -> Int {
        let label = element("playback.progress.label")
        XCTAssertTrue(label.waitForExistence(timeout: 5), "The position is missing")
        return try XCTUnwrap(currentPercent(), "The position is not a percentage: \(label.label)")
    }

    private func currentPercent() -> Int? {
        let label = element("playback.progress.label")
        guard label.exists else { return nil }
        return Int(label.label.replacingOccurrences(of: "%", with: ""))
    }

    /// "m:ss" or "h:mm:ss", optionally after a word such as "Recording duration".
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
