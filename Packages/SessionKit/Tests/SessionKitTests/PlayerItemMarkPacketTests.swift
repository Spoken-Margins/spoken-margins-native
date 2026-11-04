import Foundation
import XCTest
import SessionKit
import SessionKitPersistence
import SessionKitSharing

/// #3203: a Lock Screen Mark placed on the item our player was playing is an ordinary written Margin, so it shares
/// like one. `exportPacket` imports each packet with the frozen Build 29 reader here and keeps it for
/// scripts/check-build29-database.sh, which imports it again with Build 32's and Build 34's own code.
final class PlayerItemMarkPacketTests: XCTestCase {
    private let stamp = Date(timeIntervalSince1970: 1_777_000_000)
    private let taken = Date(timeIntervalSince1970: 1_793_805_600)
    private var root: URL!
    private var store: SQLiteSessionStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("player-item-mark-packet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try SQLiteSessionStore(path: root.appendingPathComponent("library.sqlite").path)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: root)
    }

    /// The share flow's own steps for one stored Margin: the words the review starts with, the anchor, the packet.
    private func export(_ margin: Interjection, item: Item, nativeAudio: Bool, name: String) throws -> SpokenMarginsPackageManifest {
        let words = SharedMarginTextRequirement.initialReviewedText(for: margin)
        XCTAssertTrue(SharedMarginTextRequirement.hasReviewedText(words), "a Mark carries words, so every reader since Build 29 takes it (#304)")
        let anchor = SharedMarginExport.anchor(
            for: margin, item: item, isNativeAudio: nativeAudio, mediaChapters: [], machineEvidenceAssetIds: []
        )
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: "player-item-mark-\(name)", createdAt: stamp,
            item: SharedItemIdentityBuilder.exportIdentity(for: item, draftEditionDigests: [nil]),
            itemTransportSelection: .reference,
            selections: [.init(
                packageScopedId: "margin-001",
                revision: InterjectionShareRevision(
                    id: "revision-\(margin.id)", interjectionId: margin.id, itemId: item.id, sessionId: margin.sessionId,
                    createdAt: margin.createdAt, approvedTranscript: words, cleanedAudioPath: nil, cleanedAudioDurationMs: nil,
                    anchorBefore: margin.anchor.anchorBefore, anchorAfter: margin.anchor.anchorAfter, status: .senderApproved
                ),
                anchor: anchor, representation: .textOnly
            )],
            senderDisplayLabel: "A Friend", suggestedRevealMode: .companion
        )
        return try exportPacket(prepared, to: root.appendingPathComponent("\(name).spokenmargins"))
    }

    func testAMarkOnAnEpisodeExportsInAPacketTheShippedBuildsImport() throws {
        let episode = Item(
            id: "episode", title: "The Harbour Hour", mediaType: "podcast", text: nil,
            externalReference: "https://example.com/e.mp3", status: "ready", externalReferenceType: "podcast",
            media: ItemMedia(sourceType: .nativeMediaFile, url: "file:///tmp/e.mp3", durationMs: 600_000, nativeMediaId: "episode-audio")
        )
        try store.saveItem(episode)
        try store.saveSession(Session(
            id: "session-episode", itemId: "episode", createdAt: stamp, updatedAt: stamp, status: "in_progress", phase: .itemPlayback,
            currentTargetType: .transcriptBackedMedia, currentTargetId: "episode-audio",
            position: Position(charOffset: 0, mediaTimeMs: 421_000), completionPercent: 70, playbackRate: 1
        ))
        let mark = try PlayerItemMargin.placeMark(
            atMediaTimeMs: 574_000, markedAt: taken, itemId: "episode", repository: store, timeZone: TimeZone(identifier: "UTC")!
        )

        let manifest = try export(mark, item: try store.loadItem(id: "episode"), nativeAudio: true, name: "episode")

        XCTAssertEqual(manifest.requiredCapabilities.filter { $0.lowercased().contains("mark") }, [], "no new capability: \(manifest.requiredCapabilities)")
    }

    func testAMarkOnAPublisherArticleExportsInAPacketTheShippedBuildsImport() throws {
        let sentences = ["The harbour shelters fishing boats.", "Gulls circle the old pier at dawn."]
        let text = sentences.joined(separator: " ")
        let article = Item(id: "article", title: "A harbour", mediaType: "text", text: text, externalReference: "https://example.com/harbour", status: "ready")
        try store.saveItem(article)
        try store.savePublisherAudio(PublisherAudio(
            itemId: "article", audioURL: "https://publisher.example/recording.mp3", durationMs: 9_000, detectedFrom: "substack_post_voiceover",
            textMap: TranscriptTimeline(segments: [
                MediaTimelineSegment(id: "p1", startMs: 500, endMs: 4_000, startChar: 0, endChar: sentences[0].count, text: sentences[0]),
                MediaTimelineSegment(id: "p2", startMs: 4_500, endMs: 8_500, startChar: sentences[0].count + 1, endChar: text.count, text: sentences[1])
            ], chapters: [], durationMs: 9_000),
            textMapStatus: "aligned(2 of 2 sentences)"
        ))
        try store.saveSession(Session(
            id: "session-article", itemId: "article", createdAt: stamp, updatedAt: stamp, status: "in_progress", phase: .itemPlayback,
            currentTargetType: .itemTextTTS, currentTargetId: "article",
            position: Position(charOffset: 3), completionPercent: 5, playbackRate: 1
        ))
        let mark = try PlayerItemMargin.placeMark(atMediaTimeMs: 6_500, markedAt: taken, itemId: "article", repository: store)

        let manifest = try export(mark, item: try store.loadItem(id: "article"), nativeAudio: false, name: "article")

        XCTAssertEqual(manifest.requiredCapabilities.filter { $0.lowercased().contains("mark") }, [], "no new capability: \(manifest.requiredCapabilities)")
    }
}
