import XCTest
@testable import SessionKit

/// #3108: a spoken note is an ordinary Library item with a free-text media type, so the previous build still opens the
/// database and shows the row as a text item.
final class SpokenNoteItemTests: XCTestCase {
    private func note(id: String = "n1", sentences: [String] = []) -> SpokenNote {
        var note = SpokenNote(id: id)
        let take = SpokenNoteTake(
            id: "t1", audioFileName: "t1.m4a", durationMs: 5000, createdAt: Date(timeIntervalSince1970: 0),
            sentences: sentences.enumerated().map { SpokenNoteSentence(text: $1, startMs: $0 * 1000, endMs: $0 * 1000 + 900) })
        note.appendTake(take)
        return note
    }

    func testTheItemCarriesTheTranscriptAndAReferenceBackToTheNote() {
        let item = SpokenNoteItem.makeItem(note: note(sentences: ["First idea.", "Second idea."]), createdAt: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(item.id, "spoken-note-n1")
        XCTAssertEqual(item.mediaType, "spoken_note")
        XCTAssertEqual(item.text, "First idea. Second idea.", "no dictated text is dropped")
        XCTAssertEqual(item.externalReference, "note://n1")
        XCTAssertEqual(item.externalReferenceType, "spoken_note")
        XCTAssertEqual(item.status, "ready")
        XCTAssertEqual(item.title, "Spoken note")
        XCTAssertEqual(item.createdAt, Date(timeIntervalSince1970: 100))
    }

    func testANoteWithoutATranscriptYetStillMakesAnItem() {
        let item = SpokenNoteItem.makeItem(note: note(), createdAt: Date())
        XCTAssertEqual(item.text, "")
        XCTAssertEqual(SpokenNoteItem.makeItem(note: SpokenNote(id: "empty"), createdAt: Date()).text, "")
    }

    func testTheSameNoteAlwaysMakesTheSameItemId() {
        let a = SpokenNoteItem.makeItem(note: note(), createdAt: Date(timeIntervalSince1970: 1))
        let b = SpokenNoteItem.makeItem(note: note(sentences: ["More."]), createdAt: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(a.id, b.id)
        XCTAssertNotEqual(a.id, SpokenNoteItem.makeItem(note: note(id: "n2"), createdAt: Date()).id)
    }

    func testATitleIsTrimmedAndABlankOneFallsBackToTheDefault() {
        XCTAssertEqual(SpokenNoteItem.makeItem(note: note(), title: "  Walk home idea ", createdAt: Date()).title, "Walk home idea")
        for blank in ["", "   ", "\n\t"] {
            XCTAssertEqual(SpokenNoteItem.makeItem(note: note(), title: blank, createdAt: Date()).title, "Spoken note", "[\(blank)]")
        }
    }

    func testTheNoteIdComesBackFromTheReferenceAndOnlyFromASpokenNote() {
        let item = SpokenNoteItem.makeItem(note: note(id: "abc-123"), createdAt: Date())
        XCTAssertEqual(SpokenNoteItem.noteId(of: item), "abc-123")
        XCTAssertEqual(SpokenNoteItem.noteId(fromReference: "note://abc"), "abc")

        XCTAssertNil(SpokenNoteItem.noteId(fromReference: nil))
        XCTAssertNil(SpokenNoteItem.noteId(fromReference: ""))
        XCTAssertNil(SpokenNoteItem.noteId(fromReference: "note://"), "an empty id names no note")
        XCTAssertNil(SpokenNoteItem.noteId(fromReference: "https://example.com/note://x"))
        XCTAssertNil(SpokenNoteItem.noteId(fromReference: "Note://abc"), "the prefix is exact")

        var other = item
        other.mediaType = "text"
        XCTAssertNil(SpokenNoteItem.noteId(of: other), "a text item that happens to hold a note:// reference is not a note")
    }

    func testMediaTypeMatchingIgnoresCase() {
        XCTAssertTrue(SpokenNoteItem.isSpokenNote(mediaType: "spoken_note"))
        XCTAssertTrue(SpokenNoteItem.isSpokenNote(mediaType: "Spoken_Note"))
        for other in ["", "spoken note", "spoken_notes", "text", "guided_tour"] {
            XCTAssertFalse(SpokenNoteItem.isSpokenNote(mediaType: other), other)
        }
    }

    func testTheRowSaysSpokenNoteAndShowsAMicrophone() {
        for type in ["spoken_note", "Spoken_Note"] {
            XCTAssertEqual(
                LibraryRowWording.kindLabel(mediaType: type, sourceReference: "note://n1", sourceReferenceType: "spoken_note", usesNewReader: false),
                "Spoken note")
            XCTAssertEqual(LibraryItemRow(id: "i", title: "T", status: "s", canDelete: true, mediaType: type).mediaSymbol, "mic")
            XCTAssertEqual(LibraryItemRow(id: "i", title: "T", status: "s", canDelete: true, mediaType: type, hasNativeAudio: true).mediaSymbol, "mic")
        }
        XCTAssertEqual(LibraryItemRow(id: "i", title: "T", status: "s", canDelete: true, mediaType: "text").mediaSymbol, "doc.text")
    }

    func testTheItemSurvivesTheDatabaseShapeTheLastBuildReads() throws {
        // An older build decodes `Item` from this JSON; every key the note item sets is one it already knows.
        let item = SpokenNoteItem.makeItem(note: note(sentences: ["Hello."]), createdAt: Date(timeIntervalSince1970: 5))
        let data = try JSONEncoder().encode(item)
        let keys = Set(try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys)
        let shipped = Set(["id", "title", "mediaType", "text", "externalReference", "externalReferenceType", "status", "createdAt", "sourceCompletedAt"])
        XCTAssertTrue(keys.isSubset(of: shipped), "unexpected keys: \(keys.subtracting(shipped))")
        XCTAssertEqual(try JSONDecoder().decode(Item.self, from: data), item)
    }

    func testANoteIsNeverNarratedInASyntheticVoice() {
        let withText = SpokenNoteItem.makeItem(note: note(sentences: ["Hello."]), createdAt: Date())
        let withoutText = SpokenNoteItem.makeItem(note: note(), createdAt: Date())
        for item in [withText, withoutText] {
            XCTAssertTrue(LibraryAudioPreparationAdmission.playsItsOwnAudio(item), "the recording is its audio")
            XCTAssertFalse(LibraryAudioPreparationAdmission.admitsAutomatically(item, sessions: []), "no While Charging narration")
            XCTAssertFalse(LibraryRowBuilder.shouldPrewarmTextAudio(for: item), "no opening-buffer narration")
            XCTAssertTrue(PreparedNarrationFallback.isAudioFirst(item), "Play never falls back to reading the transcript")
        }
        var text = withText
        text.mediaType = "text"
        XCTAssertFalse(LibraryAudioPreparationAdmission.playsItsOwnAudio(text), "an ordinary text item is still narrated")
    }

    func testTheLibraryFilesANoteUnderTextLikeTheGuidedTour() {
        XCTAssertEqual(
            LibraryRowWording.contentType(mediaType: "spoken_note", sourceReference: "note://n1", sourceReferenceType: "spoken_note"),
            .text)
    }
}
