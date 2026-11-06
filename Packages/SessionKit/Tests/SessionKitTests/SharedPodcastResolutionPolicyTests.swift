import Foundation
import XCTest
import SessionKit
import SessionKitSharing

final class SharedPodcastResolutionPolicyTests: XCTestCase {
    func testUniqueTrackingEnclosureWinsBeforeTitleAndDuration() throws {
        let exact = candidate("Different title", audio: "https://dts.podtrac.com/redirect.mp3/chtbl.com/track/ABC/cdn.example.com/episode.mp3?utm_source=feed", duration: 420_000)
        let title = candidate("Café Episode", audio: "https://cdn.example.com/other.mp3", duration: 300_000)
        let original = review([title, exact])
        let settled = try SharedPodcastResolutionPolicy.settle(original, item: packet(), request: request)
        var expected = original
        expected.status = .playable
        expected.selectedCandidate = exact
        XCTAssertEqual(settled.result, expected, "Selection must retain all other lookup fields")
        XCTAssertNil(settled.diagnostic)
    }

    func testMultipleExactMatchesFallThroughToUniqueTitle() throws {
        let first = candidate("Different", audio: enclosure)
        let second = candidate("CAFÉ EPISODE", audio: enclosure)
        let settled = try SharedPodcastResolutionPolicy.settle(review([first, second]), item: packet(), request: request)
        XCTAssertEqual(settled.result.selectedCandidate, second)
        XCTAssertEqual(settled.result.status, .playable)
        XCTAssertNil(settled.diagnostic)
    }

    func testUniqueTitleIsCaseAndDiacriticInsensitiveAndRequiresAudio() throws {
        for title in ["Café Episode", "CAFE EPISODE", "cafe\u{301} episode"] {
            let noAudio = candidate(title, audio: nil, duration: 300_000)
            let matching = candidate(title, audio: "https://cdn.example.com/title.mp3", duration: 900_000)
            let other = candidate("Different", audio: "https://cdn.example.com/other.mp3", duration: 300_000)
            let settled = try SharedPodcastResolutionPolicy.settle(review([noAudio, other, matching]), item: packet(), request: request)
            XCTAssertEqual(settled.result.selectedCandidate, matching, title)
            XCTAssertNil(settled.diagnostic)
        }
        for title in [" Café Episode", "Café Episode ", "Café-Episode", "", "Café Episodes", String(repeating: "Café Episode", count: 1_000)] {
            XCTAssertThrowsError(try SharedPodcastResolutionPolicy.settle(
                review([candidate(title, audio: "https://cdn.example.com/other.mp3")]), item: packet(), request: request
            ), title) { error in
                XCTAssertEqual(error as? SessionKitError, .persistenceFailed("shared_podcast_item_is_ambiguous"))
            }
        }
    }

    func testUniqueTitleDurationBreaksTitleTieUsingPacketDuration() throws {
        // Includes the 2s floor, 0.5% boundary, rounding, both signs, absent durations,
        // and a value accepted only if the candidate is incorrectly used as the base.
        let cases: [(packet: Int?, candidate: Int?, compatible: Bool)] = [
            (300_000, 302_000, true), (300_000, 302_001, false),
            (300_000, 298_000, true), (300_000, 297_999, false),
            (1_000_000, 1_005_000, true), (1_000_000, 1_005_001, false),
            (1_000_000, 995_000, true), (1_000_000, 994_999, false),
            (1_000_000, 1_005_010, false),
            (500_100, 502_601, true), (500_100, 502_602, false),
            (nil, 300_000, false), (300_000, nil, false), (nil, nil, false)
        ]
        for row in cases {
            let matching = candidate("Café Episode", audio: "https://cdn.example.com/duration.mp3", duration: row.candidate)
            let other = candidate("Café Episode", audio: "https://cdn.example.com/other.mp3", duration: 10_000_000)
            let result = review([other, matching])
            let item = packet(duration: row.packet)
            if row.compatible {
                let settled = try SharedPodcastResolutionPolicy.settle(result, item: item, request: request)
                XCTAssertEqual(settled.result.selectedCandidate, matching, "\(row)")
                XCTAssertNil(settled.diagnostic)
            } else {
                XCTAssertThrowsError(try SharedPodcastResolutionPolicy.settle(result, item: item, request: request), "\(row)") { error in
                    XCTAssertEqual(error as? SessionKitError, .persistenceFailed("shared_podcast_item_is_ambiguous"))
                }
            }
        }
    }

