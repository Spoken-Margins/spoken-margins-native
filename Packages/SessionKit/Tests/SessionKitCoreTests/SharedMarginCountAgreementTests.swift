import Foundation
import SQLite3
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #3402: a friend's note that can't be heard must not wait as new forever, and every screen must give the same count.
/// Real SQLite: the Library's count comes from SQL plus a narrow read, and the rows and the offer from decoded Margins, so
/// the test that matters is that the two routes agree on the same stored notes.
final class SharedMarginCountAgreementTests: XCTestCase {
    private let imported = Date(timeIntervalSince1970: 1_700_000_000)
    private let placed = ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: 5_000, confidence: 1)

    override func tearDown() {
        WrittenMarginSpeech.useVoiceCheck(nil)
        super.tearDown()
    }

    /// This phone has no voice for anything but Latin letters.
    private func noVoiceForOtherScripts() {
        WrittenMarginSpeech.useVoiceCheck { words in !words.unicodeScalars.contains { $0.value >= 0x900 && $0.properties.isAlphabetic } }
    }

    private func layer(_ id: String = "cole", item: String = "a") -> ImportedCommentaryLayer {
        ImportedCommentaryLayer(
            id: id, itemId: item, packageDigest: "digest-\(id)", packageId: "package-\(id)",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode", durationMs: 1_800_000),
            displayLabel: "Cole", importedAt: imported, sourceResolutionStatus: .resolved, isEnabled: true
        )
    }

    private func margin(
        _ id: String, words: String, audio: String? = nil, layer: String = "cole", sender: Bool? = nil, listener: Bool? = nil
    ) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(
            id: id, layerId: layer, packageScopedId: id, createdAt: imported,
            anchorEvidence: PortableAnchorEvidence(anchorType: .text), approvedTranscript: words,
            audioPath: audio, audioDurationMs: audio == nil ? nil : 4_000, resolution: placed,
            senderReadAloud: sender, listenerReadAloud: listener
        )
    }

    private func withStore(_ body: (SQLiteSessionStore, String) throws -> Void) throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "shared-agreement-\(UUID().uuidString).sqlite").path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let store = try SQLiteSessionStore(path: path)
        try store.saveItem(Item(id: "a", title: "Title", mediaType: "text", text: "Words.", externalReference: nil, status: "ready"))
        try body(store, path)
    }

    /// The neighbouring inputs: one row per kind of Margin with no recording, plus a recording, against the two routes.
    private var table: [(margin: ImportedCommentaryInterjection, showsNew: Bool, offered: Bool, why: String)] {
        [
            (margin("voice", words: "Spoken words.", audio: "ImportedCommentary/voice.m4a"), true, true, "a recording"),
            (margin("voicePlaceholder", words: "Voice Margin at 12:34", audio: "ImportedCommentary/voicePlaceholder.m4a"), true, true, "a recording with stand-in words"),
            (margin("plain", words: "Great point."), true, true, "a note a voice can read"),
            (margin("emoji", words: "🎧🎧"), false, false, "only emoji"),
            (margin("link", words: "https://example.com/page"), false, false, "only a link"),
            (margin("blank", words: "  \n "), false, false, "blank"),
            (margin("placeholder", words: "Voice Margin at 12:34"), false, false, "a lost recording's stand-in words"),
            (margin("hindi", words: "यह बहुत अच्छा है"), false, false, "no voice on this phone"),
            (margin("mixed", words: "Listen यह सुनो"), false, false, "partly no voice on this phone"),
            (margin("off", words: "Great point.", sender: false), true, false, "reading off: met on its details sheet (#3427)"),
            (margin("offHindi", words: "यह बहुत अच्छा है", sender: false), true, false, "reading off, no voice: still met on the sheet"),
            (margin("onAgain", words: "Great point.", sender: false, listener: true), true, true, "the listener's choice beats the sender's"),
        ]
    }

    func testTheLibraryCountTheRowsAndTheOfferAgreeOnEveryKindOfNote() throws {
        noVoiceForOtherScripts()
        try withStore { store, _ in
            _ = try store.importCommentaryLayer(layer(), interjections: table.map(\.margin))
            let saved = try store.loadImportedCommentaryInterjections(layerId: "cole")
            XCTAssertEqual(saved.count, table.count)
            for row in table {
                let stored = try XCTUnwrap(saved.first { $0.id == row.margin.id })
                XCTAssertEqual(stored.showsAsNew, row.showsNew, "row, \(row.why)")
                XCTAssertEqual(SharedMarginAudio.canOffer(stored), row.offered, "offer, \(row.why)")
            }
            let shown = table.filter(\.showsNew).count
            XCTAssertEqual(try store.loadSharedMarginTallies()["a"], SharedMarginTally(total: table.count, new: shown),
                           "the SQL route counts what the rows show")

            let offered = try SharedMarginReview.entries(itemId: "a", in: store).map(\.interjection.id)
            XCTAssertEqual(Set(offered), Set(table.filter(\.offered).map(\.margin.id)), "the offer and the item screen")
            XCTAssertEqual(
                SharedPacketArrival.newMarginCount(importedIds: table.map(\.margin.id), saved: saved), offered.count,
                "the arrival says what the offer says"
            )
        }
    }

    // The issue's own example: "3 new Margins from Cole" when the offer and the item's screen say 2.
    func testTheArrivalSaysTwoWhenOneOfThreeCannotBeRead() throws {
        try withStore { store, _ in
            let ids = ["one", "two", "emoji"]
            let margins = [margin("one", words: "First."), margin("two", words: "Second."), margin("emoji", words: "🎧")]
            _ = try store.importCommentaryLayer(layer(), interjections: margins)
            let saved = try store.loadImportedCommentaryInterjections(layerId: "cole")
            let count = SharedPacketArrival.newMarginCount(importedIds: ids, saved: saved)
            XCTAssertEqual(count, 2)
            XCTAssertEqual(SharedPacketArrival.announcement(newMarginCount: count, senderName: "Cole", itemHadFriendMargins: true), "2 new Margins from Cole")
            XCTAssertEqual(try SharedMarginReview.entries(itemId: "a", in: store).count, count)
            XCTAssertEqual(SharedPacketArrival.newMarginCount(importedIds: ["emoji"], saved: saved), 0, "nothing to say about a file that added only that")
            XCTAssertEqual(SharedPacketArrival.newMarginCount(importedIds: ["one"], saved: saved), 1, "only what this import added")
        }
    }

    // Nothing is stored, so a voice downloaded later brings the note back: new, offered and counted, with no migration.
    func testAVoiceDownloadedLaterMakesTheNoteNewAgainAndNoHeardFactWasMade() throws {
        noVoiceForOtherScripts()
        try withStore { store, _ in
            _ = try store.importCommentaryLayer(layer(), interjections: [margin("hindi", words: "यह बहुत अच्छा है")])
            XCTAssertEqual(try store.loadSharedMarginTallies()["a"], SharedMarginTally(total: 1, new: 0))
            XCTAssertEqual(try SharedMarginReview.entries(itemId: "a", in: store).count, 0)
            let before = try XCTUnwrap(store.loadImportedCommentaryInterjections(layerId: "cole").first)
            XCTAssertNil(before.firstHeardAt, "not new is not heard")
            XCTAssertTrue(before.isNewToListener)

            WrittenMarginSpeech.useVoiceCheck { _ in true }
            XCTAssertEqual(try store.loadSharedMarginTallies()["a"], SharedMarginTally(total: 1, new: 1))
            XCTAssertEqual(try SharedMarginReview.entries(itemId: "a", in: store).count, 1)
            XCTAssertTrue(try XCTUnwrap(store.loadImportedCommentaryInterjections(layerId: "cole").first).showsAsNew)
        }
    }

    // The payload is what a previous build opens: reading the count writes nothing, and the record has no new key.
    func testTheCountWritesNothingToTheStoredRecord() throws {
        noVoiceForOtherScripts()
        try withStore { store, _ in
            let note = margin("emoji", words: "🎧")
            _ = try store.importCommentaryLayer(layer(), interjections: [note])
            let before = try store.loadImportedCommentaryInterjections(layerId: "cole")
            _ = try store.loadSharedMarginTallies()
            XCTAssertEqual(try store.loadImportedCommentaryInterjections(layerId: "cole"), before)
        }
    }

    // A hidden Margin is out of the count, and the note check must not subtract it a second time.
    func testAHiddenNoteIsNotSubtractedTwice() throws {
        try withStore { store, _ in
            _ = try store.importCommentaryLayer(layer(), interjections: [margin("plain", words: "Great point."), margin("emoji", words: "🎧"), margin("emoji2", words: "🎧🎧")])
            XCTAssertEqual(try store.loadSharedMarginTallies()["a"], SharedMarginTally(total: 3, new: 1))
            var hidden = HiddenSenders()
            hidden.hideMargin("emoji")
            XCTAssertEqual(try store.loadSharedMarginTallies(hiding: hidden)["a"], SharedMarginTally(total: 2, new: 1))
        }
    }

    // A heard note left the new count in the tally, so the note check must not subtract it again. The unheard plain note is
    // what makes the note check run at all; the two heard ones are what it must leave out.
    func testAHeardNoteIsLeftOutOfTheNoteCheck() throws {
        noVoiceForOtherScripts()
        try withStore { store, _ in
            _ = try store.importCommentaryLayer(layer(), interjections: [
                margin("plain", words: "Great point."), margin("heardEmoji", words: "🎧"), margin("heardHindi", words: "यह बहुत अच्छा है"),
            ])
            _ = try store.markImportedCommentaryInterjectionHeard(id: "heardEmoji", at: imported)
            _ = try store.markImportedCommentaryInterjectionHeard(id: "heardHindi", at: imported)
            XCTAssertEqual(try store.loadSharedMarginTallies()["a"], SharedMarginTally(total: 3, new: 1))
        }
    }

    // A recording is heard, whatever its words say, so the note check must leave recordings out. The plain note with no
    // recording is what makes the note check run at all.
    func testARecordingIsLeftOutOfTheNoteCheckWhateverItsWords() throws {
        noVoiceForOtherScripts()
        try withStore { store, _ in
            let recordings = [
                margin("placeholder", words: "Voice Margin at 12:34", audio: "ImportedCommentary/placeholder.m4a"),
                margin("emoji", words: "🎧", audio: "ImportedCommentary/emoji.m4a"),
                margin("hindi", words: "यह बहुत अच्छा है", audio: "ImportedCommentary/hindi.m4a"),
            ]
            _ = try store.importCommentaryLayer(layer(), interjections: [margin("plain", words: "Great point.")] + recordings)
            XCTAssertEqual(try store.loadSharedMarginTallies()["a"], SharedMarginTally(total: 4, new: 4))
            for stored in try store.loadImportedCommentaryInterjections(layerId: "cole") {
                XCTAssertTrue(stored.showsAsNew, "the row agrees: \(stored.id)")
            }
        }
    }

    // A broken payload gave no match before this read existed; the narrow read must not fail the Library on one.
    func testABrokenPayloadDoesNotFailTheCount() throws {
        try withStore { store, path in
            _ = try store.importCommentaryLayer(layer(), interjections: [margin("emoji", words: "🎧")])
            var connection: OpaquePointer?
            XCTAssertEqual(sqlite3_open(path, &connection), SQLITE_OK)
            defer { sqlite3_close(connection) }
            XCTAssertEqual(sqlite3_exec(connection, "INSERT INTO records (kind, id, payload) VALUES ('imported_commentary_interjection', 'broken', '{not json')", nil, nil, nil), SQLITE_OK)
            XCTAssertEqual(try store.loadSharedMarginTallies()["a"], SharedMarginTally(total: 1, new: 0))
        }
    }

    func testAnUnreadableNoteOnATapSaysThePlainLineAndAChoiceSaysItsOwn() {
        noVoiceForOtherScripts()
        XCTAssertEqual(SharedMarginAudio.unavailableWords(for: margin("x", words: "🎧")), "This Margin can't be read aloud on this iPhone.")
        XCTAssertEqual(SharedMarginAudio.unavailableWords(for: margin("x", words: "यह बहुत अच्छा है")), "This Margin can't be read aloud on this iPhone.")
        XCTAssertEqual(SharedMarginAudio.unavailableWords(for: margin("x", words: "Great point.", sender: false)),
                       "This Margin is set not to be read aloud. Turn reading on for it to hear it.")
        XCTAssertEqual(ReadAloudWords.footer(for: margin("x", words: "यह बहुत अच्छा है"), senderName: "Cole"), "This Margin can't be read aloud on this iPhone.")
        XCTAssertEqual(ReadAloudWords.footer(for: margin("x", words: "Great point."), senderName: "Cole"),
                       "Your phone reads this Margin aloud where it comes up, and Skim stops at it.")
    }

    func testResolveSaysCannotBeReadForANoteWithNoVoiceAndNeverStartsARender() {
        noVoiceForOtherScripts()
        let audio = SharedMarginAudio.resolve(
            margin("x", words: "यह बहुत अच्छा है"), in: layer(), voiceFile: { _ in nil },
            reading: { _ in (URL(fileURLWithPath: "/tmp/never"), false) }
        )
        XCTAssertEqual(audio, .cannotBeRead)
    }
}
