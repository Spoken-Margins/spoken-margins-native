import Foundation
@testable import SessionKit
import XCTest

/// #2506: recovery finds the Library item for a feed episode from summaries, then reads only those items whole.
/// The candidate list must never leave out an item the full rule (audio link, or GUID plus title) would keep.
final class RecoveredEpisodeCandidatesTests: XCTestCase {
    private func summary(_ id: String, title: String, audio: String? = nil) -> LibraryItemSummary {
        LibraryItemSummary(id: id, title: title, mediaType: "transcript_backed_media", status: "ready",
                           media: audio.map { ItemMedia(sourceType: .remoteStream, url: $0) },
                           hasListenableText: false, textCharacterCount: nil)
    }

    private func entry(title: String = "Episode 12", audio: String? = "https://cdn.example/12.mp3", guid: String? = "g-12") -> FeedEntry {
        FeedEntry(id: "e", subscriptionId: "s", canonicalURL: "https://show.example", audioURL: audio, title: title, episodeGUID: guid)
    }

    func testTheAudioLinkNamesTheEpisodeWhateverTheTitle() {
        let items = [summary("a", title: "Renamed", audio: "https://cdn.example/12.mp3"), summary("b", title: "Other", audio: "https://cdn.example/9.mp3")]
        XCTAssertEqual(entry(guid: nil).recoveryCandidateItemIDs(among: items), ["a"])
    }

    func testAGUIDNeedsTheTitleBesideItAndTitlesCompareWithoutCaseOrOuterSpace() {
        let items = [summary("a", title: "  episode 12 "), summary("b", title: "Episode 120"), summary("c", title: "Episode 12")]
        XCTAssertEqual(entry(audio: nil).recoveryCandidateItemIDs(among: items), ["a", "c"])
    }

    func testAnEntryWithNeitherLinkNorGUIDMatchesNothingByTitle() {
        let items = [summary("a", title: "Episode 12")]
        XCTAssertEqual(entry(audio: nil, guid: nil).recoveryCandidateItemIDs(among: items), [])
    }

    func testOrderFollowsTheSummariesAndNeighbouringAudioLinksDoNotMatch() {
        let items = [summary("a", title: "Episode 12"), summary("b", title: "x", audio: "https://cdn.example/12.mp3"),
                     summary("c", title: "y", audio: "https://cdn.example/12.mp3?x=1")]
        XCTAssertEqual(entry().recoveryCandidateItemIDs(among: items), ["a", "b"])
    }
}