    func testAmbiguousAudioCandidatesNeverUsePacketFallback() throws {
        let cases = [
            [candidate("Other", audio: "https://cdn.example.com/other.mp3")],
            [candidate("Café Episode", audio: "https://cdn.example.com/one.mp3", duration: 300_000),
             candidate("Café Episode", audio: "https://cdn.example.com/two.mp3", duration: 300_000)],
            [candidate("Café Episode", audio: enclosure, duration: 300_000),
             candidate("Café Episode", audio: enclosure, duration: 300_000)]
        ]
        for candidates in cases {
            XCTAssertThrowsError(try SharedPodcastResolutionPolicy.settle(review(candidates), item: packet(), request: request)) { error in
                XCTAssertEqual(error as? SessionKitError, .persistenceFailed("shared_podcast_item_is_ambiguous"))
            }
        }
    }

    func testLookupWithoutAudioReplacesWholeResultAndReturnsDiagnostic() throws {
        for candidates in [[], [candidate("Café Episode", audio: nil)]] {
            let settled = try SharedPodcastResolutionPolicy.settle(review(candidates), item: packet(), request: request)
            let expected = try XCTUnwrap(SharedPodcastResolutionPolicy.packageReferenceResolution(item: packet(), request: request))
            XCTAssertEqual(settled.result, expected)
            XCTAssertEqual(settled.diagnostic, "package_reference_after_lookup_without_audio")
            XCTAssertNil(settled.result.failureReason)
            XCTAssertEqual(settled.result.requestId, request.id)
        }
        XCTAssertThrowsError(try SharedPodcastResolutionPolicy.settle(review([]), item: packet(enclosure: nil), request: request)) { error in
            XCTAssertEqual(error as? SessionKitError, .persistenceFailed("shared_podcast_item_is_ambiguous"))
        }
    }

    /// The sharing-kit HPR packet's page link is the mp3 itself, so the real resolver returns a bare file whose title
    /// is the file name. The friend must see the sender's title, never "hpr4736" (#3262).
    func testAPacketWhoseLinkIsTheAudioFileNamesTheEpisodeByItsTitleNotItsFileName() throws {
        let file = "https://hpr.nyc3.cdn.digitaloceanspaces.com/eps/hpr4736/hpr4736.mp3"
        let title = "HPR4736: How to replace the battery in a car key fob"
        let item = packet(canonical: file, title: title, enclosure: file)
        let link = SourceLink(url: file, provider: "direct_audio", title: "hpr4736", role: "audio_file")
        let direct = LinkResolutionCandidate(sourceLink: link, title: "hpr4736", audioURL: file, confidence: 1)
        let resolved = LinkResolutionResult(requestId: "r", status: .playable, originalLink: link, selectedCandidate: direct, candidates: [direct])
        let settled = try SharedPodcastResolutionPolicy.settle(resolved, item: item, request: request).result
        XCTAssertEqual(settled.selectedCandidate?.title, title)
        XCTAssertEqual(settled.selectedCandidate?.sourceLink.title, title, "the Library byline falls back to this")
        XCTAssertEqual(settled.selectedCandidate?.showTitle, "Example Show")
        XCTAssertEqual(settled.originalLink.title, title)
        XCTAssertEqual(settled.candidates.map(\.title), [title])
        XCTAssertEqual(settled.selectedCandidate?.audioURL, file, "only the name changes")
    }

    /// Neighbouring inputs: a feed that reports the file name or ID as the title is also a bare ID; a real title,
    /// a title that only contains the ID, and a blank packet title are left alone.
    func testOnlyAFileNameShapedTitleIsReplacedByThePacketTitle() throws {
        let file = "https://cdn.example.com/eps/hpr4736/hpr4736.mp3"
        let title = "HPR4736: How to replace the battery"
        func settle(resolvedTitle: String, provider: String = "rss", packetTitle: String = title) throws -> String {
            let link = SourceLink(url: "https://podcast.example.com/feed.xml", provider: provider, role: "canonical_feed")
            let resolvedCandidate = LinkResolutionCandidate(sourceLink: link, title: resolvedTitle, audioURL: file, confidence: 1)
            let resolved = LinkResolutionResult(requestId: "r", status: .playable, originalLink: link, selectedCandidate: resolvedCandidate, candidates: [resolvedCandidate])
            let item = packet(canonical: "https://podcast.example.com/eps/4736", title: packetTitle, enclosure: file)
            return try XCTUnwrap(SharedPodcastResolutionPolicy.settle(resolved, item: item, request: request).result.selectedCandidate?.title)
        }
        for idLike in ["hpr4736", "HPR4736", "hpr 4736", "hpr-4736", " hpr4736 "] {
            XCTAssertEqual(try settle(resolvedTitle: idLike), title, idLike)
        }
        XCTAssertEqual(try settle(resolvedTitle: "HPR4736: Feed's own title"), "HPR4736: Feed's own title")
        XCTAssertEqual(try settle(resolvedTitle: "Battery"), "Battery")
        XCTAssertEqual(try settle(resolvedTitle: "hpr4736", packetTitle: "  "), "hpr4736", "nothing better to show")
    }

