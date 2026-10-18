import Foundation
import XCTest
@testable import SessionKit

final class ImportInboxReasonTests: XCTestCase {
    func testAPlainSentencePassesThrough() {
        XCTAssertEqual(ImportInboxReason.plain("The shared link did not return a readable PDF."), "The shared link did not return a readable PDF.")
        XCTAssertEqual(ImportInboxReason.plain("  The page has no text.\n"), "The page has no text.")
    }

    func testCodeNamesAndDumpsBecomeTheFallback() {
        let raws = [
            "",
            "   ",
            "browser_text_item_id",
            "persistenceFailed(\"database_unavailable\")",
            "persistence_failed: browser_text_item_id",
            "The operation couldn’t be completed. (SessionKit.SessionKitError error 3.)",
            "Error Domain=NSCocoaErrorDomain Code=4 \"No such file\" UserInfo={NSFilePath=/x}",
            "invalidPayload"
        ]
        for raw in raws {
            XCTAssertEqual(ImportInboxReason.plain(raw), ImportInboxReason.fallback, raw)
        }
    }
}
