import Foundation
import XCTest
@testable import SessionKit

/// The Margins tab's Play button on a friend's Margin (#4447). It asked only for a time in the item, so a friend's
/// Margin on an article or PDF, matched at a passage of the listener's text, was listed with a dead button.
final class SharedMarginListPlayTests: XCTestCase {
    private func margin(
        audioPath: String? = "margin.m4a", listenerReadAloud: Bool? = nil, senderMs: Int? = nil,
        _ resolution: ImportedAnchorResolution
    ) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(
            id: "imported-1", layerId: "layer-1", packageScopedId: "pkg::ij-002",
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            anchorEvidence: PortableAnchorEvidence(anchorType: senderMs == nil ? .text : .media, mediaTimeMs: senderMs),
            approvedTranscript: "A thought.", audioPath: audioPath, resolution: resolution,
            listenerReadAloud: listenerReadAloud
        )
    }

    private func layer(
        enabled: Bool = true, deleted: Bool = false, status: ImportedSourceResolutionStatus = .resolved
    ) -> ImportedCommentaryLayer {
        ImportedCommentaryLayer(
            id: "layer-1", itemId: "item-1", packageDigest: "digest", packageId: "package",
            itemIdentity: SharedItemIdentity(itemType: .text, title: "An article"),
            importedAt: Date(timeIntervalSince1970: 1_790_000_000), sourceResolutionStatus: status, isEnabled: enabled,
            deletedAt: deleted ? Date(timeIntervalSince1970: 1_790_000_100) : nil
        )
    }

    func testAnArticleMarginMatchedInTheListenersTextPlaysAtItsPassage() {
        let resolution = ImportedAnchorResolution(evidenceClass: .articleTextVerified, localStartChar: 1_200, localEndChar: 1_260)
        XCTAssertNil(SharedMarginPlaybackPosition(margin(resolution)), "no time in the item: what the old rule asked for")
        XCTAssertEqual(SharedMarginListPlay(margin(resolution)), .textPassage)
        XCTAssertTrue(SharedMarginListPlay.canPlay(margin(resolution), in: layer()))
    }

    func testAPodcastMarginKeepsTheMomentPlayerWhateverItsTextOffset() {
        XCTAssertEqual(SharedMarginListPlay(margin(.init(evidenceClass: .exactEdition, localMediaTimeMs: 33_000))), .moment)
        let both = ImportedAnchorResolution(evidenceClass: .exactEdition, localStartChar: 40, localMediaTimeMs: 5_000)
        XCTAssertEqual(SharedMarginListPlay(margin(both)), .moment)
        XCTAssertEqual(SharedMarginListPlay(margin(senderMs: 302_926, .init(evidenceClass: .unresolved))), .moment,
                       "an unmatched podcast Margin still plays at the sender's time")
    }

    // The neighbours: every shape of place against a recording and against words the voice cannot read.
    func testTheWholeTable() {
        let passage = ImportedAnchorResolution(evidenceClass: .articleTextVerified, localStartChar: 300)
        let rows: [(String, ImportedCommentaryInterjection, SharedMarginListPlay?)] = [
            ("text passage", margin(passage), .textPassage),
            ("text passage at the start", margin(.init(evidenceClass: .articleTextVerified, localStartChar: 0)), .textPassage),
            ("text passage, ambiguous", margin(.init(evidenceClass: .articleTextVerified, localStartChar: 300, isAmbiguous: true)), nil),
            ("text passage, negative", margin(.init(evidenceClass: .articleTextVerified, localStartChar: -1)), nil),
            ("not matched in the text", margin(.init(evidenceClass: .unresolved, localStartChar: 300)), nil),
            ("absent from this copy", margin(.init(evidenceClass: .absentFromRecipientEdition, localStartChar: 300)), nil),
            ("no place at all", margin(.init(evidenceClass: .unresolved)), nil),
            ("podcast time", margin(.init(evidenceClass: .acousticVerified, localMediaTimeMs: 9_000)), .moment),
            ("podcast sender time", margin(senderMs: 9_000, .init(evidenceClass: .unresolved)), .moment),
        ]
        for (name, interjection, expected) in rows {
            XCTAssertEqual(SharedMarginListPlay(interjection), expected, name)
            XCTAssertEqual(SharedMarginListPlay.canPlay(interjection, in: layer()), expected != nil, "\(name): with a recording")
        }
    }

    func testAMarginWithNothingToPlayIsNeverEnabledWhereverItSits() {
        // Words the listener turned reading off for, and no recording: nothing to play, whatever its place.
        for resolution in [ImportedAnchorResolution(evidenceClass: .articleTextVerified, localStartChar: 300),
                           ImportedAnchorResolution(evidenceClass: .exactEdition, localMediaTimeMs: 9_000)] {
            let silent = margin(audioPath: nil, listenerReadAloud: false, resolution)
            XCTAssertFalse(SharedMarginAudio.canOffer(silent))
            XCTAssertNotNil(SharedMarginListPlay(silent), "it has a place")
            XCTAssertFalse(SharedMarginListPlay.canPlay(silent, in: layer()), "\(resolution.evidenceClass)")
        }
    }

    // The audit on 1e7362f: a friend's article Margin on a layer the listener turned off had an enabled Play and a
    // tap that failed. The prompt list a Skim stop uses leaves such a layer out, so the button follows it.
    func testAPassageMarginFollowsItsLayerButATimedMarginPlaysWhateverTheToggle() {
        let passage = margin(.init(evidenceClass: .articleTextVerified, localStartChar: 300))
        let timed = margin(.init(evidenceClass: .exactEdition, localMediaTimeMs: 9_000))
        let layers: [(String, ImportedCommentaryLayer, Bool)] = [
            ("on", layer(), true),
            ("turned off", layer(enabled: false), false),
            ("deleted", layer(deleted: true), false),
            ("matched to the wrong source", layer(status: .wrongSource), false),
            ("still resolving", layer(status: .pending), true),
        ]
        for (name, layer, passageEnabled) in layers {
            XCTAssertEqual(SharedMarginListPlay.canPlay(passage, in: layer), passageEnabled, "passage Margin, layer \(name)")
            XCTAssertTrue(SharedMarginListPlay.canPlay(timed, in: layer), "timed Margin, layer \(name): its moment plays as before")
        }
    }
}
