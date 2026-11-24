import XCTest
@testable import SessionKit

final class MarginIdentityTests: XCTestCase {
    func testSplitTable() {
        let table: [(String, String?, String?)] = [
            ("s1::m1", "s1", "m1"),
            ("s1::m1::extra", "s1", "m1::extra"),
            ("a:b::c:d", "a:b", "c:d"),
            ("sé::mé", "sé", "mé"),
            ("::m1", nil, nil), ("s1::", nil, nil), ("::", nil, nil), ("", nil, nil),
            ("s1:m1", nil, nil), ("s1", nil, nil), ("s1 :: m1", "s1 ", " m1")
        ]
        for (identity, session, margin) in table {
            let parts = MarginIdentity.split(identity)
            XCTAssertEqual(parts?.sessionId, session, identity)
            XCTAssertEqual(parts?.interjectionId, margin, identity)
        }
    }

    func testMakeAndSplitAreInverseForPlainIds() {
        let identity = MarginIdentity.make(sessionId: "session-1", interjectionId: "margin-9")
        XCTAssertEqual(identity, "session-1::margin-9")
        XCTAssertEqual(MarginIdentity.split(identity)?.sessionId, "session-1")
        XCTAssertEqual(MarginIdentity.split(identity)?.interjectionId, "margin-9")
    }
}
