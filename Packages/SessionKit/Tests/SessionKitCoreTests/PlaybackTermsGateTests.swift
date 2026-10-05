import Foundation
import XCTest
@testable import SessionKit

/// #781: the first Play of anything, a podcast included, opened the Terms sheet. The Terms cover only text
/// read by James or Lily.
final class PlaybackTermsGateTests: XCTestCase {
    private let podcast = Item(
        id: "episode", title: "An episode", mediaType: "audio", text: nil, externalReference: nil, status: "ready",
        media: ItemMedia(sourceType: .remoteStream, url: "https://example.com/episode.mp3")
    )
    private let downloaded = Item(
        id: "file", title: "A recording", mediaType: "audio", text: nil, externalReference: nil, status: "ready",
        media: ItemMedia(sourceType: .nativeMediaFile, nativeMediaId: "asset-1")
    )
    private let article = Item(
        id: "article", title: "An article", mediaType: "text", text: "Some words.", externalReference: nil, status: "ready"
    )
    private let spokenArticle = Item(
        id: "spoken", title: "A spoken article", mediaType: "text", text: "Some words.", externalReference: nil, status: "ready",
        media: ItemMedia(sourceType: .generatedTTSPrerendered)
    )

    func testAPodcastIsNeverGatedEvenWithJamesPending() {
        for item in [podcast, downloaded] {
            XCTAssertFalse(PlaybackTermsGate.requiresTerms(for: item, termsAccepted: false, bundledVoicePending: true), item.id)
        }
    }

    func testAnArticleWithJamesPendingIsGated() {
        for item in [article, spokenArticle] {
            XCTAssertTrue(PlaybackTermsGate.requiresTerms(for: item, termsAccepted: false, bundledVoicePending: true), item.id)
        }
    }

    func testAnArticleWithTheIPhoneVoiceIsNotGated() {
        XCTAssertFalse(PlaybackTermsGate.requiresTerms(for: article, termsAccepted: false, bundledVoicePending: false))
    }

    func testOnceTheTermsAreAcceptedNothingIsGated() {
        for item in [podcast, downloaded, article, spokenArticle] {
            XCTAssertFalse(PlaybackTermsGate.requiresTerms(for: item, termsAccepted: true, bundledVoicePending: true), item.id)
        }
        XCTAssertFalse(PlaybackTermsGate.requiresTerms(for: nil, termsAccepted: true, bundledVoicePending: true))
    }

    func testAnItemThatCantBeLoadedKeepsTheGate() {
        XCTAssertTrue(PlaybackTermsGate.requiresTerms(for: nil, termsAccepted: false, bundledVoicePending: true))
    }
}
