import XCTest
@testable import SessionKit

/// #1578: a text item that plays from its pre-rendered edition (`transcript_backed_media`) still offers
/// More > Text, because the item's text and a playhead mapped onto it are right there.
final class PlaybackTextReaderAvailabilityTests: XCTestCase {
    func testTable() {
        let text = TargetType.itemTextTTS.rawValue
        let media = TargetType.transcriptBackedMedia.rawValue
        let rows: [(name: String, target: String?, itemText: String, nativeAudio: Bool, available: Bool)] = [
            ("live speech over the text", text, "Some words.", false, true),
            ("pre-rendered edition of a text item, the owner's case", media, "Some words.", false, true),
            ("pre-rendered edition, text with surrounding whitespace", media, "\n  Some words.  \n", false, true),
            ("pre-rendered edition with no text stored", media, "", false, false),
            ("pre-rendered edition with only whitespace", media, " \n\t ", false, false),
            ("a podcast recording", media, "", true, false),
            ("a podcast recording whose item carries text", media, "Show notes.", true, false),
            ("browser-owned media", TargetType.browserOwnedMedia.rawValue, "Some words.", false, false),
            ("a spoken summary turn", TargetType.summaryTurnTTS.rawValue, "Some words.", false, false),
            ("a spoken assistant turn", TargetType.assistantTurnTTS.rawValue, "Some words.", false, false),
            ("nothing playing", nil, "Some words.", false, false),
            ("an unknown target type", "something_else", "Some words.", false, false)
        ]
        for row in rows {
            XCTAssertEqual(
                PlaybackTextReaderAvailability.isAvailable(
                    targetType: row.target, itemText: row.itemText, itemHasNativeAudio: row.nativeAudio
                ),
                row.available,
                row.name
            )
        }
    }
}
