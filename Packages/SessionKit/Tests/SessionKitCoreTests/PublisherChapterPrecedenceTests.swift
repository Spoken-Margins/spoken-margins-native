import Foundation
import XCTest
@testable import SessionKit

/// Which publisher chapters a podcast episode keeps: the source with the highest precedence (Podcasting 2.0 JSON,
/// then Podlove Simple Chapters, then chapters embedded in the audio, then timestamps in the description), and a
/// fresh copy of the same source replaces the old one.
///
/// `testPodcastPublisherChaptersUsePrecedencePersistAndNavigateWithoutTranscript` (Mac-only target) lists the
/// candidate's collections lowest precedence first, so the best one is also the last, and picking the last
/// collection gives the same answer as picking the best. `testPublisherChapterSourcesUpgradeInDeclaredOrder`
/// attaches each source once and never the same source twice.
final class PublisherChapterPrecedenceTests: XCTestCase {
    private func collection(_ source: PublisherChapterSource, _ titles: [String]) -> PublisherChapterCollection {
        PublisherChapterCollection(source: source, chapters: titles.enumerated().map { index, title in
            PublisherChapter(title: title, startMs: index * 300_000)
        })
    }

    private func engineAndRepository() -> (SessionEngine, InMemorySessionRepository) {
        let repository = InMemorySessionRepository()
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(
                id: "phone-tablet-online", displayName: "Phone/Tablet Online",
                capabilities: ["sync": ["canonical_persistence"], "playback": ["native_media"], "timeline": ["chapter_timing"]]
            ),
            repository: repository
        )
        return (engine, repository)
    }

    private func permutations<T>(_ items: [T]) -> [[T]] {
        guard let first = items.first else { return [[]] }
        let rest = permutations(Array(items.dropFirst()))
        return rest.flatMap { permutation in
            (0...permutation.count).map { index in
                var inserted = permutation
                inserted.insert(first, at: index)
                return inserted
            }
        }
    }

    func testAResolvedEpisodeKeepsTheHighestPrecedenceChaptersWhateverOrderTheCollectionsComeIn() throws {
        let collections = [
            collection(.timestampedDescription, ["Description Intro", "Description Topic"]),
            collection(.podloveSimpleChapters, ["Podlove Intro", "Podlove Topic"]),
            collection(.podcasting20JSON, ["Publisher Intro", "Publisher Topic"]),
        ]
        let orders = permutations(collections)
        XCTAssertEqual(orders.count, 6, "fixture check: every order is tried, including the best source first and in the middle")

        for ordered in orders {
            let (engine, repository) = engineAndRepository()
            let request = LinkResolutionRequest(
                id: "request", inputURL: "https://feeds.example.com/show.xml", sourceSurface: "paste",
                createdAt: Date(timeIntervalSince1970: 1)
            )
            let candidate = LinkResolutionCandidate(
                sourceLink: SourceLink(url: request.inputURL, provider: "rss", role: "canonical_feed"),
                title: "Chaptered Episode", durationMs: 1_200_000, audioURL: "https://cdn.example.com/chaptered.mp3",
                publisherChapterCollections: ordered, confidence: 0.96
            )
            let result = LinkResolutionResult(
                requestId: request.id, status: .playable,
                originalLink: SourceLink(url: request.inputURL, provider: "rss", role: "canonical_feed"),
                selectedCandidate: candidate, candidates: [candidate]
            )

            let imported = try engine.importResolvedSourceLink(request, result: result)

            let itemId = try XCTUnwrap(imported.itemId)
            let map = try XCTUnwrap(try repository.loadListeningMap(itemId: itemId))
            let order = ordered.map(\.source.rawValue).joined(separator: ", ")
            XCTAssertEqual(map.id, "map-\(itemId)-publisher-podcasting_2_json", "collections in order: \(order)")
            XCTAssertEqual(map.chapters.map(\.title), ["Publisher Intro", "Publisher Topic"], "collections in order: \(order)")
        }
    }

    func testAFreshCopyOfTheSameChapterSourceReplacesTheOldChaptersButALowerSourceDoesNot() throws {
        let (engine, repository) = engineAndRepository()
        let item = Item(
            id: "item-refresh", title: "Refreshed Episode", mediaType: TargetType.transcriptBackedMedia.rawValue, text: nil,
            externalReference: "https://example.com/episode", status: "ready",
            media: ItemMedia(sourceType: .nativeMediaFile, url: "file:///tmp/episode.mp3", durationMs: 900_000)
        )
        try repository.saveItem(item)

        _ = try engine.attachPublisherChapters(itemId: item.id, collection: collection(.podcasting20JSON, ["Draft Intro", "Draft Topic"]))
        XCTAssertEqual(try repository.loadListeningMap(itemId: item.id)?.chapters.map(\.title), ["Draft Intro", "Draft Topic"])

        // The publisher corrects its chapter list: the same source arrives again with different chapters.
        _ = try engine.attachPublisherChapters(itemId: item.id, collection: collection(.podcasting20JSON, ["Final Intro", "Final Topic", "Final Outro"]))

        let corrected = try XCTUnwrap(try repository.loadListeningMap(itemId: item.id))
        XCTAssertEqual(corrected.chapters.map(\.title), ["Final Intro", "Final Topic", "Final Outro"],
                       "the corrected chapters replace the old ones")
        XCTAssertEqual(try repository.loadTranscriptTimeline(itemId: item.id)?.timeline.chapters.map(\.title),
                       ["Final Intro", "Final Topic", "Final Outro"], "and so does the timeline the player jumps by")

        _ = try engine.attachPublisherChapters(itemId: item.id, collection: collection(.timestampedDescription, ["Description Only"]))

        XCTAssertEqual(try repository.loadListeningMap(itemId: item.id)?.chapters.map(\.title), ["Final Intro", "Final Topic", "Final Outro"],
                       "a lower-precedence source never replaces them")
    }
}
