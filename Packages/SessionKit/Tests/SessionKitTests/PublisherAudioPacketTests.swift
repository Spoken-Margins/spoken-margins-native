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
}
