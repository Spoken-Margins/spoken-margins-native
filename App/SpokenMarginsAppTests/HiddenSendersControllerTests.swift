import SessionKit
import XCTest
@testable import SpokenMarginsApp

/// The listener's hidden-senders list survives a relaunch and only ever takes real sender ids (#2846).
@MainActor
final class HiddenSendersControllerTests: XCTestCase {
    private let ana = "0123456789abcdef0123456789abcdef"
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HiddenSendersControllerTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAHiddenSenderStaysHiddenAfterARelaunchUntilShownAgain() {
        let first = HiddenSendersController(directory: directory)
        XCTAssertTrue(first.hide(ana, displayLabel: "Ana"))
        XCTAssertTrue(first.isHidden(ana))

        let relaunched = HiddenSendersController(directory: directory)
        XCTAssertEqual(relaunched.current.listed.map(\.senderId), [ana])
        XCTAssertEqual(relaunched.current.listed.first?.displayLabel, "Ana")

        relaunched.unhide(ana)
        XCTAssertTrue(HiddenSendersController(directory: directory).isEmpty)
    }

    func testOnlyARealSenderIdCanBeHidden() {
        let controller = HiddenSendersController(directory: directory)
        XCTAssertFalse(controller.hide(nil, displayLabel: "Ana"), "a Margin from an older packet has no id to hide by")
        XCTAssertFalse(controller.hide("short", displayLabel: "Ana"))
        XCTAssertTrue(controller.isEmpty)
    }

    func testADamagedFileShowsEveryoneAgainAndIsNotAnError() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("hidden-senders.json"))
        XCTAssertTrue(HiddenSendersController(directory: directory).isEmpty)
    }
}
