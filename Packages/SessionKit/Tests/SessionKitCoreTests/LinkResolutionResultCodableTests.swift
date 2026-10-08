import Foundation
import XCTest
@testable import SessionKit

/// #1048 (BIG-11). The test this replaces (in SessionKitTests, which only builds on a Mac) built a
/// link result through the memberwise initialisers and read back three of the values it had just
/// supplied, so it could only fail if a property was renamed, and then it would not compile. What
/// is stored and exchanged is the JSON, so these tests pin its keys and values, and the shape an
/// older writer produced.
final class LinkResolutionResultCodableTests: XCTestCase {
    func testAResolvedPodcastEpisodeKeepsItsWireKeysAndValues() throws {
        let candidate = LinkResolutionCandidate(
            sourceLink: SourceLink(url: "https://feeds.example.com/show.xml", provider: "rss", title: "Example Show", role: "canonical_feed"),
            title: "Episode Title",
            showTitle: "Example Show",
            durationMs: 1_800_000,
            publishedAt: "2026-06-19",
            episodeGUID: "guid-1",
            audioURL: "https://cdn.example.com/episode.mp3",
            transcriptLinks: [SourceTranscriptLink(url: "https://cdn.example.com/episode.vtt", type: "text/vtt", language: "en", rel: "captions")],
            confidence: 0.96
        )
        let result = LinkResolutionResult(
            requestId: "link-request-1",
            status: .playable,
            originalLink: SourceLink(url: "https://open.spotify.com/episode/example", provider: "spotify", role: "discovery"),
            selectedCandidate: candidate,
            candidates: [candidate]
        )

        let data = try JSONEncoder().encode(result)
        let wire = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(wire["requestId"] as? String, "link-request-1")
        XCTAssertEqual(wire["status"] as? String, "playable")
        XCTAssertEqual(wire["originalLink"] as? [String: String],
                       ["url": "https://open.spotify.com/episode/example", "provider": "spotify", "role": "discovery"])
        XCTAssertNil(wire["failureReason"], "an absent reason is left out, not written as null")
        let selected = try XCTUnwrap(wire["selectedCandidate"] as? [String: Any])
        XCTAssertEqual(selected["title"] as? String, "Episode Title")
        XCTAssertEqual(selected["showTitle"] as? String, "Example Show")
        XCTAssertEqual(selected["durationMs"] as? Int, 1_800_000)
        XCTAssertEqual(selected["publishedAt"] as? String, "2026-06-19")
        XCTAssertEqual(selected["episodeGUID"] as? String, "guid-1")
        XCTAssertEqual(selected["audioURL"] as? String, "https://cdn.example.com/episode.mp3")
        XCTAssertEqual(selected["confidence"] as? Double, 0.96)
        XCTAssertEqual((selected["sourceLink"] as? [String: Any])?["role"] as? String, "canonical_feed")
        XCTAssertEqual((selected["transcriptLinks"] as? [[String: String]])?.first,
                       ["url": "https://cdn.example.com/episode.vtt", "type": "text/vtt", "language": "en", "rel": "captions"])
        XCTAssertEqual((wire["candidates"] as? [[String: Any]])?.count, 1)

        XCTAssertEqual(try JSONDecoder().decode(LinkResolutionResult.self, from: data), result)
    }

    func testEveryStatusIsWrittenAsTheContractSpellsIt() throws {
        let link = SourceLink(url: "https://example.com/episode")
        for (status, spelled) in [(LinkResolutionStatus.resolving, "resolving"), (.playable, "playable"),
                                  (.needsReview, "needs_review"), (.unsupported, "unsupported")] {
            let data = try JSONEncoder().encode(LinkResolutionResult(requestId: "r", status: status, originalLink: link))
            let wire = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(wire["status"] as? String, spelled)
            XCTAssertEqual(try JSONDecoder().decode(LinkResolutionResult.self, from: data).status, status)
        }
    }

    /// A result written before candidates carried transcript, chapter and collection links still reads.
    func testAResultFromAnOlderWriterStillDecodes() throws {
        let older = """
        {"requestId":"r1","status":"needs_review",
         "originalLink":{"url":"https://open.spotify.com/episode/x","provider":"spotify","role":"discovery"},
         "candidates":[{"sourceLink":{"url":"https://feeds.example.com/show.xml","role":"canonical_feed"},
                        "title":"Episode","audioURL":"https://cdn.example.com/episode.mp3","confidence":0.5}],
         "failureReason":"Two feeds carry this episode."}
        """
        let result = try JSONDecoder().decode(LinkResolutionResult.self, from: Data(older.utf8))
        XCTAssertEqual(result.status, .needsReview)
        XCTAssertNil(result.selectedCandidate)
        XCTAssertEqual(result.failureReason, "Two feeds carry this episode.")
        let candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertEqual(candidate.audioURL, "https://cdn.example.com/episode.mp3")
        XCTAssertEqual(candidate.transcriptLinks, [])
        XCTAssertEqual(candidate.chapterLinks.count, 0)
        XCTAssertEqual(candidate.publisherChapterCollections.count, 0)
    }
}
