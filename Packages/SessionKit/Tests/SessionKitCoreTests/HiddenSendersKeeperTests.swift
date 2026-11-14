import Foundation
import XCTest
@testable import SessionKit

/// The listener's hidden-senders list survives a relaunch and only ever takes real sender ids (#2846). Moved from the
/// app-hosted `HiddenSendersControllerTests` (#318), which keeps one test that the screen's wrapper publishes it.
final class HiddenSendersKeeperTests: XCTestCase {
    private let ana = "0123456789abcdef0123456789abcdef"
    private let ben = "fedcba9876543210fedcba9876543210"
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HiddenSendersKeeperTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAHiddenSenderStaysHiddenAfterARelaunchUntilShownAgain() {
        var first = HiddenSendersKeeper(directory: directory)
        XCTAssertTrue(first.hide(ana, displayLabel: "Ana"))
        XCTAssertTrue(first.isHidden(ana))

        var relaunched = HiddenSendersKeeper(directory: directory)
        XCTAssertEqual(relaunched.current.listed.map(\.senderId), [ana])
        XCTAssertEqual(relaunched.current.listed.first?.displayLabel, "Ana")

        relaunched.unhide(ana)
        XCTAssertTrue(HiddenSendersKeeper(directory: directory).isEmpty)
    }

    func testOnlyARealSenderIdCanBeHidden() {
        var keeper = HiddenSendersKeeper(directory: directory)
        XCTAssertFalse(keeper.hide(nil, displayLabel: "Ana"), "a Margin from an older packet has no id to hide by")
        XCTAssertFalse(keeper.hide("short", displayLabel: "Ana"))
        XCTAssertTrue(keeper.isEmpty)
    }

    func testAHiddenMarginStaysHiddenAfterARelaunchUntilShownAgain() {
        var first = HiddenSendersKeeper(directory: directory)
        XCTAssertTrue(first.hideMargin("margin-1", senderLabel: "Ana", text: "A few words"))
        XCTAssertTrue(first.isMarginHidden("margin-1"))
        XCTAssertFalse(first.isEmpty)

        var relaunched = HiddenSendersKeeper(directory: directory)
        XCTAssertEqual(relaunched.current.listedMargins.map(\.marginId), ["margin-1"])
        XCTAssertTrue(relaunched.current.entries.isEmpty, "hiding one Margin hides no sender")

        relaunched.unhideMargin("margin-1")
        XCTAssertTrue(HiddenSendersKeeper(directory: directory).isEmpty)
    }

    func testAMarginWithNoIdCannotBeHidden() {
        var keeper = HiddenSendersKeeper(directory: directory)
        XCTAssertFalse(keeper.hideMargin("", senderLabel: nil, text: "words"))
        XCTAssertTrue(keeper.isEmpty)
    }

    func testADamagedFileShowsEveryoneAgainAndIsNotAnError() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("hidden-senders.json"))
        XCTAssertTrue(HiddenSendersKeeper(directory: directory).isEmpty)
    }

    func testAMissingFolderKeepsTheListInMemoryOnly() {
        var keeper = HiddenSendersKeeper(directory: nil)
        XCTAssertTrue(keeper.hide(ana, displayLabel: "Ana"))
        XCTAssertTrue(keeper.isHidden(ana))
        XCTAssertTrue(HiddenSendersKeeper(directory: nil).isEmpty, "with no folder nothing is kept for the next launch")
    }

    func testHidingTwoSendersAndShowingOneAgainKeepsTheOther() {
        var keeper = HiddenSendersKeeper(directory: directory)
        keeper.hide(ana, displayLabel: "Ana")
        keeper.hide(ben, displayLabel: "Ben")

        keeper.unhide(ana)

        let relaunched = HiddenSendersKeeper(directory: directory)
        XCTAssertFalse(relaunched.isHidden(ana))
        XCTAssertTrue(relaunched.isHidden(ben))
    }

    func testHidingTheSameSenderAgainChangesNothing() {
        var keeper = HiddenSendersKeeper(directory: directory)
        keeper.hide(ana, displayLabel: "Ana")
        let before = keeper.current

        keeper.hide(ana, displayLabel: "Ana")

        XCTAssertEqual(keeper.current.listed.count, 1)
        XCTAssertEqual(keeper.current.listed.map(\.senderId), before.listed.map(\.senderId))
    }

    func testUnhidingASenderThatWasNeverHiddenIsHarmless() {
        var keeper = HiddenSendersKeeper(directory: directory)
        keeper.unhide(ana)
        keeper.unhideMargin("never-hidden")
        XCTAssertTrue(keeper.isEmpty)
    }
}
