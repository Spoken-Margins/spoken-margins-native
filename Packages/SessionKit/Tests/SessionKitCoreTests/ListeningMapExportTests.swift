import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// The Listening Map toggle in Export (AI Handoff Markdown, Full JSON Archive and batch export all
/// build through `SessionEngine.buildExport`) carries the map the item's Timeline shows (#2121).
/// On Build 35 a podcast episode whose map is a proposal plus a projection exported no map at all,
/// because only the legacy `ListeningMap` record was read.
final class ListeningMapExportTests: XCTestCase {
    private let episode = Item(
        id: "item-episode", title: "Is There a Bubble?", mediaType: TargetType.transcriptBackedMedia.rawValue, text: nil,
        externalReference: "https://example.com/episode", status: "ready",
        media: ItemMedia(sourceType: .remoteStream, url: "https://example.com/episode.mp3", durationMs: 600_000)
    )

    func testAPodcastMapStoredAsAProposalAndProjectionIsInTheMarkdownAndTheJSON() throws {
        try withStore { store in
            try store.saveItem(episode)
            try store.savePortableListeningMapProposal(proposal(), itemId: episode.id)
            try store.saveResolvedListeningMapProjection(ResolvedListeningMapProjection(
                id: "episode-projection-item-episode", itemId: episode.id, proposalId: "episode-map-proposal-item-episode",
                algorithmVersion: "episode-projection.exact-edition.v1", points: [], intervals: []
            ))
            let export = try buildExport(store: store, itemId: episode.id, includeListeningMap: true)

            let map = try XCTUnwrap(export.listeningMap, "the toggle is on and the Timeline shows three scenes")
            XCTAssertEqual(map.chapters.map(\.title), ["Cold open", "The bull case", "The bear case"])
            XCTAssertEqual(map.chapters.map(\.percent), [0, 20, 50], "each scene at its share of the 10-minute episode")

            let markdown = SessionExportMarkdownRenderer.render(export)
            XCTAssertTrue(markdown.contains("## Listening Map"), markdown)
            XCTAssertTrue(markdown.contains("- The bull case (20%)"), markdown)

            let json = try XCTUnwrap(String(data: JSONEncoder().encode(export), encoding: .utf8))
            XCTAssertTrue(json.contains("\"The bear case\""), "the Full JSON Archive carries the same map")

            let off = try buildExport(store: store, itemId: episode.id, includeListeningMap: false)
            XCTAssertNil(off.listeningMap, "with the toggle off there is no map")
        }
    }

    func testAMapWithNoOverviewStillListsItsChapters() throws {
        try withStore { store in
            let article = Item(id: "item-article", title: "Article", mediaType: "text",
                               text: String(repeating: "A sentence. ", count: 50), externalReference: nil, status: "ready")
            try store.saveItem(article)
            try store.saveListeningMap(ListeningMap(id: "map-article", itemId: article.id, overview: "  ", chapters: [
                Chapter(id: "c1", title: "Opening", startChar: 0, endChar: 100, percent: 0),
                Chapter(id: "c2", title: "Argument", startChar: 100, endChar: 600, percent: 17),
            ]))
            let markdown = SessionExportMarkdownRenderer.render(try buildExport(store: store, itemId: article.id, includeListeningMap: true))

            XCTAssertTrue(markdown.contains("## Listening Map"), markdown)
            XCTAssertTrue(markdown.contains("- Opening (0%)"), markdown)
            XCTAssertTrue(markdown.contains("- Argument (17%)"), markdown)
        }
    }

    func testScenesThatCannotBePlacedOnThisCopyAreLeftOutAsTheTimelineLeavesThemOut() throws {
        try withStore { store in
            try store.saveItem(episode)
            // A proposal with no projection on a non-exact copy: the Timeline places nothing.
            try store.savePortableListeningMapProposal(proposal(), itemId: episode.id)
            try store.saveResolvedListeningMapProjection(ResolvedListeningMapProjection(
                id: "episode-projection-item-episode", itemId: episode.id, proposalId: "episode-map-proposal-item-episode",
                points: [], intervals: []
            ))
            XCTAssertNil(try buildExport(store: store, itemId: episode.id, includeListeningMap: true).listeningMap)
        }
    }

    // MARK: Fixtures

    private func proposal() -> PortableListeningMapProposalArtifact {
        let scenes: [(String, Int, Int)] = [("Cold open", 0, 120_000), ("The bull case", 120_000, 300_000), ("The bear case", 300_000, 600_000)]
        return PortableListeningMapProposalArtifact(
            id: "episode-map-proposal-item-episode", createdAt: Date(timeIntervalSince1970: 1), generator: "on-device-scene-map.v1",
            scenes: scenes.enumerated().map { index, scene in
                PortableListeningMapScene(
                    id: "scene-\(index)", order: index, title: scene.0, summaryText: "About \(scene.0).",
                    summaryProvenance: .modelGenerated, eligibility: .eligible,
                    startAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: scene.1),
                    endAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: scene.2)
                )
            }
        )
    }

    private func buildExport(store: SQLiteSessionStore, itemId: String, includeListeningMap: Bool) throws -> SessionExport {
        let session = Session(
            id: "session-\(itemId)", itemId: itemId, status: "in_progress", phase: .itemPlayback,
            currentTargetType: .transcriptBackedMedia, currentTargetId: itemId,
            position: Position(), completionPercent: 10, playbackRate: 1
        )
        try store.saveSession(session)
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "phone", displayName: "Phone", capabilities: ["sync": ["canonical_persistence"]]),
            repository: store
        )
        return try engine.buildExport(options: ExportOptions(
            sessionId: session.id, includeFullText: false, includeReference: true,
            includeListeningMap: includeListeningMap, includeInterjections: true
        ))
    }

    private func withStore(_ test: (SQLiteSessionStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try test(try SQLiteSessionStore(path: root.appendingPathComponent("library.sqlite").path))
    }
}
