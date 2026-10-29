import XCTest

// J11: a fresh install reaches audio, then a first Margin, the way a new listener does (#2854).
// The launch wipes the app's defaults and the Library and seeds nothing (SPOKEN_MARGINS_UI_TEST_FIRST_RUN),
// so the Welcome sample, the first-run drawer, the Terms screen and the first Margin prompt run as shipped.
// The script takes the path that needs no network: Done with nothing picked plays the Welcome sample. Picking a
// show or a Substack hits the network and stays with the agent run (docs/journeys.md, J11).
// Microphone and speech recognition are stand-ins here; whether the real prompts behave, and whether anything is
// audible, is "owner to confirm". Each run attaches the taps and seconds it took, for the desk to compare.
final class J11FirstMinuteJourneyUITests: XCTestCase {
    private var app: XCUIApplication!
    private var taps = 0
    private var launchedAt = Date()
    private var report: [String] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["SPOKEN_MARGINS_UI_TESTING"] = "1"
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_FIRST_RUN"] = "1"
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_RECORDING"] = "1"
    }

    override func tearDownWithError() throws {
        let attachment = XCTAttachment(string: report.joined(separator: "\n"))
        attachment.name = "J11 first minute"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
        app = nil
    }

    func testANewListenerReachesAudioAndAFirstMargin() throws {
        XCTContext.runActivity(named: "J11 step 1: First launch opens the drawer of shows") { _ in
            launchedAt = Date()
            app.launch()
            XCTAssertTrue(element("catalog.drawer").waitForExistence(timeout: 20), "The first-run drawer did not open")
            note("drawer open")
        }

        XCTContext.runActivity(named: "J11 step 2: Done with nothing picked starts the Welcome sample") { _ in
            tap("catalog.drawer.done")
        }

        XCTContext.runActivity(named: "J11 step 3: The Terms are one short screen with both buttons in view") { _ in
            XCTAssertTrue(element("terms.screen").waitForExistence(timeout: 20), "The Terms screen did not appear at the first Play")
            let accept = app.buttons["terms.accept.button"], decline = app.buttons["terms.decline.button"]
            XCTAssertTrue(accept.waitForExistence(timeout: 5), "Agree is missing")
            XCTAssertTrue(accept.isHittable && decline.isHittable, "Both Terms buttons must be reachable without scrolling")
            note("terms shown")
            tap("terms.decline.button")
        }

        XCTContext.runActivity(named: "J11 step 4: Audio starts (owner to confirm it is audible)") { _ in
            XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 15), "Now Playing did not open")
            XCTAssertTrue(app.buttons["playback.itemTitle.button"].waitForExistence(timeout: 5), "Playing item's title is missing")
            note("audio started, \(taps) taps")
        }

        XCTContext.runActivity(named: "J11 step 5: One prompt asks for a first Margin, and the Margin is saved") { _ in
            XCTAssertTrue(element("playback.firstMargin.prompt").waitForExistence(timeout: 10), "The first Margin prompt did not appear")
            XCTAssertFalse(element("playback.onboarding.card").exists, "The tour coach must stay out of the way of the prompt")
            tap("playback.firstMargin.prompt")
            XCTAssertTrue(element("recording.screen").waitForExistence(timeout: 8), "Recording did not open")
            let duration = element("recording.duration.label")
            XCTAssertTrue(duration.waitForExistence(timeout: 5), "Recording clock is missing")
            waitUntil("Recording clock did not reach 2 s", timeout: 15) { self.seconds(duration.label).map { $0 >= 2 } ?? false }
            tap("recording.finish.button")
            XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8), "Did not return to Now Playing")
            XCTAssertFalse(element("playback.firstMargin.prompt").exists, "The prompt must not come back after a first Margin")
            // The count lives in the Margins pane, which Now Playing doesn't open by itself. Opening it is
            // checking, not listening, so it isn't counted in the taps.
            let marginsPane = element("playback.margins.button")
            XCTAssertTrue(marginsPane.waitForExistence(timeout: 8), "The Margins pane button is missing")
            note("first Margin saved, \(taps) taps")
            marginsPane.tap()
            waitUntil("The saved Margin did not appear in the count", timeout: 10) {
                self.element("playback.margins.count").exists && self.element("playback.margins.count").label == "Margins: 1"
            }
        }
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func tap(_ identifier: String) {
        let control = element(identifier)
        XCTAssertTrue(control.waitForExistence(timeout: 8), "\(identifier) is missing")
        control.tap()
        taps += 1
    }

    private func note(_ what: String) {
        report.append(String(format: "%.1fs  %@", Date().timeIntervalSince(launchedAt), what))
    }

    private func seconds(_ label: String) -> Int? {
        guard let clock = label.split(separator: " ").last else { return nil }
        let parts = clock.split(separator: ":").map { Int($0) }
        guard parts.count == 2 || parts.count == 3, !parts.contains(nil) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) {
        let met = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [met], timeout: timeout), .completed, message)
    }
}
