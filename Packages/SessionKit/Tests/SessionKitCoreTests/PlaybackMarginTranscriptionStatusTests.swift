import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

final class PlaybackMarginTranscriptionStatusTests: XCTestCase {
    func testPersistedPendingVoiceMarginProducesStatus() throws {
        try withStore { store, _, _ in
            try store.saveInterjection(note("pending", transcription: "pending"))
            let result = present(try store.loadInterjections(sessionId: "A-current"))
            XCTAssertEqual(result.pendingCount, 1)
            XCTAssertEqual(result.attentionCount, 0)
            XCTAssertEqual(result.text, "1 transcript pending")
            XCTAssertEqual(result.accessibilityLabel, "1 Margin transcript pending")
        }
    }

    func testSelectedItemMustBeThePlayingItemAndASessionMustExist() throws {
        try withStore { store, _, _ in
            try store.saveInterjection(note("pending", transcription: "pending"))
            let notes = try store.loadInterjections(sessionId: "A-current")
            for (selected, playing, session) in [
                ("B", Optional("A"), Optional("A-current")),
                ("A", nil, Optional("A-current")),
                ("A", Optional("A"), nil)
            ] {
                let result = PlaybackMarginTranscriptionStatus(
                    selectedItemId: selected, playingItemId: playing, sessionId: session, interjections: notes)
                XCTAssertNil(result.text, "\(selected)/\(String(describing: playing))/\(String(describing: session))")
                XCTAssertEqual(result.pendingCount, 0)
            }
        }
    }

    func testCrossedItemAndOlderSessionRowsCannotContributeEvenWithSameBareID() throws {
        try withStore { store, _, _ in
            try store.saveInterjection(note("same", transcription: "pending", session: "A-older"))
            try store.saveInterjection(note("same", transcription: "failed", item: "B", session: "B-current"))
            // Real SQLite permits a row's item ID to disagree with its session's item.
            try store.saveInterjection(note("crossed", transcription: "failed", item: "B"))
            try store.saveInterjection(note("same", transcription: "transcribed"))
            let all = try ["A-current", "A-older", "B-current"].flatMap { try store.loadInterjections(sessionId: $0) }
            let result = present(all)
            XCTAssertEqual(result.pendingCount, 0)
            XCTAssertEqual(result.attentionCount, 0)
            XCTAssertNil(result.text)
        }
    }

    func testWrittenDeletedReadyLegacyReadyAndUnknownStatesDoNotBecomeWork() throws {
        try withStore { store, _, _ in
            var written = note("written", transcription: "pending")
            written.captureKind = .written
            var deleted = note("deleted", transcription: "failed")
            deleted.status = "deleted"
            for row in [written, deleted,
                        note("ready", transcription: "transcribed"),
                        note("legacy", transcription: "complete"),
                        note("unknown", transcription: "deferred")] {
                try store.saveInterjection(row)
            }
            let result = present(try store.loadInterjections(sessionId: "A-current"))
            XCTAssertNil(result.text)
            XCTAssertNil(result.accessibilityLabel)
        }
    }

    func testPendingWithoutRecordingMetadataNeedsAttentionInsteadOfPromisingWork() throws {
        try withStore { store, _, _ in
            var noPath = note("no-path", transcription: "pending")
            noPath.audioPath = nil
            var missing = note("missing", transcription: "pending")
            missing.audioStatus = "missing"
            for row in [noPath, missing] { try store.saveInterjection(row) }
            let result = present(try store.loadInterjections(sessionId: "A-current"))
            XCTAssertEqual(result.pendingCount, 0)
            XCTAssertEqual(result.attentionCount, 2)
            XCTAssertEqual(result.text, "2 Margins need attention")
        }
    }

    func testFailedAndPendingCountsHaveCompactCopyAndCompleteAccessibilityWords() throws {
        try withStore { store, _, _ in
            for row in [note("p1", transcription: "pending"), note("p2", transcription: "pending"),
                        note("f1", transcription: "failed")] { try store.saveInterjection(row) }
            let result = present(try store.loadInterjections(sessionId: "A-current"))
            XCTAssertEqual(result.pendingCount, 2)
            XCTAssertEqual(result.attentionCount, 1)
            XCTAssertEqual(result.text, "2 transcripts pending · 1 needs attention")
            XCTAssertEqual(result.accessibilityLabel, "2 Margin transcripts pending. 1 Margin needs attention")
        }
    }

    func testReadyAndUnknownStatesStayExcludedButLiveRetryOutranksStaleMissingMetadata() throws {
        try withStore { store, _, _ in
            for status in ["transcribed", "complete", "deferred", "pending", "failed"] {
                var row = note(status, transcription: status)
                row.audioStatus = "missing"
                try store.saveInterjection(row)
            }
            let result = present(try store.loadInterjections(sessionId: "A-current"), isRetrying: { _ in true })
            XCTAssertEqual(result.pendingCount, 2)
            XCTAssertEqual(result.attentionCount, 0)
            XCTAssertEqual(result.text, "2 transcripts pending")
        }
    }

