import Combine
import SessionKit
import XCTest
@testable import SpokenMarginsApp

/// The screens' wrapper over the hidden-senders list passes the hide and show calls through and publishes the result
/// (#2846). The rules and the file are host-tested in SessionKit (`HiddenSendersKeeperTests`, #318).
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

    /// The screens redraw from `current`, so every hide and show of a Margin must publish it.
    func testHidingAndShowingAMarginPublishesTheList() {
        let controller = HiddenSendersController(directory: directory)
        var published: [Bool] = []
        let sink = controller.$current.dropFirst().sink { published.append($0.isMarginHidden("margin-1")) }
        defer { sink.cancel() }

        XCTAssertTrue(controller.hideMargin("margin-1", senderLabel: "Ana", text: "A few words"))
        controller.unhideMargin("margin-1")
        controller.unhideMargin("margin-1") // nothing changed, so nothing is published

        XCTAssertEqual(published, [true, false])
    }
}
