import Foundation
import XCTest
import SessionKit

final class SharedPacketInboxMemoryTests: XCTestCase {
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "shared-packet-inbox-memory-\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func memory() -> SharedPacketInboxMemory {
        SharedPacketInboxMemory(defaults: UserDefaults(suiteName: suiteName)!)
    }

    func testAShownFileIsRememberedAcrossLaunchesUntilItLeavesTheInbox() {
        XCTAssertFalse(memory().wasShown(payloadID: "a"), "a new file has not been shown")
        memory().noteShown(payloadID: "a")
        memory().noteShown(payloadID: "b")
        XCTAssertTrue(memory().wasShown(payloadID: "a"), "a fresh instance stands for the next launch")
        XCTAssertFalse(memory().wasShown(payloadID: "c"))

        memory().forgetAll(except: ["b"])
        XCTAssertFalse(memory().wasShown(payloadID: "a"), "imported or cancelled: forgotten")
        XCTAssertTrue(memory().wasShown(payloadID: "b"))

        memory().forgetAll(except: [])
        XCTAssertFalse(memory().wasShown(payloadID: "b"))
        XCTAssertNil(UserDefaults(suiteName: suiteName)!.object(forKey: "sharedPacketInboxShown.v1"), "nothing left behind")
    }
}