    func testNonReviewResultsRemainUnchanged() throws {
        for status in [LinkResolutionStatus.playable, .unsupported, .resolving] {
            var original = review([candidate("Other", audio: nil)])
            original.status = status
            let settled = try SharedPodcastResolutionPolicy.settle(original, item: packet(), request: request)
            XCTAssertEqual(settled.result, original)
            XCTAssertNil(settled.diagnostic)
        }
    }

    func testPackageReferencePreservesStoredFieldsAndOriginalURLs() throws {
        let item = packet(canonical: "HTTPS://Podcast.Example.com/episode/#section", title: " Café Episode ", enclosure: "https://CDN.example.com/episode.mp3?token=abc#part")
        let result = try XCTUnwrap(SharedPodcastResolutionPolicy.packageReferenceResolution(item: item, request: request))
        let source = SourceLink(url: try XCTUnwrap(item.canonicalURL), provider: "shared_package", title: item.title, role: "package_reference")
        let selected = LinkResolutionCandidate(
            sourceLink: source, title: item.title, showTitle: item.showTitle,
            durationMs: item.durationMs, publishedAt: item.publishedAt,
            audioURL: item.enclosureURL, confidence: 1
        )
        XCTAssertEqual(result, LinkResolutionResult(requestId: request.id, status: .playable, originalLink: source, selectedCandidate: selected, candidates: [selected]))
    }

    func testReferenceGuardsRejectMissingOrNonHTTPSURLsAndBlankTitles() {
        for url in [nil, "", "not a URL", "http://example.com/episode", "file:///episode.mp3", "https://["] {
            let invalidCanonical = packet(canonical: url)
            XCTAssertFalse(SharedPodcastResolutionPolicy.hasReference(invalidCanonical), "\(String(describing: url))")
            XCTAssertNil(SharedPodcastResolutionPolicy.packageReferenceResolution(item: invalidCanonical, request: request))
            let invalidEnclosure = packet(enclosure: url)
            XCTAssertTrue(SharedPodcastResolutionPolicy.hasReference(invalidEnclosure))
            XCTAssertNil(SharedPodcastResolutionPolicy.packageReferenceResolution(item: invalidEnclosure, request: request))
        }
        for title in ["", " \t\n"] {
            XCTAssertNil(SharedPodcastResolutionPolicy.packageReferenceResolution(item: packet(title: title), request: request))
        }
        XCTAssertNil(SharedPodcastResolutionPolicy.packageReferenceResolution(item: packet(type: .text), request: request))
        XCTAssertTrue(SharedPodcastResolutionPolicy.hasReference(packet()))
        XCTAssertNotNil(SharedPodcastResolutionPolicy.packageReferenceResolution(item: packet(), request: request))
    }

    private let enclosure = "https://cdn.example.com/episode.mp3"
    private var request: LinkResolutionRequest {
        LinkResolutionRequest(id: "shared-package-test", inputURL: "https://podcast.example.com/episode", sourceSurface: "spoken_margins_package", createdAt: Date(timeIntervalSince1970: 123))
    }

    private func packet(
        type: SharedItemType = .podcast,
        canonical: String? = "https://podcast.example.com/episode",
        title: String = "Café Episode",
        enclosure: String? = "https://cdn.example.com/episode.mp3",
        duration: Int? = 300_000
    ) -> SharedItemIdentity {
        SharedItemIdentity(itemType: type, canonicalURL: canonical, title: title, showTitle: "Example Show", enclosureURL: enclosure, publishedAt: "2026-10-01", durationMs: duration)
    }

    private func candidate(_ title: String, audio: String?, duration: Int? = nil) -> LinkResolutionCandidate {
        LinkResolutionCandidate(sourceLink: SourceLink(url: "https://podcast.example.com/feed.xml", provider: "rss", role: "canonical_feed"), title: title, durationMs: duration, episodeGUID: "guid-\(title)", audioURL: audio, confidence: 0.7)
    }

    private func review(_ candidates: [LinkResolutionCandidate]) -> LinkResolutionResult {
        LinkResolutionResult(requestId: "lookup-request", status: .needsReview, originalLink: SourceLink(url: "https://podcast.example.com/page", provider: "lookup", role: "discovery"), selectedCandidate: candidates.last, candidates: candidates, failureReason: "lookup-review-reason")
    }
}
