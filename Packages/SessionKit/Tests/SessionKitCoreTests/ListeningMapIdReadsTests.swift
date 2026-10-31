import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #2506: a caller that asks only whether an item has a map, or whose it is, reads ids and chapters, not a podcast's
/// whole transcript, a stored map or every proposal's scenes.
final class ListeningMapIdReadsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let itemId = "item-episode"

    private func withStore(_ test: (SQLiteSessionStore, StoreReadMeter) throws -> Void) throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("map-ids-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let meter = StoreReadMeter()
        try test(try SQLiteSessionStore(path: path, readMeter: meter), meter)
    }

    private func proposal(_ id: String, sceneCount: Int = 1, at offset: TimeInterval = 0) -> PortableListeningMapProposalArtifact {
        PortableListeningMapProposalArtifact(
            id: id, createdAt: now.addingTimeInterval(offset), generator: "on-device-scene-map.v1",
            scenes: (0..<sceneCount).map { index in
                PortableListeningMapScene(
                    id: "\(id)-\(index)", order: index, title: "Scene \(index)",
                    summaryText: String(repeating: "What happens in this scene. ", count: 20), summaryProvenance: .modelGenerated,
                    eligibility: .eligible,
                    startAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: index * 60_000),
                    endAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: (index + 1) * 60_000)
                )
            }
        )
    }

    /// A transcript the size of a long episode: thousands of segments, one publisher chapter.
    private func longTranscript(chapterId: String) -> SourceTranscriptTimeline {
        let segments = (0..<3_000).map { index in
            MediaTimelineSegment(id: "s\(index)", startMs: index * 1_000, endMs: (index + 1) * 1_000,
                                 text: "A sentence somebody said on the show, number \(index).")
        }
        return SourceTranscriptTimeline(id: "timeline", itemId: itemId, createdAt: now, timeline: TranscriptTimeline(
            segments: segments,
            chapters: [MediaTimelineChapter(id: chapterId, title: "Intro", startMs: 0, transcriptSegmentId: "s0")],
            durationMs: 3_000_000))
    }

    func testTheIdReadsGiveTheWholeReadsIdsInItsOrder() throws {
        try withStore { store, _ in
            XCTAssertNil(try store.listeningMapId(itemId: itemId))
            XCTAssertEqual(try store.portableListeningMapProposalIds(itemId: itemId), [])

            try store.saveListeningMap(ListeningMap(id: "map-item-publisher-feed", itemId: itemId, overview: "", chapters: []))
            try store.savePortableListeningMapProposal(proposal("first"), itemId: itemId)
            try store.savePortableListeningMapProposal(proposal("second", at: 60), itemId: itemId)
            try store.savePortableListeningMapProposal(proposal("elsewhere"), itemId: "other-item")

            XCTAssertEqual(try store.listeningMapId(itemId: itemId), try store.loadListeningMap(itemId: itemId)?.id)
            XCTAssertEqual(try store.portableListeningMapProposalIds(itemId: itemId),
                           try store.loadPortableListeningMapProposals(itemId: itemId).map(\.id))
            XCTAssertEqual(Set(try store.portableListeningMapProposalIds(itemId: itemId)), ["first", "second"])
            XCTAssertNil(try store.listeningMapId(itemId: "other-item"))
        }
    }

    func testOpeningAnEpisodeReadsNoTranscriptMapOrProposalWhole() throws {
        try withStore { store, meter in
            try store.saveTranscriptTimeline(longTranscript(chapterId: "ch-publisher-podcast_namespace-001"))
            try store.saveListeningMap(ListeningMap(id: "map-item", itemId: itemId, overview: String(repeating: "x", count: 50_000), chapters: []))
            try store.savePortableListeningMapProposal(proposal("own-map", sceneCount: 200), itemId: itemId)

            meter.reset()
            let state = CommunityMapLocalState.read(itemId: itemId, repository: store)
            let bytes = meter.samples.reduce(0) { $0 + $1.bytes }

            XCTAssertEqual(state, CommunityMapLocalState(hasPublisherChapters: true, hasMap: true))
            for whole in ["loadTranscriptTimeline(itemId:)", "loadListeningMap(itemId:)", "loadPortableListeningMapProposals(itemId:)"] {
                XCTAssertEqual(meter.totals(for: whole).calls, 0, "\(whole) decodes the whole record")
            }
            XCTAssertLessThan(bytes, 2_000, "ids and one chapter, not the transcript, map and scenes (\(bytes) bytes read)")
        }
    }

    func testTheItemScreensOwnMapCheckReadsOnlyIds() throws {
        try withStore { store, meter in
            try store.savePortableListeningMapProposal(proposal("own-map", sceneCount: 200), itemId: itemId)
            meter.reset()
            let ids = try store.portableListeningMapProposalIds(itemId: itemId)
            XCTAssertEqual(ids, ["own-map"])
            XCTAssertEqual(meter.totals(for: "portableListeningMapProposalIds(itemId:)").bytes, "own-map".utf8.count)
        }
    }

    func testAPublishersMapIdIsReadAsThePublishersChapters() {
        XCTAssertTrue(CommunityMapUploadPolicy.hasPublisherChapters(mapId: "map-item-publisher-podcast_namespace", chapters: []))
        XCTAssertFalse(CommunityMapUploadPolicy.hasPublisherChapters(mapId: "map-item", chapters: []))
        XCTAssertFalse(CommunityMapUploadPolicy.hasPublisherChapters(mapId: nil, chapters: [
            MediaTimelineChapter(id: "ch-scene-001", title: "A scene", startMs: 0, transcriptSegmentId: "s0")]))
        XCTAssertTrue(CommunityMapUploadPolicy.hasPublisherChapters(mapId: nil, chapters: [
            MediaTimelineChapter(id: "ch-publisher-feed-001", title: "Intro", startMs: 0, transcriptSegmentId: "s0")]))
    }

    func testAStoreWithoutIdReadsAnswersFromTheWholeRecords() throws {
        let repository = InMemorySessionRepository()
        try repository.saveListeningMap(ListeningMap(id: "map-item", itemId: itemId, overview: "", chapters: []))
        try repository.savePortableListeningMapProposal(proposal("own-map"), itemId: itemId)
        try repository.saveTranscriptTimeline(longTranscript(chapterId: "ch-publisher-feed-001"))
        XCTAssertEqual(try repository.listeningMapId(itemId: itemId), "map-item")
        XCTAssertEqual(try repository.portableListeningMapProposalIds(itemId: itemId), ["own-map"])
        XCTAssertEqual(try repository.loadTranscriptTimelineChapters(itemId: itemId).map(\.id), ["ch-publisher-feed-001"])
        XCTAssertEqual(CommunityMapLocalState.read(itemId: itemId, repository: repository),
                       CommunityMapLocalState(hasPublisherChapters: true, hasMap: true))
    }
}
