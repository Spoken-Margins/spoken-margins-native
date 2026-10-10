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

    /// Every redirect service in the list unwraps to the file behind it. The address after each
    /// service is how that service writes it: some put one opaque token (a show or campaign id)
    /// in front of the file's host, most don't. One wrong count drops the file's host or keeps the
    /// token, and the sender's and the recipient's keys for the same file stop matching, so the
    /// shared Margin is not placed.
    func testEveryRedirectServiceUnwrapsToTheFileBehindIt() {
        let services: [(wrapper: String, token: String?)] = [
            ("podtrac.com/pts/redirect.mp3", nil),
            ("dts.podtrac.com/redirect.mp3", nil),
            ("dts.podtrac.com/redirect.m4a", nil),
            ("www.podtrac.com/pts/redirect.mp3", nil),
            ("tracking.swap.fm/track", "UVBrz8bN8aM2Xe47PEPu"),
            ("chtbl.com/track", "ABC123"),
            ("pdst.fm/e", nil),
            ("pscrb.fm/rss/p", nil),
            ("verifi.podscribe.com/rss/p", nil),
            ("arttrk.com/p", "K1E2Y"),
            ("pfx.vpixl.com", "9f8e7d"),
            ("mgln.ai/e", "xyz789"),
            ("claritaspod.com/measure", nil),
            ("op3.dev/e", nil),
            ("prfx.byspotify.com/e", nil),
            ("prefix.up.audio/s", nil)
        ]
        let direct = "https://\(omnyFile)"
        let other = "https://\(omnyFile.replacingOccurrences(of: "audio.mp3", with: "another.mp3"))"
        for (wrapper, token) in services {
            let front = "\(wrapper)/" + (token.map { "\($0)/" } ?? "")
            for form in ["https://\(front)\(omnyFile)", "http://\(front)\(omnyFile)?utm_source=feed",
                         "https://\(front)https://\(omnyFile)", "https://\(front.uppercased())\(omnyFile)"] {
                XCTAssertEqual(PodcastEnclosureIdentity.key(form), omnyFile, form)
                XCTAssertTrue(PodcastEnclosureIdentity.sameFile(form, direct), form)
                XCTAssertFalse(PodcastEnclosureIdentity.sameFile(form, other), "another file behind the same service: \(form)")
            }
        }
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
