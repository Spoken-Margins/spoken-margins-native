import Foundation
import SessionKit
import XCTest
@testable import SpokenMarginsApp

/// Pins the persisted raw values, strings and defaults of the value types that lived at the top of
/// Gate1AppModel.swift (#964). Values that Build 29 wrote to UserDefaults must still decode, and the
/// text the listener reads must not drift when a type moves to another file.
final class Gate1ValueTypeContractTests: XCTestCase {
    func testPersistedRawValuesDoNotChange() {
        // Kitten (#2226) joined after the three Build 29 wrote; their spelling and the picker order are unchanged.
        XCTAssertEqual(AppTTSVoiceSelection.allCases.map(\.rawValue), ["supertonic:M2", "supertonic:F2", "kitten:jasper", "system"])
        XCTAssertEqual(AppTTSVoiceSelection.allCases.map(\.rawValue), ReadingVoiceChoice.allCases.map(\.rawValue),
                       "the app's list and SessionKit's host-tested one are the same list")
        XCTAssertEqual(AIDataSharingConsent(rawValue: "unknown"), .unknown)
        XCTAssertEqual(AIDataSharingConsent(rawValue: "grantedV1"), .grantedV1)
        XCTAssertEqual(AIDataSharingConsent(rawValue: "declined"), .declined)
        XCTAssertEqual(BatchSessionExportFilter.withInterjections.rawValue, "with_interjections")
        XCTAssertEqual(BatchSessionExportFilter.all.rawValue, "all")
        XCTAssertEqual(
            [NativeTextStartupAudioState.notRequired, .waiting, .preparing, .ready, .paused, .failed].map(\.rawValue),
            ["not_required", "waiting", "preparing", "ready", "paused", "failed"])
        XCTAssertEqual(ImportInboxEntry.Kind.sourceLink.rawValue, "sourceLink")
        XCTAssertEqual(ImportInboxEntry.Kind.browserText.rawValue, "browserText")
        XCTAssertEqual(SummaryBridgeRatePolicy.cacheVersion, "natural-rate-v2")
    }

    func testLibraryRowSymbolFollowsMediaTypeWithoutCase() {
        func symbol(_ type: String) -> String {
            LibraryItemRow(id: type, title: type, status: "ready", canDelete: true, mediaType: type).mediaSymbol
        }
        for type in ["podcast", "Podcast", "AUDIO", "audiobook", "m4a", "M4B", "mp3"] {
            XCTAssertEqual(symbol(type), "headphones", type)
        }
        XCTAssertEqual(symbol("pdf"), "doc.richtext")
        XCTAssertEqual(symbol("PDF"), "doc.richtext")
        XCTAssertEqual(symbol("epub"), "book.closed")
        XCTAssertEqual(symbol("EPUB"), "book.closed")
        XCTAssertEqual(symbol("text"), "doc.text")
        XCTAssertEqual(symbol("something-new"), "doc.text")
    }

    func testLibraryRowInitClampsCountsAndDefaultsRecencyRank() {
        let negative = LibraryItemRow(
            id: "a", title: "A", status: "ready", canDelete: true,
            startupAudioCompletedChunkCount: -3, startupAudioTargetChunkCount: -1)
        XCTAssertEqual(negative.startupAudioCompletedChunkCount, 0)
        XCTAssertEqual(negative.startupAudioTargetChunkCount, 0)
        XCTAssertEqual(negative.storageRecencyRank, Int.max)
        let counted = LibraryItemRow(
            id: "b", title: "B", status: "ready", canDelete: true,
            startupAudioCompletedChunkCount: 1, startupAudioTargetChunkCount: 2)
        XCTAssertEqual(counted.startupAudioCompletedChunkCount, 1)
        XCTAssertEqual(counted.startupAudioTargetChunkCount, 2)
        XCTAssertEqual(counted.startupAudioState, .notRequired)
        XCTAssertEqual(counted.offlineState, .onlineOnly)
        XCTAssertEqual(counted.mediaType, "text")
    }

    func testQueueRowProgressIsZeroWithoutAPlanAndNeverAboveOne() {
        func progress(done: Int, planned: Int) -> Double {
            AudioPreparationQueueRow(
                id: "job", itemId: "item", title: "Title", policy: .explicit, state: .preparing,
                completedChunkCount: done, plannedChunkCount: planned,
                requestedAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
                failureCode: nil, isActivePlaybackItem: false, canMoveEarlier: false, canMoveLater: false
            ).progress
        }
        XCTAssertEqual(progress(done: 3, planned: 0), 0)
        XCTAssertEqual(progress(done: 1, planned: 4), 0.25)
        XCTAssertEqual(progress(done: 9, planned: 4), 1)
    }

    func testSourceFileImportErrorMessagesAreTheListenerFacingOnes() {
        XCTAssertEqual(
            SourceFileImportError.pdfHasNoExtractableText.errorDescription,
            "This PDF is only pictures of pages, so there is no text to read aloud. Try a PDF you can select text in.")
        XCTAssertEqual(
            SourceFileImportError.pdfImportUnavailable.errorDescription,
            "PDF text extraction is unavailable in this build.")
        XCTAssertEqual(
            SourceFileImportError.remotePDFInvalidResponse.errorDescription,
            "The shared link did not return a readable PDF.")
        XCTAssertEqual(
            SourceFileImportError.remotePDFTooLarge.errorDescription,
            "This PDF is larger than the 50 MB import limit.")
    }

    func testAmbiguousSourceLinkResolverAnswersWithTwoCandidatesForReview() throws {
        let request = LinkResolutionRequest(
            id: "request-1", inputURL: "https://open.spotify.com/episode/x", sourceSurface: "test",
            createdAt: Date(timeIntervalSince1970: 0))
        let result = try UITestingAmbiguousSourceLinkResolver().resolve(request)
        XCTAssertEqual(result.status, .needsReview)
        XCTAssertEqual(result.requestId, "request-1")
        XCTAssertEqual(result.failureReason, "spotify_episode_match_ambiguous")
        XCTAssertEqual(result.candidates.map(\.title), ["Ambiguous Episode One", "Ambiguous Episode Two"])
    }

    func testVoiceSelectionNamesAndDetailsKeepTheirText() {
        XCTAssertEqual(AppTTSVoiceSelection.james.displayName, "James")
        XCTAssertEqual(AppTTSVoiceSelection.lily.displayName, "Lily")
        XCTAssertEqual(AppTTSVoiceSelection.kitten.displayName, "Kitten (Jasper)")
        XCTAssertEqual(AppTTSVoiceSelection.system.displayName, "iOS System Voice")
        // U+00B7 MIDDLE DOT, written as an escape so retyping the file can't change it.
        XCTAssertEqual(AppTTSVoiceSelection.james.detail, "Deep, calm \u{00B7} M2")
        XCTAssertEqual(AppTTSVoiceSelection.lily.detail, "Bright, cheerful \u{00B7} F2")
        XCTAssertEqual(AppTTSVoiceSelection.kitten.detail, "Built into the app \u{00B7} no download")
        XCTAssertEqual(AppTTSVoiceSelection.system.detail, "Uses the selected voice installed in iOS")
    }
}
