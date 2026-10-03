import XCTest
@testable import SessionKit

/// #171: a note's link reopens its Margin; anything else that looks similar is refused.
final class MarginDeepLinkTests: XCTestCase {
    func testBuildsTheLinkTheNoteCarries() {
        let link = MarginDeepLink(sessionId: "session-item-a-1F2E", marginId: "ij-003")
        XCTAssertEqual(link.url.absoluteString, "spokenmargins://margin?session=session-item-a-1F2E&margin=ij-003")
    }

    func testParsesWhatItBuildsIncludingIdsThatNeedEscaping() throws {
        for (session, margin) in [("session-item-a-1F2E", "ij-003"), ("session-item: \"x\"-9&9", "ij-written-ABC=1"), ("s", "m")] {
            let link = MarginDeepLink(sessionId: session, marginId: margin)
            XCTAssertEqual(MarginDeepLink(url: link.url), link, link.url.absoluteString)
        }
        XCTAssertEqual(
            MarginDeepLink(url: try XCTUnwrap(URL(string: "SpokenMargins://margin/?margin=ij-001&session=session-a"))),
            MarginDeepLink(sessionId: "session-a", marginId: "ij-001")
        )
    }

    func testRejectsMalformedLinks() throws {
        let rejected = [
            "https://margin?session=a&margin=b",
            "spokenmargins://listening-edition?session=a&margin=b",
            "spokenmargins://margin/extra?session=a&margin=b",
            "spokenmargins://margin?session=a",
            "spokenmargins://margin?margin=b",
            "spokenmargins://margin?session=&margin=b",
            "spokenmargins://margin?session=a&margin=",
            "spokenmargins://margin?session=a&session=c&margin=b",
            "spokenmargins://margin?session=a&margin=b&margin=c",
            "spokenmargins://margin?session=a%0Ab&margin=c",
            "spokenmargins://margin?session=%20%20&margin=c",
            "spokenmargins://margin",
            "spokenmargins://margin?session=\(String(repeating: "a", count: 401))&margin=b",
        ]
        for string in rejected {
            XCTAssertNil(MarginDeepLink(url: try XCTUnwrap(URL(string: string), string)), string)
        }
    }
}
