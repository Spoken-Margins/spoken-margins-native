import Foundation
import XCTest
import SessionKit

final class KeptPackageNoticesTests: XCTestCase {
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "kept-package-notices-\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func notices() -> KeptPackageNotices {
        KeptPackageNotices(defaults: UserDefaults(suiteName: suiteName)!)
    }

    private let day: TimeInterval = 24 * 60 * 60
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testAFileIsAnnouncedUntilItIsNotedAndThenOncePerAppVersion() {
        XCTAssertTrue(notices().shouldAnnounce(payloadID: "a", appVersion: "0.1 (35)"))
        notices().noteKept(payloadID: "a", appVersion: "0.1 (35)", now: start)
        XCTAssertFalse(notices().shouldAnnounce(payloadID: "a", appVersion: "0.1 (35)"), "same build: quiet on the next launch")
        XCTAssertTrue(notices().shouldAnnounce(payloadID: "a", appVersion: "0.1 (36)"), "a new build tells again")
        XCTAssertTrue(notices().shouldAnnounce(payloadID: "b", appVersion: "0.1 (35)"), "another file is its own")
    }

    func testAKeptFileExpiresThirtyDaysAfterItWasFirstKept() {
        notices().noteKept(payloadID: "a", appVersion: "v1", now: start)
        notices().noteKept(payloadID: "a", appVersion: "v2", now: start.addingTimeInterval(20 * day))
        XCTAssertFalse(notices().hasExpired(payloadID: "a", now: start.addingTimeInterval(29 * day)))
        XCTAssertTrue(notices().hasExpired(payloadID: "a", now: start.addingTimeInterval(31 * day)),
                      "telling again in a later version does not restart the 30 days")
    }

    func testAFileNeverKeptDoesNotExpireAndForgetClearsIt() {
        XCTAssertFalse(notices().hasExpired(payloadID: "a", now: start.addingTimeInterval(400 * day)))
        notices().noteKept(payloadID: "a", appVersion: "v1", now: start)
        notices().forget(payloadID: "a")
        XCTAssertTrue(notices().shouldAnnounce(payloadID: "a", appVersion: "v1"))
        XCTAssertFalse(notices().hasExpired(payloadID: "a", now: start.addingTimeInterval(400 * day)))
    }
}
