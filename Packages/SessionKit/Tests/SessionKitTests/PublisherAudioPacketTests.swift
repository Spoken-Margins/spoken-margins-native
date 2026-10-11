import Foundation
import XCTest
import ZIPFoundation
import SessionKit
import SessionKitPersistence
import SessionKitSharing

final class PublisherAudioPacketTests: XCTestCase {
    func testPublisherRecordingDoesNotChangeExportedPacketOrEscapeInAnyEntry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("publisher-packet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteSessionStore(path: root.appendingPathComponent("library.sqlite").path)
        let item = Item(id: "article", title: "A harbour", mediaType: "text", text: "The harbour shelters fishing boats.", externalReference: "https://example.com/harbour", status: "ready")
        try store.saveItem(item)
        let date = Date(timeIntervalSince1970: 1_777_000_000)
        func export(_ name: String) throws -> [String: Data] {
            let current = try store.loadItem(id: item.id)
            let prepared = try SpokenMarginsPackageBuilder.prepare(
                packageId: "publisher-audio-equivalence", createdAt: date,
                item: SharedItemIdentityBuilder.exportIdentity(for: current, draftEditionDigests: [nil]),
                itemTransportSelection: .reference,
                selections: [.init(packageScopedId: "margin-001", revision: InterjectionShareRevision(
                    id: "revision", interjectionId: "note", itemId: item.id, sessionId: "session",
                    createdAt: date, approvedTranscript: "A thought about this harbour.",
                    cleanedAudioPath: nil, cleanedAudioDurationMs: nil,
                    anchorBefore: "The harbour", anchorAfter: "fishing boats.", status: .senderApproved),
                    anchor: .init(anchorType: .text, exactText: "shelters"), representation: .textOnly)])
            let url = root.appendingPathComponent("\(name).spokenmargins")
            _ = try exportPacket(prepared, to: url)
            let archive = try Archive(url: url, accessMode: .read)
            var entries: [String: Data] = [:]
            for entry in archive {
                var data = Data()
                _ = try archive.extract(entry) { data.append($0) }
                entries[entry.path] = data
            }
            return entries
        }
        let before = try export("before")
        let privateURL = "https://publisher.example/recording.mp3?subscriber_token=must-stay-local"
        let text = try XCTUnwrap(item.text)
        let alignment = PublisherAudioAligner.align(articleText: text, recognised: TranscriptTimeline(
            segments: [MediaTimelineSegment(id: "recording", startMs: 1_000, endMs: 3_000, text: text)],
            chapters: [], durationMs: 80_000))
        let recording = PublisherAudio(itemId: item.id, audioURL: privateURL, durationMs: 80_000, detectedFrom: "substack_post_voiceover")
            .recordingTextMap(alignment)
        XCTAssertNotNil(recording.textMap, alignment.status)
        try store.savePublisherAudio(recording)
        let after = try export("after")
        XCTAssertEqual(before, after, "all archive entries, including the manifest, must match byte for byte")
        XCTAssertNotNil(after["manifest.json"])
        for (path, data) in after {
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(text.contains(privateURL), path)
            XCTAssertFalse(text.contains("must-stay-local"), path)
            XCTAssertFalse(text.contains("publisher_audio"), path)
            XCTAssertFalse(text.contains("publisher-audio-0001"), path)
        }
    }
    /// #547: a Margin recorded while the publisher's recording plays is anchored to the article's words,
    /// so its packet is the packet of any article Margin: Build 29 reads it, and it carries no time in
    /// the recording and no segment of the map.
    func testAMarginRecordedDuringThePublisherRecordingExportsAsAnOrdinaryTextMargin() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("publisher-margin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteSessionStore(path: root.appendingPathComponent("library.sqlite").path)
        let sentences = ["The harbour shelters fishing boats.", "Gulls circle the old pier at dawn."]
        let text = sentences.joined(separator: " ")
        let item = Item(id: "article", title: "A harbour", mediaType: "text", text: text, externalReference: "https://example.com/harbour", status: "ready")
        try store.saveItem(item)
        let privateURL = "https://publisher.example/recording.mp3?subscriber_token=must-stay-local"
        try store.savePublisherAudio(PublisherAudio(
            itemId: item.id, audioURL: privateURL, durationMs: 9_000, detectedFrom: "substack_post_voiceover",
            textMap: TranscriptTimeline(segments: [
                MediaTimelineSegment(id: "publisher-audio-0001", startMs: 500, endMs: 4_000, startChar: 0, endChar: sentences[0].count, text: sentences[0]),
                MediaTimelineSegment(id: "publisher-audio-0002", startMs: 4_500, endMs: 8_500, startChar: sentences[0].count + 1, endChar: text.count, text: sentences[1])
            ], chapters: [], durationMs: 9_000),
            textMapStatus: "aligned(2 of 2 sentences)"))
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "phone", displayName: "Phone", capabilities: [
                "sync": ["canonical_persistence"], "playback": ["realtime_tts", "native_media"], "interjection": ["record_audio"]
            ]),
            repository: store
        )
        let started = try engine.startSession(itemId: item.id)
        XCTAssertEqual(started.targetType, TargetType.transcriptBackedMedia.rawValue, "the recording plays")
        let capture = try engine.beginWrittenInterjection()
        _ = try engine.saveWrittenInterjection(captureId: capture.id, text: "A thought about this harbour.")
        let margin = try XCTUnwrap(try store.loadInterjections(sessionId: try XCTUnwrap(started.sessionId)).first)

        let stored = try store.loadItem(id: item.id)
        let anchor = SharedMarginExport.anchor(for: margin, item: stored, isNativeAudio: false, mediaChapters: [], machineEvidenceAssetIds: [])
        XCTAssertEqual(anchor.anchorType, .text)
        XCTAssertNil(anchor.mediaTimeMs)
        XCTAssertNil(anchor.transcriptSegmentId)
        XCTAssertNotNil(anchor.startChar)

        let date = Date(timeIntervalSince1970: 1_777_000_000)
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: "publisher-margin", createdAt: date,
            item: SharedItemIdentityBuilder.exportIdentity(for: stored, draftEditionDigests: [nil]),
            itemTransportSelection: .reference,
            selections: [.init(packageScopedId: "margin-001", revision: InterjectionShareRevision(
                id: "revision", interjectionId: margin.id, itemId: item.id, sessionId: margin.sessionId,
                createdAt: date, approvedTranscript: "A thought about this harbour.",
                cleanedAudioPath: nil, cleanedAudioDurationMs: nil,
                anchorBefore: margin.anchor.anchorBefore, anchorAfter: margin.anchor.anchorAfter, status: .senderApproved),
                anchor: anchor, representation: .textOnly)])
        let url = root.appendingPathComponent("publisher-margin.spokenmargins")
        _ = try exportPacket(prepared, to: url) // the shipped Build 29 reader imports it
        let archive = try Archive(url: url, accessMode: .read)
        for entry in archive {
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            let contents = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(contents.contains(privateURL), entry.path)
            XCTAssertFalse(contents.contains("must-stay-local"), entry.path)
            XCTAssertFalse(contents.contains("publisher-audio-0001"), entry.path)
            XCTAssertFalse(contents.contains("publisher_audio"), entry.path)
        }
    }
}
