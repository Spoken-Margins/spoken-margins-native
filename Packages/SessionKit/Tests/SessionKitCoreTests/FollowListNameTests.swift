import XCTest
@testable import SessionKit

/// #4046: what a typed list name can be. A table of neighbouring inputs: case, whitespace, Unicode normalisation,
/// punctuation, empty, very long, and look-alikes.
final class FollowListNameTests: XCTestCase {
    private let existing = [FollowList(id: "news", name: "News", createdAt: Date(timeIntervalSince1970: 0))]

    func testNameTable() {
        let nfc = "Caf\u{00E9}"
        let nfd = "Cafe\u{0301}"
        let forty = String(repeating: "a", count: 40)
        let cases: [(raw: String, expected: FollowListName.Outcome)] = [
            ("Tech", .valid("Tech")),
            ("  Tech  ", .valid("Tech")),
            ("Deep\n  Dives", .valid("Deep Dives")),
            ("Deep\tDives", .valid("Deep Dives")),
            ("Long\u{00A0}reads", .valid("Long reads")),
            ("", .invalid(.empty)),
            ("   \n\t ", .invalid(.empty)),
            ("Tech, AI", .invalid(.containsCommaOrSlash)),
            ("Tech/AI", .invalid(.containsCommaOrSlash)),
            ("/News", .invalid(.containsCommaOrSlash)),
            (",\u{0301}", .invalid(.containsCommaOrSlash)),         // a comma with a combining mark is still a comma
            ("Tech,\u{0301}AI", .invalid(.containsCommaOrSlash)),
            ("a/\u{FE0F}b", .invalid(.containsCommaOrSlash)),
            ("Tech\u{FF0C}AI", .valid("Tech\u{FF0C}AI")),   // fullwidth comma: OPML does not split on it
            (forty, .valid(forty)),
            (forty + "a", .invalid(.tooLong)),
            ("🎧", .valid("🎧")),
            (String(repeating: "🎧", count: 40), .valid(String(repeating: "🎧", count: 40))),
            (String(repeating: "🎧", count: 41), .invalid(.tooLong)),
            (nfc, .valid(nfc)),
            (nfd, .valid(nfd)),
            ("news", .invalid(.duplicate(existingName: "News"))),
            ("NEWS", .invalid(.duplicate(existingName: "News"))),
            ("  News ", .invalid(.duplicate(existingName: "News"))),
            ("Néws", .invalid(.duplicate(existingName: "News"))),
            ("News 2", .valid("News 2")),
            ("Newss", .valid("Newss")),
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(FollowListName.validate(raw, existing: existing), expected, "input: \(raw.debugDescription)")
        }
    }

    func testNFCAndNFDAreTheSameName() {
        let list = FollowList(id: "cafe", name: "Caf\u{00E9}", createdAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(FollowListName.validate("Cafe\u{0301}", existing: [list]), .invalid(.duplicate(existingName: "Café")))
        XCTAssertTrue(FollowListName.sameName("Caf\u{00E9}", "CAFE\u{0301}"))
    }

    func testRenamingAListMayKeepItsOwnNameOrChangeItsCase() {
        XCTAssertEqual(FollowListName.validate("News", existing: existing, renaming: "news"), .valid("News"))
        XCTAssertEqual(FollowListName.validate("NEWS", existing: existing, renaming: "news"), .valid("NEWS"))
        XCTAssertEqual(FollowListName.validate("News", existing: existing, renaming: "other"), .invalid(.duplicate(existingName: "News")))
    }

    func testTheCommaAndSlashProblemComesBeforeLengthAndDuplicates() {
        XCTAssertEqual(FollowListName.validate(String(repeating: "a", count: 50) + "/", existing: existing), .invalid(.containsCommaOrSlash))
    }

    func testMessagesAreTheDesignsStrings() {
        XCTAssertEqual(FollowListName.Problem.containsCommaOrSlash.message, "A list name can’t contain a comma or a slash.")
        XCTAssertEqual(FollowListName.Problem.duplicate(existingName: "News").message, "You already have a list called News.")
    }

    func testChipOrderIsAlphabeticalIgnoringCaseWithIdTieBreak() {
        let lists = ["zebra", "Apple", "banana", "apple"].enumerated().map {
            FollowList(id: "id\($0.offset)", name: $0.element, createdAt: Date(timeIntervalSince1970: 0))
        }
        XCTAssertEqual(FollowListName.chipOrder(lists).map(\.name), ["Apple", "apple", "banana", "zebra"])
    }
}
