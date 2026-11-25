import XCTest
@testable import SessionKitFeeds

/// The add flow's words while a link resolves (#5049): never a bare spinner, never jargon, and a second line on a
/// long wait.
final class SourceLinkProgressMessageTests: XCTestCase {
    func testTheLineAtEachPointOfTheWait() {
        let table: [(elapsed: TimeInterval, text: String)] = [
            (0, "Looking for something to play…"),
            (2.5, "Looking for something to play…"),
            (9.99, "Looking for something to play…"),
            (10, "Still looking. Some pages take up to a minute."),
            (41, "Still looking. Some pages take up to a minute."),
            (600, "Still looking. Some pages take up to a minute."),
        ]
        for row in table {
            XCTAssertEqual(SourceLinkProgressMessage.text(elapsed: row.elapsed), row.text, "elapsed \(row.elapsed)")
        }
    }

    func testNoLineUsesTheOldJargon() {
        for line in [SourceLinkProgressMessage.looking, SourceLinkProgressMessage.stillLooking] {
            XCTAssertFalse(line.isEmpty)
            for word in ["resolv", "source", "url"] {
                XCTAssertFalse(line.lowercased().contains(word), "\(line) says \(word)")
            }
        }
    }

    func testOnlyItsOwnLinesCountAsProgress() {
        XCTAssertTrue(SourceLinkProgressMessage.isProgress(SourceLinkProgressMessage.looking))
        XCTAssertTrue(SourceLinkProgressMessage.isProgress(SourceLinkProgressMessage.stillLooking))
        for other in [nil, "", "Source added.", "Choose the matching podcast episode.", "Resolving source link…",
                      "I found the page or feed, but not a playable podcast/audio file."] {
            XCTAssertFalse(SourceLinkProgressMessage.isProgress(other), String(describing: other))
        }
    }
}
