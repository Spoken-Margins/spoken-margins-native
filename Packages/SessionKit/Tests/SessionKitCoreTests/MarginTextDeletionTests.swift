import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// What "delete the transcript" and "delete the cleaned text" of a Margin leave behind.
///
/// The listener asks to remove the words of a Margin. The Margin list, the timeline preview and the Margin layer
/// read `displayText ?? cleanedTranscript ?? transcript`, and an export reads `cleanedTranscript ?? transcript`,
/// so every one of those fields has to go, not just one of them.
/// `testSessionQualifiedCleanupAndDeletionDoNotMutateSameIDMarginInAnotherSQLiteSession` (Mac-only target) proves
/// the delete stays inside one session but asserts only `transcript == nil` afterwards.
final class MarginTextDeletionTests: XCTestCase {
    private var paths: [String] = []

    override func tearDown() {
        for path in paths { try? FileManager.default.removeItem(atPath: path) }
        paths = []
        super.tearDown()
    }

    func testDeletingTheTranscriptRemovesEveryCopyOfTheWordsAndOffersRetranscriptionOfARecording() throws {
        let (store, engine) = try makeEngine()
        let recorded = marginRecord(sessionId: "session-A", audioPath: "interjections/A.m4a", words: "Spoken in A")
        let otherSession = marginRecord(sessionId: "session-B", audioPath: "interjections/B.m4a", words: "Spoken in B")
        try store.saveInterjection(recorded)
        try store.saveInterjection(otherSession)

        _ = try engine.deleteRepresentation(interjectionId: recorded.id, sessionId: "session-A", representation: "transcript")

        let afterDelete = try XCTUnwrap(try store.loadInterjections(sessionId: "session-A").first)
        XCTAssertNil(afterDelete.transcript)
        XCTAssertNil(afterDelete.cleanedTranscript, "the cleaned copy is the same words")
        XCTAssertNil(afterDelete.displayText, "the Margin list shows displayText, so it must not keep showing the deleted words")
        XCTAssertEqual(afterDelete.transcriptionStatus, "failed",
                       "no work is queued, so it must not read as pending (#942); the recording is still there for Retry")
        var unchangedApartFromText = afterDelete
        unchangedApartFromText.transcript = recorded.transcript
        unchangedApartFromText.cleanedTranscript = recorded.cleanedTranscript
        unchangedApartFromText.displayText = recorded.displayText
        unchangedApartFromText.transcriptionStatus = recorded.transcriptionStatus
        XCTAssertEqual(unchangedApartFromText, recorded, "nothing but the words and their status changes: audio, anchor and state stay")
        XCTAssertEqual(try store.loadInterjections(sessionId: "session-B").first, otherSession,
                       "the Margin with the same id in another session keeps all of its text")
    }

    func testDeletingTheTranscriptOfAWrittenMarginMarksItFailedBecauseThereIsNothingToTranscribeAgain() throws {
        let (store, engine) = try makeEngine()
        var written = marginRecord(sessionId: "session-A", audioPath: nil, words: "Typed words")
        written.captureKind = .written
        written.audioStatus = "discarded"
        try store.saveInterjection(written)

        _ = try engine.deleteRepresentation(interjectionId: written.id, sessionId: "session-A", representation: "transcript")

        let afterDelete = try XCTUnwrap(try store.loadInterjections(sessionId: "session-A").first)
        XCTAssertNil(afterDelete.transcript)
        XCTAssertNil(afterDelete.cleanedTranscript)
        XCTAssertNil(afterDelete.displayText)
        XCTAssertEqual(afterDelete.transcriptionStatus, "failed")
    }

    func testDeletingTheCleanedTextFallsBackToTheTranscriptAndKeepsIt() throws {
        let (store, engine) = try makeEngine()
        let recorded = marginRecord(sessionId: "session-A", audioPath: "interjections/A.m4a", words: "Spoken in A")
        try store.saveInterjection(recorded)

        _ = try engine.deleteRepresentation(interjectionId: recorded.id, sessionId: "session-A", representation: "cleanedTranscript")

        let afterDelete = try XCTUnwrap(try store.loadInterjections(sessionId: "session-A").first)
        XCTAssertNil(afterDelete.cleanedTranscript)
        XCTAssertEqual(afterDelete.transcript, "Spoken in A original")
        XCTAssertEqual(afterDelete.displayText, "Spoken in A original", "the list shows the raw words once the cleaned copy is gone")
        XCTAssertEqual(afterDelete.transcriptionStatus, "transcribed")
    }

    /// The point of deleting a transcript: the words must not leave the phone in a summary or share afterwards.
    func testAnExportAfterDeletingTheTranscriptCarriesNoneOfTheDeletedWords() throws {
        let (store, engine) = try makeEngine()
        let recorded = marginRecord(sessionId: "session-A", audioPath: "interjections/A.m4a", words: "Private")
        try store.saveInterjection(recorded)
        func exportedWords() throws -> String {
            let export = try engine.buildExport(options: ExportOptions(
                sessionId: "session-A", includeFullText: false, includeReference: false,
                includeListeningMap: false, includeInterjections: true, includeTurns: false
            ))
            return SessionExportMarkdownRenderer.render(export)
        }
        XCTAssertTrue(try exportedWords().contains("Private cleaned"), "fixture check: the words are in the export before the delete")

        _ = try engine.deleteRepresentation(interjectionId: recorded.id, sessionId: "session-A", representation: "transcript")

        let afterDelete = try exportedWords()
        XCTAssertFalse(afterDelete.contains("Private original"))
        XCTAssertFalse(afterDelete.contains("Private cleaned"))
    }

    // MARK: Fixtures

    private func makeEngine() throws -> (SQLiteSessionStore, SessionEngine) {
        let path = FileManager.default.temporaryDirectory.appending(path: "sessionkit-margin-text-\(UUID().uuidString).sqlite").path
        paths.append(path)
        let store = try SQLiteSessionStore(path: path)
        let item = Item(id: "item-text", title: "Text", mediaType: "text", text: "Source.", externalReference: nil, status: "ready")
        try store.saveItem(item)
        for id in ["session-A", "session-B"] {
            try store.saveSession(Session(
                id: id, itemId: item.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS,
                currentTargetId: item.id, position: Position(), completionPercent: 0, playbackRate: 1
            ))
        }
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "phone-tablet-online", displayName: "Phone / Tablet Online", capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "interjection": ["record_audio", "capture_text_anchor"],
            ]),
            repository: store
        )
        return (store, engine)
    }

    /// The same Margin id in both sessions, as the app numbers them.
    private func marginRecord(sessionId: String, audioPath: String?, words: String) -> Interjection {
        Interjection(
            id: "same-margin-id", itemId: "item-text", sessionId: sessionId, targetType: .item, targetId: "item-text",
            createdAt: Date(timeIntervalSince1970: 1), roughPercent: 0,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 7, anchorBefore: "Source.", anchorAfter: ""),
            audioPath: audioPath, audioStatus: audioPath == nil ? "discarded" : "saved", transcriptionStatus: "transcribed",
            transcript: "\(words) original", cleanedTranscript: "\(words) cleaned", displayText: "\(words) cleaned", status: "active"
        )
    }
}
