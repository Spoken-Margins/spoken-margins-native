import Foundation
import XCTest
import SessionKit
@testable import SessionKitFeeds

/// #4341, slice 3: what Connect accepts in Settings › Zotero, and the line it shows once connected.
final class ZoteroConnectionTests: XCTestCase {
    private func accepted(_ id: String, _ key: String) -> (Int, String)? {
        if case .success(let value) = ZoteroConnectionInput.validate(userID: id, apiKey: key) { return (value.userID, value.apiKey) }
        return nil
    }

    private func problem(_ id: String, _ key: String) -> ZoteroConnectionInput.Problem? {
        if case .failure(let problem) = ZoteroConnectionInput.validate(userID: id, apiKey: key) { return problem }
        return nil
    }

    func testUserIDTable() {
        let key = "P9NiFoyLeZu2bZNvvuQPDWsd"
        XCTAssertEqual(accepted("1234567", key)?.0, 1234567)
        XCTAssertEqual(accepted("  1234567\n", key)?.0, 1234567, "spaces around")
        XCTAssertEqual(accepted("userID: 1234567", key)?.0, 1234567, "copied with its label")
        XCTAssertEqual(accepted("１２３", key)?.0, nil, "full-width digits are not Zotero's")
        XCTAssertEqual(problem("", key), .userIDMissing)
        XCTAssertEqual(problem("abc", key), .userIDMissing)
        XCTAssertEqual(problem("0", key), .userIDMissing)
        XCTAssertEqual(problem("12 34", key), .userIDMissing, "two numbers: which one?")
        XCTAssertEqual(problem("-5", key), nil, "the dash is a label character; 5 is the number")
        XCTAssertEqual(problem(String(repeating: "9", count: 13), key), .userIDMissing, "too long to be an ID")
    }

    func testKeyTable() {
        XCTAssertEqual(accepted("1", " P9NiFoyLeZu2bZNvvuQPDWsd ")?.1, "P9NiFoyLeZu2bZNvvuQPDWsd", "trimmed")
        XCTAssertEqual(problem("1", ""), .keyMissing)
        XCTAssertEqual(problem("1", "   "), .keyMissing)
        XCTAssertEqual(problem("1", "P9Ni FoyLe"), .keyMissing, "one word")
        XCTAssertEqual(problem("1", "P9Ni-FoyLe"), .keyMissing, "letters and digits only")
        XCTAssertEqual(problem("1", "Ключ123"), .keyMissing, "ASCII only")
        XCTAssertEqual(problem("1", String(repeating: "a", count: 65)), .keyMissing)
    }

    func testWords() {
        XCTAssertEqual(ZoteroConnection(userID: 1, libraryName: "listener").statusLine, "Connected as listener")
        XCTAssertEqual(ZoteroConnection(userID: 1, libraryName: nil).statusLine, "Connected to Zotero")
        XCTAssertEqual(ZoteroConnection(userID: 1, libraryName: "").statusLine, "Connected to Zotero")
        XCTAssertEqual(ZoteroConnectionInput.Problem.keyMissing.message, "Enter your Zotero API key.")
        XCTAssertEqual(ZoteroConnectionInput.keysPage.host, "www.zotero.org")
    }
}
