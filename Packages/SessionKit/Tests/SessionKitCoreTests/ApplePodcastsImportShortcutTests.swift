import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitFeeds

/// #4290: "Import from Apple Podcasts" in the drawer and in Following. The link is the owner's current shared Shortcut,
/// the words are the Design's, and the button opens one link per tap and falls back to the manual steps.
final class ApplePodcastsImportShortcutTests: XCTestCase {
    func testTheLinkIsTheOwnersCurrentICloudShortcut() throws {
        let link = ApplePodcastsImportShortcut.link
        let components = try XCTUnwrap(URLComponents(url: link, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "www.icloud.com")
        XCTAssertNil(components.query, "nothing about the listener rides on the link")
        XCTAssertNil(components.fragment)
        let parts = components.path.split(separator: "/").map(String.init)
        XCTAssertEqual(parts.count, 2, components.path)
        XCTAssertEqual(parts.first, "shortcuts")
        let id = try XCTUnwrap(parts.last)
        XCTAssertEqual(id.count, 32)
        XCTAssertTrue(id.allSatisfy { $0.isHexDigit && !$0.isUppercase }, id)
        XCTAssertFalse(ApplePodcastsImportShortcut.retiredShortcutIDs.contains(id), "the bare-link version shared before the space fix")
        XCTAssertEqual(id, "ccb7e3db856a48a2b90799a05331a9cc", "the link recorded on #4290 after the space fix")
    }

    func testTheGuideSaysWhatTheDesignSays() {
        XCTAssertEqual(ApplePodcastsImportShortcut.title, "Import from Apple Podcasts")
        XCTAssertEqual(ApplePodcastsImportShortcut.steps.count, 2)
        XCTAssertTrue(ApplePodcastsImportShortcut.steps[0].contains(ApplePodcastsImportShortcut.getButton),
                      "step 1 names the button the listener taps")
        XCTAssertTrue(ApplePodcastsImportShortcut.steps[1].contains("Nothing is followed until you tap Follow."))
        XCTAssertTrue(ApplePodcastsImportShortcut.footnote.contains("Tap Allow."))
        XCTAssertTrue(ApplePodcastsImportShortcut.linkFailed.contains("make the Shortcut yourself"))
        XCTAssertEqual(ApplePodcastsImportShortcut.manualTitle, "Make it yourself")
        // No line is empty or padded, and nothing in the guide reads a link aloud.
        for line in ApplePodcastsImportShortcut.readingOrder + [ApplePodcastsImportShortcut.linkFailed, ApplePodcastsImportShortcut.noLinksMessage] {
            XCTAssertFalse(line.isEmpty)
            XCTAssertEqual(line, line.trimmingCharacters(in: .whitespacesAndNewlines))
            XCTAssertFalse(line.contains("http"), line)
        }
    }

    func testTheManualStepsNameTheSpaceThatMakesTheRowsReadable() {
        let text = ApplePodcastsImportShortcut.manualSteps[1]
        XCTAssertTrue(text.contains("Name, then one space, then the podcast's Feed URL"), text)
        XCTAssertTrue(ApplePodcastsImportShortcut.manualClosing.contains("space"))
        XCTAssertEqual(ApplePodcastsImportShortcut.manualSteps.count, 3)
        XCTAssertTrue(ApplePodcastsImportShortcut.manualSteps[0].hasPrefix("Get Podcasts from Library"))
        XCTAssertTrue(ApplePodcastsImportShortcut.manualSteps[2].contains("Follow Podcasts in Spoken Margins"), "the action's own title")
    }

    /// What the steps build passes rows the preview reads as named shows; without the space it can't (the owner's
    /// second version, 2026-11-21).
    func testRowsBuiltAsTheStepsSayGiveNamedShows() throws {
        let built = ["Planet Money https://feeds.npr.org/510289/podcast.xml", "Hard Fork https://feeds.simplecast.com/l2i9YnTd"]
        let document = try FeedLinkListParser.parse(built)
        XCTAssertEqual(document.feeds.map(\.title), ["Planet Money", "Hard Fork"])
        XCTAssertEqual(document.feeds.map(\.feedURL), ["https://feeds.npr.org/510289/podcast.xml", "https://feeds.simplecast.com/l2i9YnTd"])
        XCTAssertEqual(document.unusableOutlineCount, 0)
    }

    func testTheNoLinksMessageSpeaksToBothKindsOfListener() {
        let message = ApplePodcastsImportShortcut.noLinksMessage
        XCTAssertTrue(message.hasPrefix("No podcast links came through."))
        XCTAssertTrue(message.contains("If you made this Shortcut yourself"))
        XCTAssertTrue(message.contains("If you added ours"))
    }

    func testOneTapOpensOneLinkHoweverFastTheTapsCome() {
        var state = ApplePodcastsImportGuideState()
        XCTAssertTrue(state.beginOpening())
        XCTAssertFalse(state.beginOpening(), "a second tap while the first link is on its way opens nothing")
        XCTAssertFalse(state.beginOpening())
        state.finishedOpening(accepted: true)
        XCTAssertFalse(state.linkFailed)
        XCTAssertFalse(state.showsManualSteps, "an opened link leaves the guide as it was")
        XCTAssertTrue(state.beginOpening(), "back from Shortcuts, the button works again")
    }

    func testALinkThatDidntOpenShowsTheLineAndOpensTheManualSteps() {
        var state = ApplePodcastsImportGuideState()
        XCTAssertFalse(state.showsManualSteps, "closed by default")
        XCTAssertTrue(state.beginOpening())
        state.finishedOpening(accepted: false)
        XCTAssertTrue(state.linkFailed)
        XCTAssertTrue(state.showsManualSteps)
        XCTAssertFalse(state.isOpening)
        // The listener may close the steps; trying again and succeeding clears the failed line.
        state.showsManualSteps = false
        XCTAssertTrue(state.beginOpening())
        state.finishedOpening(accepted: true)
        XCTAssertFalse(state.linkFailed)
        XCTAssertFalse(state.showsManualSteps)
    }
}
