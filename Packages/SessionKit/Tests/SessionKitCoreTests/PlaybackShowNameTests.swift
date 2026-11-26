import XCTest
@testable import SessionKit

/// The show line and compact title on the Now screen draw a readable name, never an item's internal reference.
final class PlaybackShowNameTests: XCTestCase {
    /// #5345: a spoken note's Library row has no source name, so its source title falls back to the item's
    /// `note://<id>` reference, and the player drew that id under the title (VoiceOver read it out too).
    func testShowNameNeverDrawsAnInternalReference() {
        let note = SpokenNoteItem.makeItem(
            note: SpokenNote(id: "97960ccd-4faa-4883-ae72-a829f0cb55f6"), createdAt: Date(timeIntervalSince1970: 0))
        // The row builder's fallback: no source title, so the reference stands in.
        let rowSourceTitle = note.sourceTitle ?? note.externalReference
        XCTAssertEqual(rowSourceTitle, "note://97960ccd-4faa-4883-ae72-a829f0cb55f6")
        XCTAssertNil(PlaybackTitleMode.showName(sourceTitle: rowSourceTitle))
        XCTAssertEqual(PlaybackTitleMode.compactLine(title: note.title, sourceName: rowSourceTitle), note.title)
        XCTAssertFalse(PlaybackTitleMode.compact.voiceControlNames(title: note.title, sourceName: rowSourceTitle)
            .contains { $0.contains("note://") })

        let rows: [(String?, String?)] = [
            ("The Show", "The Show"),
            ("  The Show \n", "The Show"),
            ("Episode 12: Café", "Episode 12: Café"),
            ("A show: https://example.com", "A show: https://example.com"), // a name with words keeps its words
            ("[[Daily Notes]]", "Daily Notes"),
            ("[[  ]]", nil),
            (nil, nil),
            ("", nil),
            ("   ", nil),
            ("note://abc", nil),
            ("NOTE://abc", nil),
            ("note://", nil),
            ("bundled://welcome.json", nil),
            ("file:///private/var/mobile/a.pdf", nil),
            ("spokenmargins://item/1", nil),
            ("https://www.example.com/feed.xml", "example.com"),
            ("HTTPS://Pod.Example.com/ep/1", "pod.example.com"),
            ("www.example.org/a", "example.org"),
            (String(repeating: "Long show ", count: 40), String(repeating: "Long show ", count: 40).trimmingCharacters(in: .whitespaces)),
        ]
        for (input, expected) in rows {
            XCTAssertEqual(PlaybackTitleMode.showName(sourceTitle: input), expected, "input: \(String(describing: input))")
            let drawn = PlaybackTitleMode.compactLine(title: "Title", sourceName: input)
            if input?.contains(" ") != true {
                XCTAssertFalse(drawn.contains("://"), "compact line drew an address for \(String(describing: input))")
            }
        }
    }
}
