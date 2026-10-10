import Foundation
@testable import SessionKit
import XCTest

/// #755: the listener says which episode an imported audio file is, and the link is stored on the file's
/// item. These cover the rule that accepts or refuses the link and how it is stored; the matcher that
/// uses it is covered in `LinkedFileEpisodeMatchTests`.
final class LinkedEpisodeTests: XCTestCase {
    private func importedFile(durationMs: Int? = 1_800_000) -> Item {
        // The shape LocalSourceImporters.importAudiobook writes.
        Item(
            id: "audiobook-1", title: "harbour-lights.m4a", mediaType: "audiobook", text: nil,
            externalReference: "file:///var/mobile/Application%20Support/Audiobooks/audiobook-1.m4a",
            status: "ready", externalReferenceType: "audiobook",
            media: ItemMedia(sourceType: .nativeMediaFile, url: "file:///var/mobile/Audiobooks/audiobook-1.m4a", durationMs: durationMs)
        )
    }

    private func candidate(
        guid: String? = "harbour-lights", audioURL: String? = "https://cdn.example.com/harbour-lights.mp3",
        durationMs: Int? = 1_800_000
    ) -> LinkResolutionCandidate {
        LinkResolutionCandidate(
            sourceLink: SourceLink(url: "https://podcasts.example.com/episodes/harbour-lights"),
            title: " Harbour Lights ", showTitle: "Example Show", durationMs: durationMs,
            publishedAt: "2026-09-29T10:00:00Z", episodeGUID: guid, audioURL: audioURL, confidence: 1
        )
    }

    func testLinkStoresTheEpisodeAndLeavesTheFileAlone() throws {
        let file = importedFile()
        let linked = try ImportedFileEpisodeLink.link(
            file, to: candidate(), pageURL: "https://podcasts.example.com/episodes/harbour-lights"
        )
        XCTAssertEqual(linked.linkedEpisode, LinkedEpisode(
            guid: "harbour-lights", title: "Harbour Lights", showTitle: "Example Show",
            publishedAt: "2026-09-29T10:00:00Z", pageURL: "https://podcasts.example.com/episodes/harbour-lights",
            enclosureURL: "https://cdn.example.com/harbour-lights.mp3", durationMs: 1_800_000
        ))
        var unchanged = linked
        unchanged.linkedEpisode = nil
        XCTAssertEqual(unchanged, file, "only the link is added")
        // The streamed-episode identity fields stay empty, so nothing mistakes the file for a feed episode.
        XCTAssertNil(linked.episodeGUID)
        XCTAssertNil(linked.showTitle)
        XCTAssertEqual(ImportedFileEpisodeLink.unlink(linked), file)
    }

    func testOnlyAnImportedAudioFileCanBeLinked() {
        let streamed = Item(
            id: "audio-url:https://cdn.example.com/a.mp3", title: "A", mediaType: TargetType.transcriptBackedMedia.rawValue,
            text: nil, externalReference: "https://example.com/a", status: "ready", externalReferenceType: "url",
            media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/a.mp3", durationMs: 1_800_000)
        )
        let article = Item(id: "article", title: "Article", mediaType: "text", text: "Words.", externalReference: nil, status: "ready")
        let downloadedNonAudiobook = Item(
            id: "native", title: "Native", mediaType: TargetType.transcriptBackedMedia.rawValue, text: nil,
            externalReference: nil, status: "ready",
            media: ItemMedia(sourceType: .nativeMediaFile, url: "file:///a.m4a", durationMs: 1_800_000)
        )
        for item in [streamed, article, downloadedNonAudiobook] {
            XCTAssertThrowsError(try ImportedFileEpisodeLink.link(item, to: candidate(), pageURL: nil), item.id) {
                XCTAssertEqual($0 as? ImportedFileEpisodeLink.Refusal, .notAnImportedAudioFile, item.id)
            }
        }
    }

    func testAnEpisodeWithNothingToMatchOnIsRefused() {
        // Title, show and length are never enough: they are how the wrong work gets a friend's Margins.
        let bare = LinkResolutionCandidate(
            sourceLink: SourceLink(url: "https://example.com"), title: "Harbour Lights", showTitle: "Example Show",
            durationMs: 1_800_000, publishedAt: "2026-09-29T10:00:00Z", confidence: 1
        )
        for (name, guid, audio, page) in [
            ("nothing", nil, nil, nil), ("blank", "  ", "", "\n"),
        ] as [(String, String?, String?, String?)] {
            var candidate = bare
            candidate.episodeGUID = guid
            candidate.audioURL = audio
            XCTAssertThrowsError(try ImportedFileEpisodeLink.link(importedFile(), to: candidate, pageURL: page), name) {
                XCTAssertEqual($0 as? ImportedFileEpisodeLink.Refusal, .noEpisodeIdentity, name)
            }
        }
        XCTAssertNoThrow(try ImportedFileEpisodeLink.link(importedFile(), to: candidate(guid: nil, audioURL: nil), pageURL: "https://example.com/e"))
        XCTAssertNoThrow(try ImportedFileEpisodeLink.link(importedFile(), to: candidate(guid: "g", audioURL: nil), pageURL: nil))
        XCTAssertNoThrow(try ImportedFileEpisodeLink.link(importedFile(), to: candidate(guid: nil), pageURL: nil))
    }

