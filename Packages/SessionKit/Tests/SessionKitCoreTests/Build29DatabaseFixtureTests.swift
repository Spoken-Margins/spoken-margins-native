#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// Writes a database with the current code for scripts/check-build29-database.sh,
/// including a v1 item moved to v2 by a re-import (step 5),
/// which opens it with Build 29's own persistence code (the owner's condition for
/// storing I13 documents, #191). Run alone it writes to a temporary file and checks
/// that the current code reads it back.
final class Build29DatabaseFixtureTests: XCTestCase {
    func testWritesV1AndV2PDFItemsWithMarginsForTheBuild29Reader() throws {
        let environment = ProcessInfo.processInfo.environment
        let path = environment["SM_BUILD29_DB"]
            ?? FileManager.default.temporaryDirectory.appending(path: "build29-\(UUID().uuidString).sqlite").path
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        let store = try SQLiteSessionStore(path: path)
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "pdf", displayName: "PDF", capabilities: ["sync": ["canonical_persistence"]]),
            repository: store
        )
        let v1 = try engine.importBrowserTextInBackground(BrowserTextHandoff(
            captureMode: .markdownFile,
            source: BrowserTextSource(url: "shared-file://share-sheet/Old.pdf", title: "Old"),
            text: "# Old paper\n\n## Methods\n\nImported before extraction v2.",
            contentFormat: .markdown
        ))
        let document = StructuredDocumentBuilder.build(lines: [
            StructuredDocumentLine(text: "Methods", role: .heading, pageIndex: 0, level: 2),
            StructuredDocumentLine(text: "Imported with extraction v2 [3].", role: .body, pageIndex: 0),
            StructuredDocumentLine(text: "References", role: .heading, pageIndex: 1, level: 2),
            StructuredDocumentLine(text: "[3] A. Author. Title. 2020.", role: .reference, pageIndex: 1),
        ], engine: "pdfkit_baseline", version: 2, pageCount: 2)
        let v2 = try engine.importBrowserTextInBackground(BrowserTextHandoff(
            captureMode: .markdownFile,
            source: BrowserTextSource(url: "shared-file://share-sheet/New.pdf", title: "New"),
            text: "unused",
            contentFormat: .markdown
        ), structuredDocument: document)

        // A v1 item moved to v2 by a re-import (C1 M3 step 5): its Margin is written
        // first, against the v1 text, and the upgrade moves it.
        let movedURL = "shared-file://share-sheet/Moved.pdf"
        let beforeMove = try engine.importBrowserTextInBackground(BrowserTextHandoff(
            captureMode: .markdownFile,
            source: BrowserTextSource(url: movedURL, title: "Moved"),
            text: "# Moved\n\n## Results\n\nThe effect held in every cohort.",
            contentFormat: .markdown
        ))
        let movedSession = Session(id: "session-\(beforeMove.id)", itemId: beforeMove.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: beforeMove.id, position: Position(), completionPercent: 0, playbackRate: 1)
        try store.saveSession(movedSession)
        let beforeText = try XCTUnwrap(beforeMove.text)
        let heldStart = beforeText.distance(from: beforeText.startIndex, to: try XCTUnwrap(beforeText.range(of: "effect held")).lowerBound)
        try store.saveInterjection(Interjection(
            id: "margin-\(beforeMove.id)", itemId: beforeMove.id, sessionId: movedSession.id, targetType: .item, targetId: beforeMove.id,
            createdAt: Date(timeIntervalSince1970: 1), roughPercent: 0,
            anchor: Anchor(anchorType: .text, startChar: heldStart, endChar: heldStart + 11, anchorBefore: "", anchorAfter: ""),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: nil, cleanedTranscript: nil,
            displayText: "A written Margin", status: "active"
        ))
        let movedDocument = StructuredDocumentBuilder.build(lines: [
            StructuredDocumentLine(text: "J Biol 12", role: .pageHeader, pageIndex: 0),
            StructuredDocumentLine(text: "Results", role: .heading, pageIndex: 0, level: 2),
            StructuredDocumentLine(text: "The effect held in every cohort.", role: .body, pageIndex: 0),
        ], engine: "pdfkit_baseline", version: 2, pageCount: 1)
        let moved = try engine.importBrowserTextInBackground(BrowserTextHandoff(
            captureMode: .markdownFile,
            source: BrowserTextSource(url: movedURL, title: "Moved"),
            text: movedDocument.text,
            contentFormat: .plainText
        ), structuredDocument: movedDocument)
        XCTAssertEqual(moved.id, beforeMove.id, "moved in place")
        XCTAssertEqual(moved.text, movedDocument.text)

        var expected: [[String: Any]] = []
        for (item, sessionId, marginId) in [(moved, movedSession.id, "margin-\(beforeMove.id)")] {
            let text = try XCTUnwrap(try store.loadItem(id: item.id).text)
            let margin = try XCTUnwrap(try store.loadInterjections(sessionId: sessionId).first)
            XCTAssertEqual(String(Array(text)[margin.anchor.startChar..<margin.anchor.endChar]), "effect held")
            expected.append([
                "itemId": item.id,
                "textSHA256": SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined(),
                "sessionId": sessionId,
                "marginId": marginId,
                "marginWords": "effect held",
                "hasListeningMap": try store.loadListeningMap(itemId: item.id) != nil,
            ])
        }
        for item in [v1, v2] {
            let text = try XCTUnwrap(item.text)
            let session = Session(id: "session-\(item.id)", itemId: item.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(charOffset: 3), completionPercent: 10, playbackRate: 1)
            try store.saveSession(session)
            let margin = Interjection(
                id: "margin-\(item.id)", itemId: item.id, sessionId: session.id, targetType: .item, targetId: item.id,
                createdAt: Date(timeIntervalSince1970: 1), roughPercent: 10,
                anchor: Anchor(anchorType: .text, startChar: 0, endChar: min(8, text.count), anchorBefore: "", anchorAfter: ""),
                audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: nil, cleanedTranscript: nil,
                displayText: "A written Margin", status: "active"
            )
            try store.saveInterjection(margin)
            expected.append([
                "itemId": item.id,
                "textSHA256": SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined(),
                "sessionId": session.id,
                "marginId": margin.id,
                "hasListeningMap": try store.loadListeningMap(itemId: item.id) != nil,
            ])
        }
        // A reply and an arrived reply carry links (#472); Build 29 must still decode both.
        let replyLink = MarginReplyLink.replying(
            to: MarginPacketIdentity(packageDigest: String(repeating: "a", count: 64), packageScopedId: "a-1"),
            parentConversationId: nil
        )
        var reply = try XCTUnwrap(try store.loadInterjections(sessionId: "session-\(v1.id)").first)
        reply.replyTo = replyLink
        try store.saveInterjection(reply.recordingShare(as: MarginPacketIdentity(
            packageDigest: String(repeating: "b", count: 64), packageScopedId: "b-1")))
        let layer = ImportedCommentaryLayer(
            id: "layer-reply", itemId: v1.id, packageDigest: String(repeating: "c", count: 64), packageId: "package-c",
            itemIdentity: SharedItemIdentity(itemType: .pdf, title: "Old"), importedAt: Date(timeIntervalSince1970: 1)
        )
        _ = try store.importCommentaryLayer(layer, interjections: [ImportedCommentaryInterjection(
            id: "arrived-reply", layerId: layer.id, packageScopedId: "c-1", createdAt: Date(timeIntervalSince1970: 1),
            anchorEvidence: PortableAnchorEvidence(anchorType: .text), approvedTranscript: "A reply", replyLinks: [replyLink]
        )])
        XCTAssertEqual(try store.loadInterjections(sessionId: "session-\(v1.id)").first?.replyTo, replyLink)

        // An article with publisher audio (#545): its own record kind beside the item, and a feed
        // entry with the body word count and duration. Build 29 must still read both.
        // With its text-to-time map (#546), which lives inside that record.
        try store.savePublisherAudio(PublisherAudio(
            itemId: v1.id, audioURL: "https://api.substack.com/feed/podcast/1/a.mp3", durationMs: 60_000, detectedFrom: "feed_enclosure",
            textMap: TranscriptTimeline(segments: [MediaTimelineSegment(id: "publisher-audio-0001", startMs: 0, endMs: 2_000, startChar: 0, endChar: 4, text: "Text")], chapters: [], durationMs: 60_000),
            textMapStatus: "aligned(1 of 1 sentences)"
        ))
        let feedEntry = FeedEntry(id: "entry-publisher-audio", subscriptionId: "subscription-substack", canonicalURL: "https://example.substack.com/p/post",
                                  audioURL: "https://api.substack.com/feed/podcast/1/a.mp3", title: "Post", bodyWordCount: 720, fullBody: "A full subscriber article", publisherPlatform: "substack", publisherNarrationConfirmed: true, audioDurationMs: 60_000)
        try store.saveFeedEntry(feedEntry)
        XCTAssertEqual(try store.loadPublisherAudio(itemId: v1.id)?.durationMs, 60_000)
        XCTAssertNil(try store.loadTranscriptTimeline(itemId: v1.id), "the map must not make the article transcript-backed")

        // An article playing its publisher's recording through its map (#547). Build 29 must see a plain
        // article, its session reading the article, and a Margin anchored to the article's words.
        let postText = "The harbour shelters fishing boats. Gulls circle the old pier."
        let post = Item(id: "item-publisher-post", title: "Harbour", mediaType: "text", text: postText,
                        externalReference: "https://example.substack.com/p/harbour", status: "ready")
        try store.saveItem(post)
        try store.savePublisherAudio(PublisherAudio(
            itemId: post.id, audioURL: "https://api.substack.com/feed/podcast/2/b.mp3", durationMs: 8_000, detectedFrom: "feed_enclosure",
            textMap: TranscriptTimeline(segments: [
                MediaTimelineSegment(id: "publisher-audio-0001", startMs: 500, endMs: 3_500, startChar: 0, endChar: 35, text: "The harbour shelters fishing boats."),
                MediaTimelineSegment(id: "publisher-audio-0002", startMs: 4_000, endMs: 7_000, startChar: 36, endChar: 62, text: "Gulls circle the old pier.")
            ], chapters: [], durationMs: 8_000),
            textMapStatus: "aligned(2 of 2 sentences)"
        ))
        let playingEngine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "phone", displayName: "Phone", capabilities: [
                "sync": ["canonical_persistence"], "playback": ["realtime_tts", "native_media"], "interjection": ["record_audio"]
            ]),
            repository: store
        )
        let playing = try playingEngine.startSession(itemId: post.id)
        XCTAssertEqual(playing.targetType, TargetType.transcriptBackedMedia.rawValue, "the recording plays")
        let postCapture = try playingEngine.beginWrittenInterjection()
        _ = try playingEngine.saveWrittenInterjection(captureId: postCapture.id, text: "On the harbour")
        let postSessionId = try XCTUnwrap(playing.sessionId)
        let postMargin = try XCTUnwrap(try store.loadInterjections(sessionId: postSessionId).first)
        XCTAssertEqual(postMargin.anchor.anchorType, .text)
        XCTAssertNil(try store.loadItem(id: post.id).media)
        XCTAssertEqual(try store.loadSession(id: postSessionId)?.currentTargetType, .itemTextTTS)
        expected.append([
            "itemId": post.id,
            "textSHA256": SHA256.hash(data: Data(postText.utf8)).map { String(format: "%02x", $0) }.joined(),
            "sessionId": postSessionId,
            "marginId": postMargin.id,
            "hasListeningMap": try store.loadListeningMap(itemId: post.id) != nil,
            "sessionTargetType": TargetType.itemTextTTS.rawValue,
            "itemHasNoMedia": true,
        ])

        // Podcasts (#1900). A streamed episode with a saved download and a Margin placed by media time, and an imported
        // audio file the listener linked to its episode (#755). Their Item fields (episodeGUID, showTitle, publishedAt,
        // descriptionText, linkedEpisode) and the download record are newer than Build 29, which must still read them.
        // Every shipped build the script checks opens them (scripts/check-build29-database.sh).
        var streamed = Item(
            id: "item-podcast-downloaded", title: "A downloaded episode", mediaType: TargetType.transcriptBackedMedia.rawValue,
            text: nil, externalReference: "https://feeds.example.com/downloaded", status: "ready", externalReferenceType: "url",
            media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/downloaded.mp3", durationMs: 1_800_000),
            sourceTitle: "The Fixture Show", createdAt: Date(timeIntervalSince1970: 1_758_000_000)
        )
        streamed.episodeGUID = "guid-downloaded"
        streamed.showTitle = "The Fixture Show"
        streamed.publishedAt = "Tue, 29 Sep 2026 10:00:00 GMT"
        streamed.descriptionText = "What the publisher says about this episode."
        try store.saveItem(streamed)
        let download = PodcastDownloadRecord(
            id: "download-podcast-downloaded", itemId: streamed.id, remoteURL: "https://cdn.example.com/downloaded.mp3",
            localRelativePath: "Podcasts/downloaded.mp3", state: .availableOffline, bytesWritten: 28_800_000,
            expectedBytes: 28_800_000, lastPlayedAt: Date(timeIntervalSince1970: 1_758_000_300), updatedAt: Date(timeIntervalSince1970: 1_758_000_400)
        )
        try store.savePodcastDownload(download)
        let streamedSession = Session(
            id: "session-podcast-downloaded", itemId: streamed.id, createdAt: Date(timeIntervalSince1970: 1_758_000_000),
            status: "in_progress", phase: .itemPlayback, currentTargetType: .transcriptBackedMedia,
            currentTargetId: streamed.media?.url ?? streamed.id, position: Position(mediaTimeMs: 600_000), completionPercent: 33, playbackRate: 1
        )
        try store.saveSession(streamedSession)
        try store.saveInterjection(Interjection(
            id: "margin-podcast-downloaded", itemId: streamed.id, sessionId: streamedSession.id, targetType: .item, targetId: streamed.id,
            createdAt: Date(timeIntervalSince1970: 1_758_000_100), roughPercent: 33,
            anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 600_000),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: nil, cleanedTranscript: nil,
            displayText: "A Margin at ten minutes", status: "active"
        ))
        var linkedFile = Item(
            id: "item-podcast-linked", title: "An imported file", mediaType: TargetType.transcriptBackedMedia.rawValue,
            text: nil, externalReference: "imported-audio://linked", status: "ready", externalReferenceType: "file",
            media: ItemMedia(sourceType: .nativeMediaFile, url: "file:///var/mobile/Library/linked.mp3", durationMs: 1_790_000),
            createdAt: Date(timeIntervalSince1970: 1_758_000_000)
        )
        linkedFile.linkedEpisode = LinkedEpisode(
            guid: "guid-downloaded", title: "A downloaded episode", showTitle: "The Fixture Show",
            publishedAt: "Tue, 29 Sep 2026 10:00:00 GMT", pageURL: "https://feeds.example.com/downloaded",
            enclosureURL: "https://cdn.example.com/downloaded.mp3", durationMs: 1_800_000
        )
        try store.saveItem(linkedFile)
        XCTAssertEqual(try store.loadItem(id: linkedFile.id).linkedEpisode, linkedFile.linkedEpisode)
        XCTAssertEqual(try store.loadPodcastDownloads().map(\.id), [download.id])
        let podcasts: [[String: Any]] = [
            [
                "itemId": streamed.id, "mediaURL": "https://cdn.example.com/downloaded.mp3", "durationMs": 1_800_000,
                "downloadId": download.id, "downloadPath": "Podcasts/downloaded.mp3",
                "sessionId": streamedSession.id, "marginId": "margin-podcast-downloaded", "marginMediaTimeMs": 600_000,
            ],
            ["itemId": linkedFile.id, "mediaURL": "file:///var/mobile/Library/linked.mp3", "durationMs": 1_790_000, "linkedEpisodeGUID": "guid-downloaded"],
        ]

        XCTAssertNil(try store.loadStructuredDocument(itemId: v1.id))
        XCTAssertEqual(try store.loadStructuredDocument(itemId: v2.id), document)

        // #1052: the shipped reader must open a database the restore pass actually wrote to,
        // not merely one with the same table shapes. Set aside the v2 item's Library rows
        // as an older decoder would, then reopen with this build before handing it to Build 29.
        let restoredRowsSQL = """
            SELECT kind, id, session_id, item_id, payload FROM records
            WHERE item_id = ? AND kind IN ('item', 'session', 'interjection', 'listening_map', 'canonical_source')
            ORDER BY kind, id;
            """
        let rowsBeforeQuarantine = try StoreRawSQL.rows(restoredRowsSQL, bindings: [v2.id], at: path)
        let itemBeforeQuarantine = try store.loadItem(id: v2.id)
        XCTAssertGreaterThanOrEqual(rowsBeforeQuarantine.count, 3, "item, session and Margin must exercise restoration")
        try StoreRawSQL.execute("""
            INSERT INTO quarantined_records(kind, id, payload, decode_error, quarantined_at)
            SELECT kind, id, payload, 'older build could not decode this row', '2026-02-03 04:05:06'
            FROM records WHERE item_id = ?
            AND kind IN ('item', 'session', 'interjection', 'listening_map', 'canonical_source');
            """, bindings: [v2.id], at: path)
        try StoreRawSQL.execute("""
            DELETE FROM records WHERE item_id = ?
            AND kind IN ('item', 'session', 'interjection', 'listening_map', 'canonical_source');
            """, bindings: [v2.id], at: path)
        XCTAssertEqual(try StoreRawSQL.rows(restoredRowsSQL, bindings: [v2.id], at: path), [])
        XCTAssertEqual(try store.quarantinedRecordCount(), rowsBeforeQuarantine.count)

        let reopened = try SQLiteSessionStore(path: path)
        XCTAssertEqual(try StoreRawSQL.rows(restoredRowsSQL, bindings: [v2.id], at: path), rowsBeforeQuarantine,
                       "the shipped-reader fixture contains the original keys, columns and bytes restored on open")
        XCTAssertEqual(try reopened.loadItem(id: v2.id), itemBeforeQuarantine)
        XCTAssertEqual(try reopened.loadInterjections(sessionId: "session-\(v2.id)").map(\.id), ["margin-\(v2.id)"])
        XCTAssertEqual(try reopened.quarantinedRecordCount(), 0)
        XCTAssertEqual(SQLiteSessionStore.schemaVersion(atPath: path), 5)
        let data = try JSONSerialization.data(
            withJSONObject: ["items": expected, "importedMargins": [["layerId": layer.id, "marginId": "arrived-reply"]], "feedEntryIds": [feedEntry.id], "podcasts": podcasts],
            options: [.sortedKeys]
        )
        try data.write(to: URL(fileURLWithPath: path + ".expected.json"))
        if environment["SM_BUILD29_DB"] == nil {
            for suffix in ["", "-wal", "-shm", ".expected.json"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
    }
}
