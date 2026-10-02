import Foundation
import XCTest
import SessionKit
import SessionKitPersistence

/// Re-importing a PDF that has prepared narration moves its sessions into the new text (#322, #344).
final class StructuredDocumentUpgradeSessionTests: XCTestCase {
    func testReimportRetiresOnlyTheUpgradedPDFsPreparationRecords() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "sessionkit-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try SQLiteSessionStore(path: path)
        let engine = SessionEngine(profile: RuntimeCapabilityProfile(id: "pdf", displayName: "PDF", capabilities: ["sync": ["canonical_persistence"]]), repository: store)
        let url = "shared-file://share-sheet/Paper.pdf"
        let v1 = try engine.importBrowserTextInBackground(BrowserTextHandoff(
            captureMode: .markdownFile, source: BrowserTextSource(url: url, title: "Paper"),
            text: "# Paper\n\nWe measured sleep in adults.", contentFormat: .markdown
        ))
        let other = try engine.importBrowserTextInBackground(BrowserTextHandoff(
            captureMode: .markdownFile,
            source: BrowserTextSource(url: "shared-file://share-sheet/Other.pdf", title: "Other"),
            text: "Another paper.", contentFormat: .markdown
        ))
        let signature = TTSRenderSignature(engine: "supertonic", modelRevision: "3", assetManifestHash: "a", voiceStyleHash: "v", synthesisParametersHash: "p", normalizationVersion: "n", chunkingVersion: "c", digest: "d")
        // Multiple renders/jobs for the upgraded paper retire together; another paper's survive.
        for (id, itemId) in [("old-a", v1.id), ("old-b", v1.id), ("other", other.id)] {
            let manifest = PreparedAudioManifest(
                id: id, itemId: itemId, sourcePackageId: itemId, signature: signature,
                state: .readyOffline, plannedChunkCount: 0, chunks: []
            )
            let job = AudioPreparationJob(id: "job-\(id)", itemId: itemId, manifestId: id, policy: .whileCharging)
            try store.savePreparedAudioManifest(manifest)
            try store.saveAudioPreparationJob(job)
        }
        // A summary's position is in the summary, not the PDF; neither it nor another
        // item's session may move when the PDF's extraction changes.
        let summarySession = Session(id: "summary", itemId: v1.id, status: "in_progress", phase: .summaryPlayback, currentTargetType: .summaryTurnTTS, currentTargetId: "summary-turn", position: Position(charOffset: 7), completionPercent: 20, playbackRate: 1)
        let otherSession = Session(id: "other-session", itemId: other.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: other.id, position: Position(charOffset: 3), completionPercent: 10, playbackRate: 1)
        try store.saveSession(summarySession)
        try store.saveSession(otherSession)
        let otherManifests = try store.loadPreparedAudioManifests(itemId: other.id)
        let otherJobs = try store.loadAudioPreparationJobs().filter { $0.itemId == other.id }
        let otherBefore = try store.loadItem(id: other.id)
        let document = StructuredDocumentBuilder.build(lines: [
            StructuredDocumentLine(text: "Paper", role: .title, pageIndex: 0),
            StructuredDocumentLine(text: "J Biol 12 (2020) 1-9", role: .pageHeader, pageIndex: 0),
            StructuredDocumentLine(text: "We measured sleep in adults.", role: .body, pageIndex: 0),
        ], engine: "pdfkit_baseline", version: 2, pageCount: 1)

        XCTAssertNotEqual(v1.text, document.text, "exercise an extraction upgrade, not an identical re-import")
        let reimported = try engine.importBrowserTextInBackground(BrowserTextHandoff(
            captureMode: .markdownFile, source: BrowserTextSource(url: url, title: "Paper"),
            text: document.text, contentFormat: .plainText
        ), structuredDocument: document)

