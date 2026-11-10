import Foundation
import XCTest
@testable import SessionKit

/// The sentence that goes out beside a share link (#3787).
final class ShareLinkMessageTests: XCTestCase {
    func testTheSentenceIsTheOwnersWordsAndSaysNothingToInstall() {
        XCTAssertEqual(
            ShareLinkMessage.sentence,
            "I left you a voice note on a podcast. Tap the link, then Play. It works in your browser, nothing to install."
        )
    }

    /// The key is the link's `#` part. Losing it, or any other part of the address, would send a link that opens nothing.
    func testTheTextCarriesTheWholeAddressAfterTheSentence() throws {
        let key = ShareLinkSealing.Key.random()
        let base = URL(string: "https://spokenmargins.com/l/0123456789abcdef0123456789abcdef")!
        let link = try XCTUnwrap(ShareLinkSealing.linkURL(base: base, key: key))
        XCTAssertNotNil(link.fragment)

        let text = ShareLinkMessage.text(for: link)

        XCTAssertEqual(text, "\(ShareLinkMessage.sentence)\n\n\(link.absoluteString)")
        // A friend's phone reads the address back out of the text and gets the same link.
        let found = text.split(whereSeparator: \.isNewline).last.flatMap { URL(string: String($0)) }
        XCTAssertEqual(found, link)
        XCTAssertNotNil(ShareLinkURL(url: try XCTUnwrap(found)))
    }
}
