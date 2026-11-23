import XCTest
@testable import SessionKit

/// #4640: the header line and the Reading voice row, word for word.
final class PublisherAudioAttributionTests: XCTestCase {
    func testEachSourceGivesItsLine() {
        for source in ["article_feed_enclosure", "feed_enclosure", "substack_post_voiceover", "substack_post_generated_voice"] {
            XCTAssertEqual(PublisherAudioAttribution.headerLine(source: source, siteHost: "example.com"), "Publisher's audio · example.com", source)
        }
        XCTAssertEqual(PublisherAudioAttribution.headerLine(source: "type3_audio_narration", siteHost: "lesswrong.com"), "Narration by Type III Audio")
        XCTAssertNil(PublisherAudioAttribution.headerLine(source: nil, siteHost: "example.com"), "the app's voice: no line")
        XCTAssertNil(PublisherAudioAttribution.headerLine(source: "something_new", siteHost: "example.com"))
    }

    func testWithNoSiteTheLineIsPublishersAudioAlone() {
        XCTAssertEqual(PublisherAudioAttribution.headerLine(source: "article_feed_enclosure", siteHost: nil), "Publisher's audio")
        XCTAssertEqual(PublisherAudioAttribution.headerLine(source: "article_feed_enclosure", siteHost: ""), "Publisher's audio")
    }

    func testTheSiteIsLowerCasedWithoutWWW() {
        XCTAssertEqual(PublisherAudioAttribution.siteName(fromOriginalLink: "https://WWW.Example.COM/posts/a?x=1"), "example.com")
        XCTAssertEqual(PublisherAudioAttribution.siteName(fromOriginalLink: "https://news.example.com/a"), "news.example.com")
        XCTAssertEqual(PublisherAudioAttribution.siteName(fromOriginalLink: "https://wwwexample.com/a"), "wwwexample.com")
        XCTAssertNil(PublisherAudioAttribution.siteName(fromOriginalLink: nil))
        XCTAssertNil(PublisherAudioAttribution.siteName(fromOriginalLink: "not a link"))
        XCTAssertEqual(PublisherAudioAttribution.headerLine(source: "substack_post_voiceover", siteHost: "WWW.Example.com"), "Publisher's audio · example.com")
    }

    func testTheReadingVoiceRowStates() {
        let a = PublisherAudioAttribution.voiceRow(playingSource: "article_feed_enclosure", recordSource: "article_feed_enclosure", siteHost: "example.com", hasReadyMap: true)
        XCTAssertEqual(a, .init(title: "Reading voice", value: "Publisher's audio · example.com",
                                subtitle: "Your Margins stay on the article's words.", button: .useAppVoice))
        let typeIII = PublisherAudioAttribution.voiceRow(playingSource: "type3_audio_narration", recordSource: "type3_audio_narration", siteHost: "lesswrong.com", hasReadyMap: true)
        XCTAssertEqual(typeIII?.value, "Narration by Type III Audio")

        let b = PublisherAudioAttribution.voiceRow(playingSource: nil, recordSource: "substack_post_voiceover", siteHost: "example.com", hasReadyMap: true)
        XCTAssertEqual(b, .init(title: "Reading voice", value: "The app's voice",
                                subtitle: "This article also has the publisher's audio.", button: .playPublisherAudio))

        XCTAssertNil(PublisherAudioAttribution.voiceRow(playingSource: nil, recordSource: "substack_post_voiceover", siteHost: nil, hasReadyMap: false), "no ready map")
        XCTAssertNil(PublisherAudioAttribution.voiceRow(playingSource: nil, recordSource: nil, siteHost: nil, hasReadyMap: false), "no record")
        XCTAssertNil(PublisherAudioAttribution.voiceRow(playingSource: nil, recordSource: "unknown", siteHost: nil, hasReadyMap: true))
        XCTAssertEqual(PublisherAudioAttribution.voiceRow(playingSource: "article_feed_enclosure", recordSource: nil, siteHost: nil, hasReadyMap: true)?.value, "Publisher's audio")
    }

    func testButtonsCarryTheirMeaningInWords() {
        XCTAssertEqual(PublisherAudioAttribution.VoiceRowButton.useAppVoice.label, "Use the App's Voice")
        XCTAssertEqual(PublisherAudioAttribution.VoiceRowButton.playPublisherAudio.label, "Play Publisher's Audio")
        XCTAssertEqual(PublisherAudioAttribution.VoiceRowButton.useAppVoice.systemImage, "waveform")
        XCTAssertEqual(PublisherAudioAttribution.VoiceRowButton.playPublisherAudio.systemImage, "person.wave.2")
    }
}