    func testAFileOfAnotherLengthIsRefused() {
        // Inserted ads move an episode's length by minutes; a different cut, a trailer or a whole other episode moves it more.
        let table: [(file: Int?, episode: Int?, agrees: Bool)] = [
            (1_800_000, 1_800_000, true), (1_800_000, 1_980_000, true), (1_800_000, 1_500_000, true),
            (1_800_000, 2_400_000, false), (1_800_000, 600_000, false), (3_600_000, 1_800_000, false),
            (nil, 1_800_000, true), (1_800_000, nil, true), (0, 1_800_000, true), (1_800_000, 0, true),
        ]
        for row in table {
            let attempt = { try ImportedFileEpisodeLink.link(self.importedFile(durationMs: row.file), to: self.candidate(durationMs: row.episode), pageURL: nil) }
            if row.agrees {
                XCTAssertNoThrow(try attempt(), "\(String(describing: row.file)) vs \(String(describing: row.episode))")
            } else {
                XCTAssertThrowsError(try attempt(), "\(String(describing: row.file)) vs \(String(describing: row.episode))") {
                    XCTAssertEqual($0 as? ImportedFileEpisodeLink.Refusal, .lengthsDisagree)
                }
            }
        }
    }

    func testALinkOnlyCountsWhenItNamesOneEpisode() throws {
        func result(_ status: LinkResolutionStatus, confidence: Double = 0.96, role: String = "canonical_feed") -> LinkResolutionResult {
            var chosen = candidate()
            chosen.confidence = confidence
            chosen.sourceLink.role = role
            chosen.sourceLink.url = "https://feeds.example.com/show.xml"
            return LinkResolutionResult(
                requestId: "r", status: status, originalLink: SourceLink(url: "https://example.com/x"),
                selectedCandidate: status == .playable ? chosen : nil, candidates: [chosen]
            )
        }
        let page = "https://podcasts.example.com/episodes/harbour-lights"
        XCTAssertNotNil(try ImportedFileEpisodeLink.link(importedFile(), resolution: result(.playable), pageURL: page).linkedEpisode)
        XCTAssertNotNil(try ImportedFileEpisodeLink.link(importedFile(), resolution: result(.playable, confidence: 0.9), pageURL: page).linkedEpisode)
        // A show's feed resolves to its first episode at 0.82; Apple's inferred enclosures at 0.78. Neither names an episode.
        for confidence in [0.82, 0.78, 0.3] {
            XCTAssertThrowsError(try ImportedFileEpisodeLink.link(importedFile(), resolution: result(.playable, confidence: confidence), pageURL: page)) {
                XCTAssertEqual($0 as? ImportedFileEpisodeLink.Refusal, .notOneEpisode, "\(confidence)")
            }
        }
        for status in [LinkResolutionStatus.needsReview, .unsupported, .resolving] {
            XCTAssertThrowsError(try ImportedFileEpisodeLink.link(importedFile(), resolution: result(status), pageURL: page)) {
                XCTAssertEqual($0 as? ImportedFileEpisodeLink.Refusal, .couldNotReadLink, "\(status)")
            }
        }
        // The episode a feed link resolved to, with the feed's own address pasted, is the show, however sure the resolver is.
        var feedPick = result(.playable)
        feedPick.selectedCandidate?.sourceLink.url = "https://feeds.example.com/show.xml/"
        XCTAssertThrowsError(try ImportedFileEpisodeLink.link(importedFile(), resolution: feedPick, pageURL: " https://FEEDS.example.com/show.xml ")) {
            XCTAssertEqual($0 as? ImportedFileEpisodeLink.Refusal, .notOneEpisode)
        }
        // An episode page that the resolver found in that feed is fine: the pasted link is the page, not the feed.
        XCTAssertNoThrow(try ImportedFileEpisodeLink.link(importedFile(), resolution: feedPick, pageURL: page))
        // Every refusal says what to do in words a listener reads.
        for refusal in [ImportedFileEpisodeLink.Refusal.notAnImportedAudioFile, .noEpisodeIdentity, .lengthsDisagree, .couldNotReadLink, .notOneEpisode, .hasSharedMargins] {
            XCTAssertFalse((refusal.errorDescription ?? "").isEmpty, "\(refusal)")
        }
    }

    func testTheLinkSurvivesStorageAndOldRecordsStillRead() throws {
        let linked = try ImportedFileEpisodeLink.link(importedFile(), to: candidate(), pageURL: nil)
        let data = try JSONEncoder().encode(linked)
        XCTAssertEqual(try JSONDecoder().decode(Item.self, from: data), linked)
        // An item nobody linked writes the same bytes as before the field existed, so Build 29 opens it.
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(importedFile())) as? [String: Any]
        XCTAssertNil(plain?["linkedEpisode"])
        let stored = try JSONSerialization.data(withJSONObject: plain ?? [:])
        XCTAssertNil(try JSONDecoder().decode(Item.self, from: stored).linkedEpisode)
    }
}
