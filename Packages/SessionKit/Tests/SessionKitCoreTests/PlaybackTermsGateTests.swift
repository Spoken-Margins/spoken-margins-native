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

    /// Every kind of media an item can have, once. A browser-owned item (a page's own player) is recorded audio, and a
    /// live-voice item is text read by the app's voice, so the first opens no Terms sheet and the second does.
    func testWhetherJamesPendingGatesAnItemFollowsItsMediaSourceType() {
        let table: [(AudioSourceType, gated: Bool)] = [
            (.nativeMediaFile, false),
            (.remoteStream, false),
            (.browserOwnedMedia, false),
            (.generatedTTSRealtime, true),
            (.generatedTTSPrerendered, true),
        ]
        // Adding a source type stops this switch compiling until the table above says what the Terms do with it.
        for (sourceType, _) in table {
            switch sourceType {
            case .nativeMediaFile, .remoteStream, .browserOwnedMedia, .generatedTTSRealtime, .generatedTTSPrerendered: break
            }
        }
        for (sourceType, gated) in table {
            let item = Item(
                id: "item", title: "An item", mediaType: "text", text: "Some words.", externalReference: nil, status: "ready",
                media: ItemMedia(sourceType: sourceType)
            )
            XCTAssertEqual(PlaybackTermsGate.requiresTerms(for: item, termsAccepted: false, bundledVoicePending: true), gated,
                           "\(sourceType.rawValue)")
            XCTAssertEqual(PlaybackTermsGate.playsRecordedAudio(item), !gated, "\(sourceType.rawValue)")
            XCTAssertFalse(PlaybackTermsGate.requiresTerms(for: item, termsAccepted: false, bundledVoicePending: false),
                           "\(sourceType.rawValue): without a bundled voice pending nothing is gated")
            XCTAssertFalse(PlaybackTermsGate.requiresTerms(for: item, termsAccepted: true, bundledVoicePending: true),
                           "\(sourceType.rawValue): accepted Terms gate nothing")
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

    /// #2853: a first Play gets the short screen; a voice the listener picks in Settings, and rereading, get the whole Terms.
    func testAFirstPlayWaitingOnTheTermsGetsTheSummaryAndEverythingElseTheCompleteTerms() {
        XCTAssertEqual(PlaybackTermsGate.presentation(playbackIsWaiting: true, termsAccepted: false), .summary)
        XCTAssertEqual(PlaybackTermsGate.presentation(playbackIsWaiting: false, termsAccepted: false), .complete, "picked in Settings")
        XCTAssertEqual(PlaybackTermsGate.presentation(playbackIsWaiting: true, termsAccepted: true), .complete)
        XCTAssertEqual(PlaybackTermsGate.presentation(playbackIsWaiting: false, termsAccepted: true), .complete)
    }

    /// #2506: the Play tap reads the item's summary, not the item, so the gate must answer the same for both.
    func testASummaryIsGatedExactlyLikeTheItemItCameFrom() {
        for item in [podcast, downloaded, article, spokenArticle] {
            let summary = LibraryItemSummary(item)
            for (accepted, pending) in [(false, true), (false, false), (true, true), (true, false)] {
                XCTAssertEqual(
                    PlaybackTermsGate.requiresTerms(for: summary, termsAccepted: accepted, bundledVoicePending: pending),
                    PlaybackTermsGate.requiresTerms(for: item, termsAccepted: accepted, bundledVoicePending: pending),
                    "\(item.id) accepted=\(accepted) pending=\(pending)")
            }
            XCTAssertEqual(PlaybackTermsGate.playsRecordedAudio(summary), PlaybackTermsGate.playsRecordedAudio(item), item.id)
        }
    }

    func testTheItemIsOnlyWorthReadingWhileTheTermsAreOpenAndAVoiceIsWaiting() {
        XCTAssertTrue(PlaybackTermsGate.mayRequireTerms(termsAccepted: false, bundledVoicePending: true))
        XCTAssertFalse(PlaybackTermsGate.mayRequireTerms(termsAccepted: true, bundledVoicePending: true))
        XCTAssertFalse(PlaybackTermsGate.mayRequireTerms(termsAccepted: false, bundledVoicePending: false))
        XCTAssertFalse(PlaybackTermsGate.mayRequireTerms(termsAccepted: true, bundledVoicePending: false))
    }
}