        XCTAssertEqual(reimported.id, v1.id)
        XCTAssertEqual(try store.listItems().count, 2, "re-import must not add a third paper")
        XCTAssertEqual(try store.loadStructuredDocument(itemId: v1.id), document)
        XCTAssertTrue(try store.loadPreparedAudioManifests(itemId: v1.id).isEmpty)
        XCTAssertEqual(try store.loadAudioPreparationJobs(), otherJobs)
        XCTAssertEqual(try store.loadPreparedAudioManifests(itemId: other.id), otherManifests)
        XCTAssertEqual(try store.loadItem(id: other.id), otherBefore)
        XCTAssertEqual(try store.loadSession(id: summarySession.id), summarySession)
        XCTAssertEqual(try store.loadSession(id: otherSession.id), otherSession)
    }

    func testReimportKeepsTheSavedPlaceOfASessionOnAnOlderRender() throws {
        // #344 audit on 4d7d41f: the upgrade read every narration session's media time on
        // the item's stored timeline. After the paper was prepared again (#277), that
        // timeline describes the newer render, not the one an older session was playing,
        // so the session's saved place moved to the wrong words.
        let path = FileManager.default.temporaryDirectory.appending(path: "sessionkit-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try SQLiteSessionStore(path: path)
        let engine = SessionEngine(profile: RuntimeCapabilityProfile(id: "pdf", displayName: "PDF", capabilities: ["sync": ["canonical_persistence"]]), repository: store)
        let url = "shared-file://share-sheet/Paper.pdf"
        let v1 = try engine.importBrowserTextInBackground(BrowserTextHandoff(
            captureMode: .markdownFile,
            source: BrowserTextSource(url: url, title: "Paper"),
            text: "# Paper\n\n## Methods\n\nWe measured sleep in adults.\nThe effect held across cohorts.",
            contentFormat: .markdown
        ))
        let text = try XCTUnwrap(v1.text)
        let measured = text.distance(from: text.startIndex, to: try XCTUnwrap(text.range(of: "We measured")).lowerBound)
        let effect = text.distance(from: text.startIndex, to: try XCTUnwrap(text.range(of: "The effect")).lowerBound)
        // The item now plays render B, and its stored timeline is B's: at 30 s, B is on "We measured".
        var narrated = v1
        narrated.media = ItemMedia(sourceType: .generatedTTSPrerendered, url: "file:///tmp/narration-344-b.caf", durationMs: 60_000)
        try store.saveItem(narrated)
        try store.saveTranscriptTimeline(SourceTranscriptTimeline(
            id: "timeline-344-b", itemId: v1.id, createdAt: Date(timeIntervalSince1970: 2),
            timeline: TranscriptTimeline(segments: [
                MediaTimelineSegment(id: "1", startMs: 0, endMs: 60_000, startChar: measured, endChar: measured, text: "We measured"),
            ], chapters: [], durationMs: 60_000)
        ))
        // The session was saved on render A at "The effect".
        let session = Session(id: "session-344-a", itemId: v1.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .transcriptBackedMedia, currentTargetId: "file:///tmp/narration-344-a.caf", position: Position(charOffset: effect, mediaTimeMs: 30_000), completionPercent: 20, playbackRate: 1)
        try store.saveSession(session)

        let document = StructuredDocumentBuilder.build(lines: [
            StructuredDocumentLine(text: "Paper", role: .title, pageIndex: 0),
            StructuredDocumentLine(text: "J Biol 12 (2020) 1-9", role: .pageHeader, pageIndex: 0),
            StructuredDocumentLine(text: "Methods", role: .heading, pageIndex: 0, level: 2),
            StructuredDocumentLine(text: "We measured sleep in adults.", role: .body, pageIndex: 0),
            StructuredDocumentLine(text: "The effect held across cohorts.", role: .body, pageIndex: 0),
        ], engine: "pdfkit_baseline", version: 2, pageCount: 1)
        let reimported = try engine.importBrowserTextInBackground(BrowserTextHandoff(
            captureMode: .markdownFile,
            source: BrowserTextSource(url: url, title: "Paper"),
            text: document.text,
            contentFormat: .plainText
        ), structuredDocument: document)

        XCTAssertEqual(reimported.id, v1.id, "one item, upgraded in place")
        let upgradedText = try XCTUnwrap(try store.loadItem(id: v1.id).text)
        let moved = try XCTUnwrap(try store.loadSession(id: session.id))
        XCTAssertEqual(moved.currentTargetType, .itemTextTTS)
        XCTAssertEqual(String(Array(upgradedText)[moved.position.charOffset...].prefix(10)), "The effect",
                       "the saved place, not render B's words at the same time")
    }
}
