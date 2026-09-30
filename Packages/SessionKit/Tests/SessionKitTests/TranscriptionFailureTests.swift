import XCTest
@testable import SessionKit
import SessionKitPersistence

/// A failed transcript is a status, not the listener's words (#304).
final class TranscriptionFailureTests: XCTestCase {
    func testFailedTranscriptionLeavesTheMarginWithoutTextOnTheTimelineOrInExports() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "sessionkit-transcript-failed-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try SQLiteSessionStore(path: path)
        let item = Item(id: "item-transcript-failed", title: "Essay", mediaType: "text", text: "A sentence to listen to.", externalReference: nil, status: "ready")
        try store.saveItem(item)
        let engine = SessionEngine(profile: phonePlaybackProfile(), repository: store)
        let sessionId = try XCTUnwrap(try engine.startSession(itemId: item.id).sessionId)
        let margin = Interjection(id: "margin-transcript-failed", itemId: item.id, sessionId: sessionId, targetType: .item, targetId: item.id, createdAt: Date(), roughPercent: 10, anchor: Anchor(anchorType: .text, startChar: 0, endChar: 1, anchorBefore: "", anchorAfter: "A sentence"), audioPath: "margin.m4a", audioStatus: "saved", transcriptionStatus: "pending", transcript: nil, cleanedTranscript: nil, displayText: nil, status: "active")
        try store.saveInterjection(margin)

        let snapshot = try engine.transcriptionFailed(interjectionId: margin.id, sessionId: sessionId, error: "speech_recognition_denied")

        let saved = try XCTUnwrap(try store.loadInterjections(sessionId: sessionId).first)
        XCTAssertEqual(saved.transcriptionStatus, "failed")
        XCTAssertNil(saved.displayText, "The failure status must not become the Margin's own words")
        XCTAssertNil(saved.transcript)
        XCTAssertEqual(snapshot.lastFailure, "transcription_failed:speech_recognition_denied")

        let entry = try XCTUnwrap(engine.compactTimelineEntries().first { $0.id == "interjection-\(margin.id)" })
        XCTAssertNil(entry.detail, "The compact timeline must not show the failure status as the Margin's text")

        let export = try engine.buildExport(options: ExportOptions(
            sessionId: sessionId,
            includeFullText: false,
            includeReference: true,
            includeListeningMap: false,
            includeInterjections: true
        ))
        XCTAssertFalse(SessionExportMarkdownRenderer.render(export).contains("Transcript failed"))
    }

    func testAMarginThatAlreadyHasWordsKeepsThemWhenARetryFails() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "sessionkit-transcript-retry-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try SQLiteSessionStore(path: path)
        let item = Item(id: "item-transcript-retry", title: "Essay", mediaType: "text", text: "A sentence to listen to.", externalReference: nil, status: "ready")
        let session = Session(id: "session-transcript-retry", itemId: item.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 0, playbackRate: 1)
        let margin = Interjection(id: "margin-transcript-retry", itemId: item.id, sessionId: session.id, targetType: .item, targetId: item.id, createdAt: Date(), roughPercent: 10, anchor: Anchor(anchorType: .text, startChar: 0, endChar: 1, anchorBefore: "", anchorAfter: "A sentence"), audioPath: "margin.m4a", audioStatus: "saved", transcriptionStatus: "transcribed", transcript: "Remember this line.", cleanedTranscript: nil, displayText: "Remember this line.", status: "active")
        try store.saveItem(item)
        try store.saveSession(session)
        try store.saveInterjection(margin)
        let engine = SessionEngine(profile: phonePlaybackProfile(), repository: store)

        _ = try engine.transcriptionFailed(interjectionId: margin.id, sessionId: session.id, error: "retry_failed")

        let saved = try XCTUnwrap(try store.loadInterjections(sessionId: session.id).first)
        XCTAssertEqual(saved.displayText, "Remember this line.")
    }

    private func phonePlaybackProfile() -> RuntimeCapabilityProfile {
        RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone / Tablet Online",
            capabilities: [
                "playback": ["realtime_tts"],
                "interjection": ["record_audio", "capture_text_anchor"],
                "sync": ["canonical_persistence"]
            ]
        )
    }
}
