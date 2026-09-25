import XCTest
@testable import SessionKit

final class PodcastEnclosureIdentityTests: XCTestCase {
    private let omnyFile = "traffic.omny.fm/d/clips/e73c998e-6e60-432f-8610-ae210140c5b1/8a94442e-5a74-4fa2-8b8d-ae27003a8d6b/77d27e49-f26e-4c79-8913-b4cf01192cf5/audio.mp3"

    func testTrackingRedirectsAndQueriesUnwrapToTheSameFile() {
        let packet = "https://podtrac.com/pts/redirect.mp3/tracking.swap.fm/track/UVBrz8bN8aM2Xe47PEPu/\(omnyFile)?utm_source=Podcast&in_playlist=982f5071"
        let direct = "https://\(omnyFile)"
        let otherTracker = "https://dts.podtrac.com/redirect.mp3/chtbl.com/track/ABC123/\(omnyFile)?utm_source=Apple"
        XCTAssertEqual(PodcastEnclosureIdentity.key(packet), omnyFile)
        XCTAssertTrue(PodcastEnclosureIdentity.sameFile(packet, direct))
        XCTAssertTrue(PodcastEnclosureIdentity.sameFile(packet, otherTracker))
    }

    func testDifferentEpisodesInTheSameFeedStayDifferent() {
        let hollywood = "https://podtrac.com/pts/redirect.mp3/tracking.swap.fm/track/X/\(omnyFile)"
        let strikes = hollywood.replacingOccurrences(of: "77d27e49-f26e-4c79-8913-b4cf01192cf5", with: "108c6d5b-0564-4c56-a502-b059015ea18f")
        XCTAssertFalse(PodcastEnclosureIdentity.sameFile(hollywood, strikes))
    }

    func testMissingOrInvalidURLsNeverMatch() {
        XCTAssertFalse(PodcastEnclosureIdentity.sameFile(nil, nil))
        XCTAssertFalse(PodcastEnclosureIdentity.sameFile("not a url", "not a url"))
        XCTAssertNil(PodcastEnclosureIdentity.key("ftp://example.com/a.mp3"))
    }
}

final class LinkResolutionArticleFallbackTests: XCTestCase {
    private func result(status: LinkResolutionStatus, reason: String?, audioURL: String?) -> LinkResolutionResult {
        let candidate = LinkResolutionCandidate(
            sourceLink: SourceLink(url: "https://en.wikipedia.org/wiki/Marginalia", provider: "en.wikipedia.org", role: "discovery"),
            title: "Marginalia",
            audioURL: audioURL,
            confidence: 0.3
        )
        return LinkResolutionResult(
            requestId: "r",
            status: status,
            originalLink: candidate.sourceLink,
            selectedCandidate: nil,
            candidates: [candidate],
            failureReason: reason
        )
    }

    func testAPageWithNoAudioIsOfferedToTheArticleReader() {
        XCTAssertTrue(result(status: .needsReview, reason: "audio_enclosure_not_found", audioURL: nil).foundNoAudio)
    }

    func testPodcastReviewAndAmbiguityAreNotTreatedAsArticles() {
        XCTAssertFalse(result(status: .needsReview, reason: "audio_enclosure_not_found", audioURL: "https://cdn.example.com/a.mp3").foundNoAudio)
        XCTAssertFalse(result(status: .needsReview, reason: "rss_episode_ambiguous", audioURL: nil).foundNoAudio)
        XCTAssertFalse(result(status: .needsReview, reason: "spotify_specific_episode_required", audioURL: nil).foundNoAudio)
    }
}
