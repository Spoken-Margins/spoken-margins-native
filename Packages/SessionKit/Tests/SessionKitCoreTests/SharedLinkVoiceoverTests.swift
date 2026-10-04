import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitFeeds

/// #810: a Substack post shared as a link imported as an article but never looked for the post's voiceover,
/// which only followed posts did.
final class SharedLinkVoiceoverTests: XCTestCase {
    private let canonical = URL(string: "https://captured.example/p/voiceover")!

    func testAPostWithACompletedVoiceoverGivesTheRecord() throws {
        let shared = URL(string: "https://captured.example/p/voiceover?r=2abc&utm_campaign=post&utm_medium=ios")!
        let audio = try XCTUnwrap(PublisherNarrationEvidence.publisherAudio(postPage: try Self.page(), finalURL: shared, itemId: "item-1"))
        XCTAssertEqual(audio, PublisherAudio(
            itemId: "item-1", audioURL: "https://recordings.example/voiceover.mp3", durationMs: 752_875,
            detectedFrom: "substack_post_voiceover"
        ))
    }

    func testTheSamePostMatchesWhateverTheCaseOfTheHostOrATrailingSlash() throws {
        let final = URL(string: "https://Captured.EXAMPLE/p/voiceover/#footnote-1")!
        XCTAssertNotNil(PublisherNarrationEvidence.publisherAudio(postPage: try Self.page(), finalURL: final, itemId: "item"))
    }

    func testATextOnlyPostGivesNothing() throws {
        let page = try Self.page().replacingOccurrences(of: #"has_voiceover\":true"#, with: #"has_voiceover\":false"#)
        XCTAssertNil(PublisherNarrationEvidence.publisherAudio(postPage: page, finalURL: canonical, itemId: "item"))
    }

    func testAPodcastPostGivesNothing() throws {
        let page = try Self.page().replacingOccurrences(of: "newsletter", with: "podcast")
        XCTAssertNil(PublisherNarrationEvidence.publisherAudio(postPage: page, finalURL: canonical, itemId: "item"))
    }

    func testAPageWhosePreloadsNameADifferentPostGivesNothing() throws {
        let elsewhere = URL(string: "https://captured.example/p/another-post")!
        XCTAssertNil(PublisherNarrationEvidence.publisherAudio(postPage: try Self.page(), finalURL: elsewhere, itemId: "item"))
        let otherPublication = URL(string: "https://other.example/p/voiceover")!
        XCTAssertNil(PublisherNarrationEvidence.publisherAudio(postPage: try Self.page(), finalURL: otherPublication, itemId: "item"))
    }

    func testAPageWithoutPreloadsGivesNothing() {
        XCTAssertNil(PublisherNarrationEvidence.publisherAudio(postPage: "<html><p>Just text.</p></html>", finalURL: canonical, itemId: "item"))
    }

    func testTheFollowedPathReadsThePageTheSameWay() throws {
        let voiceover = try XCTUnwrap(PublisherNarrationEvidence.voiceover(inPostPage: try Self.page()))
        XCTAssertEqual(voiceover.canonicalURL, canonical.absoluteString)
        XCTAssertEqual(voiceover.audioURL, "https://recordings.example/voiceover.mp3")
        XCTAssertEqual(voiceover.durationMs, 752_875)
    }

    func testOnlySubstackAddressesAreFetched() {
        for yes in [
            "https://open.substack.com/pub/garymarcus/p/breaking?r=2abc&utm_medium=ios",
            "https://garymarcus.substack.com/p/breaking",
            "https://substack.com/home/post/p-123",
            "https://GaryMarcus.Substack.com/p/breaking"
        ] {
            XCTAssertTrue(PublisherNarrationEvidence.mayHaveVoiceover(URL(string: yes)!), yes)
        }
        for no in [
            "http://garymarcus.substack.com/p/breaking",
            "https://evilsubstack.com/p/breaking",
            "https://substack.com.evil.example/p/breaking",
            "https://www.platformer.news/p/breaking",
            "https://example.com/article"
        ] {
            XCTAssertFalse(PublisherNarrationEvidence.mayHaveVoiceover(URL(string: no)!), no)
        }
    }

    private static func page() throws -> String {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("Contracts").path) {
            let parent = root.deletingLastPathComponent()
            guard parent != root else { throw CocoaError(.fileNoSuchFile) }
            root = parent
        }
        let url = root.appendingPathComponent("Contracts/fixtures/feeds/substack-voiceover-page.html")
        return String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }
}