    func testRetryUsesTheSuppliedPerNoteActivityAndRealCompletionClearsTheTag() throws {
        try withStore { store, engine, _ in
            try store.saveInterjection(note("same", transcription: "transcribed"))
            try store.saveInterjection(note("same", transcription: "failed", session: "A-older"))
            _ = try engine.deleteRepresentation(interjectionId: "same", sessionId: "A-current", representation: "transcript")
            var rows = try store.loadInterjections(sessionId: "A-current")
            XCTAssertEqual(present(rows).text, "1 Margin needs attention")
            let otherSessionRetry = present(rows, isRetrying: { $0.sessionId == "A-older" && $0.id == "same" })
            XCTAssertEqual(otherSessionRetry.attentionCount, 1)
            XCTAssertEqual(otherSessionRetry.pendingCount, 0)

            engine.transcriptionRequested(interjectionId: "same", sessionId: "A-current")
            rows = try store.loadInterjections(sessionId: "A-current")
            XCTAssertEqual(rows.first?.transcriptionStatus, "failed", "retry activity precedes the persisted completion")
            let retrying = present(rows, isRetrying: { $0.sessionId == "A-current" && $0.id == "same" })
            XCTAssertEqual(retrying.pendingCount, 1)
            XCTAssertEqual(retrying.attentionCount, 0)

            _ = try engine.transcriptionCompleted(interjectionId: "same", sessionId: "A-current", transcript: "Again")
            rows = try store.loadInterjections(sessionId: "A-current")
            XCTAssertEqual(rows.first?.transcript, "Again")
            XCTAssertNil(present(rows).text)
            XCTAssertEqual(try store.loadInterjections(sessionId: "A-older").first?.transcriptionStatus, "failed")
        }
    }

    func testReopeningSettlesAnOrphanFromPendingToAttentionWithoutInventingAWorker() throws {
        try withStore { store, _, path in
            try store.saveInterjection(note("orphan", transcription: "pending"))
            XCTAssertEqual(present(try store.loadInterjections(sessionId: "A-current")).pendingCount, 1)
            let reopened = try SQLiteSessionStore(path: path)
            XCTAssertEqual(try reopened.settleOrphanedTranscriptions(), 1)
            let after = present(try reopened.loadInterjections(sessionId: "A-current"))
            XCTAssertEqual(after.pendingCount, 0)
            XCTAssertEqual(after.attentionCount, 1)
            XCTAssertEqual(try reopened.settleOrphanedTranscriptions(), 0)
        }
    }

    private func present(_ notes: [Interjection], isRetrying: (Interjection) -> Bool = { _ in false }) -> PlaybackMarginTranscriptionStatus {
        PlaybackMarginTranscriptionStatus(selectedItemId: "A", playingItemId: "A", sessionId: "A-current",
                                         interjections: notes, isRetrying: isRetrying)
    }

    private func withStore(_ body: (SQLiteSessionStore, SessionEngine, String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("playback-transcription-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("store.sqlite").path
        do {
            let store = try SQLiteSessionStore(path: path)
            for id in ["A", "B"] {
                try store.saveItem(Item(id: id, title: id, mediaType: "text", text: "Source.", externalReference: nil, status: "ready"))
            }
            for (id, item) in [("A-current", "A"), ("A-older", "A"), ("B-current", "B")] {
                try store.saveSession(Session(id: id, itemId: item, status: "in_progress", phase: .itemPlayback,
                    currentTargetType: .itemTextTTS, currentTargetId: item, position: Position(), completionPercent: 0, playbackRate: 1))
            }
            let engine = SessionEngine(profile: RuntimeCapabilityProfile(id: "test", displayName: "Test", capabilities: [
                "sync": ["canonical_persistence"], "playback": ["realtime_tts"],
                "interjection": ["record_audio", "capture_text_anchor"]
            ]), repository: store)
            try body(store, engine, path)
        }
    }

    private func note(_ id: String, transcription: String, item: String = "A", session: String = "A-current") -> Interjection {
        Interjection(id: id, itemId: item, sessionId: session, targetType: .item, targetId: item,
            createdAt: Date(timeIntervalSince1970: 1), roughPercent: 0,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 7, anchorBefore: "Source.", anchorAfter: ""),
            audioPath: "interjections/\(id).m4a", audioStatus: "saved", transcriptionStatus: transcription,
            transcript: transcription == "transcribed" ? "Words" : nil,
            cleanedTranscript: nil, displayText: nil, status: "active")
    }
}
