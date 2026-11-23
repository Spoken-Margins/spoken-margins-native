import XCTest
@testable import SessionKit

/// #4640: one gate for every new publisher-audio record, and the narration-fit rule.
final class PublisherAudioAdmissionTests: XCTestCase {
    private func audio(_ url: String, _ source: String) -> PublisherAudio {
        PublisherAudio(itemId: "item", audioURL: url, detectedFrom: source)
    }

    func testEachSourcesOwnAddressIsAdmitted() {
        let admitted: [(String, String)] = [
            ("https://substack-post-media.s3.amazonaws.com/a.mp3", "feed_enclosure"),
            ("https://api.substack.com/feed/podcast/1/a.mp3", "substack_post_voiceover"),
            ("https://api.substack.com/feed/podcast/1/tts.mp3", "substack_post_generated_voice"),
            ("https://dl.type3.audio/episode/abc.mp3", "type3_audio_narration"),
            ("https://type3.audio/abc.mp3", "type3_audio_narration"),
            ("https://media.example.com/posts/kettleness.mp3", "article_feed_enclosure"),
            // Shipped Substack addresses carry a token, and keep playing.
            ("https://api.substack.com/feed/podcast/1/a.mp3?token=abc", "substack_post_voiceover"),
        ]
        for (url, source) in admitted {
            XCTAssertEqual(try? PublisherAudioAdmission.admit(audio(url, source)).get(), audio(url, source), "\(source) \(url)")
        }
    }

    func testRefusals() {
        let refused: [(String, String, PublisherAudioRefusal)] = [
            ("http://media.example.com/a.mp3", "article_feed_enclosure", .notHTTPS),
            ("ftp://media.example.com/a.mp3", "substack_post_voiceover", .notHTTPS),
            ("https:///a.mp3", "substack_post_voiceover", .notHTTPS),
            ("https://user:pass@media.example.com/a.mp3", "article_feed_enclosure", .userinfo),
            ("https://media.example.com:8443/a.mp3", "substack_post_voiceover", .port),
            ("https://dl.type3.audio:443/a.mp3", "type3_audio_narration", .port),
            ("https://media.example.com/a.mp3", "substack_voiceover", .unknownSource),
            ("https://media.example.com/a.mp3", "", .unknownSource),
            ("https://example.com/a.mp3", "type3_audio_narration", .hostNotAllowed),
            ("https://nottype3.audio/a.mp3", "type3_audio_narration", .hostNotAllowed),
            ("https://type3.audio.example.com/a.mp3", "type3_audio_narration", .hostNotAllowed),
            ("https://media.example.com/a.mp3?X-Amz-Signature=abc", "article_feed_enclosure", .signedURL),
            ("https://media.example.com/a.mp3?Expires=1&Key-Pair-Id=k", "article_feed_enclosure", .signedURL),
            ("https://media.example.com/a.mp3?token=abc", "article_feed_enclosure", .signedURL),
            ("https://media.example.com/a.mp3?hdnts=exp", "article_feed_enclosure", .signedURL),
        ]
        for (url, source, refusal) in refused {
            switch PublisherAudioAdmission.admit(audio(url, source)) {
            case .success: XCTFail("admitted \(source) \(url)")
            case .failure(let got): XCTAssertEqual(got, refusal, "\(source) \(url)")
            }
        }
    }

    func testAnUnsignedQueryIsAdmittedOnTheFeedRoute() {
        XCTAssertNoThrow(try PublisherAudioAdmission.admit(audio("https://media.example.com/a.mp3?utm_source=rss", "article_feed_enclosure")).get())
    }

    /// The raw values are stored in every user's database: they must never change.
    func testRawValuesAreTheStoredStrings() {
        XCTAssertEqual(PublisherAudioSource.allCases.map(\.rawValue), [
            "feed_enclosure", "substack_post_voiceover", "substack_post_generated_voice", "type3_audio_narration", "article_feed_enclosure",
        ])
        for source in PublisherAudioSource.allCases { XCTAssertFalse(source.rightsBasis.isEmpty) }
        XCTAssertEqual(PublisherAudioSource.allCases.filter(\.refusesSignedURLs), [.articleFeedEnclosure])
    }

    // MARK: - Narration fit

    func testNarrationFitEdges() {
        // 900 words at 150 a minute is 6 minutes: 360,000 ms. 0.4× = 144,000; 2× = 720,000.
        let cases: [(Int?, Int?, Int?, PublisherAudioNarrationFit.Verdict?)] = [
            (144_000, nil, 900, .fits),
            (143_999, nil, 900, .tooShort),
            (720_000, nil, 900, .fits),
            (720_001, nil, 900, .tooLong),
            (360_000, nil, 900, .fits),
            (45 * 60_000, nil, 900, .tooLong),
            (nil, 20_000_000, 900, .fits),
            (nil, 150 * 1_024 * 1_024, nil, .fits),
            (nil, 150 * 1_024 * 1_024 + 1, nil, .tooLong),
            (nil, 0, 900, nil),
            (nil, nil, 900, nil),
            (360_000, nil, nil, nil),
            (360_000, 5_000_000, nil, .fits),
            (0, nil, 900, nil),
        ]
        for (duration, length, words, expected) in cases {
            XCTAssertEqual(PublisherAudioNarrationFit.verdict(durationMs: duration, lengthBytes: length, wordCount: words), expected,
                           "duration \(String(describing: duration)) length \(String(describing: length)) words \(String(describing: words))")
        }
    }
}
