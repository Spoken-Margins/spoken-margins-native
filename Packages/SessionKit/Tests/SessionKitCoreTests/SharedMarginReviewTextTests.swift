import Foundation
import XCTest
@testable import SessionKit

/// #5409: a friend's Margins on an article, PDF or book are placed by characters and have no time in any media. The
/// review left them out (`SharedMarginReview.entry(for:)` returned nil for `.placed(nil)`), so the item screen showed no
/// "From …" intro, no "Hear the replies" and no catch-up, while the Library row and the Margins tab counted them as new.
final class SharedMarginReviewTextTests: XCTestCase {
    private let early = Date(timeIntervalSince1970: 1_700_000_000)
    private let clock = MarginMomentClock.liveNarration

    private func layer(_ id: String, type: SharedItemType = .text, label: String? = "Ana") -> ImportedCommentaryLayer {
        ImportedCommentaryLayer(
            id: id, itemId: "item", packageDigest: "digest-\(id)", packageId: "package-\(id)",
            itemIdentity: SharedItemIdentity(itemType: type, title: "Marginalia"),
            displayLabel: label, importedAt: early, sourceResolutionStatus: .resolved, isEnabled: true, isMuted: false
        )
    }

    /// As a text import places one: a verified place in the listener's copy of the text, no media time.
    private func textMargin(
        _ id: String, in layerId: String = "ana", char: Int?, evidence: AnchorResolutionEvidenceClass = .articleTextVerified,
        heard: Bool = false, replyLinks: [MarginReplyLink]? = nil
    ) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(
            id: id, layerId: layerId, packageScopedId: id, createdAt: early,
            anchorEvidence: PortableAnchorEvidence(anchorType: .text, startChar: char), approvedTranscript: "Words",
            audioPath: "ImportedCommentary/\(id).m4a", audioDurationMs: 4_000,
            resolution: ImportedAnchorResolution(evidenceClass: evidence, localStartChar: char, localEndChar: char.map { $0 + 20 }, confidence: 1),
            firstHeardAt: heard ? early : nil, replyLinks: replyLinks
        )
    }

    private func ownTextMargin(_ id: String, char: Int, sharedAs: [MarginPacketIdentity]) -> Interjection {
        Interjection(
            id: id, itemId: "item", sessionId: "s", targetType: .item, targetId: "item", createdAt: early, roughPercent: 0,
            anchor: Anchor(anchorType: .text, startChar: char, endChar: char + 20, anchorBefore: "", anchorAfter: "", mediaTimeMs: nil),
            audioPath: "\(id).m4a", audioStatus: "ready", transcriptionStatus: "complete", transcript: "Mine", cleanedTranscript: nil,
            displayText: "Mine", status: "active", sharedAs: sharedAs
        )
    }

    func testAFriendsMarginsOnAnArticleAreOfferedAtTheirPlaceInTheReading() {
        for type in [SharedItemType.text, .pdf, .epub] {
            let entries = SharedMarginReview.entries(
                layers: [layer("ana", type: type)],
                records: ["ana": [textMargin("later", char: 4_200), textMargin("first", char: 350), textMargin("heard", char: 900, heard: true)]]
            )
            XCTAssertEqual(entries.map(\.interjection.id), ["first", "later"], "\(type): new Margins in reading order")
            XCTAssertEqual(entries.map(\.textOffset), [350, 4_200], "\(type)")
            XCTAssertEqual(
                entries.map(\.mediaTimeMs), [clock.position(forTextOffset: 350), clock.position(forTextOffset: 4_200)],
                "\(type): each at its place on the narrated-text clock a moment on text read aloud counts on (#1577)")
            XCTAssertTrue(entries.allSatisfy { $0.isPlacedInText && !$0.isApproximate && !$0.playsAfterOthers }, "\(type)")
        }
    }

    func testAMarginWithNoVerifiedPlaceInTheTextIsStillNotOffered() {
        let entries = SharedMarginReview.entries(
            layers: [layer("ana")],
            records: ["ana": [textMargin("lost", char: nil, evidence: .unresolved), textMargin("guess", char: 500, evidence: .ambiguous)]]
        )
        XCTAssertEqual(entries, [], "unplaced on a text item: not offered, as before")
    }

    func testAPodcastMarginPlacedOnlyInItsTranscriptGetsNoNarratedTime() {
        let entries = SharedMarginReview.entries(layers: [layer("ana", type: .podcast)], records: ["ana": [textMargin("t", char: 350)]])
        XCTAssertNil(entries.first?.textOffset, "a podcast plays on the media clock, never the narrated one")
    }

    func testAReviewKeepsOnlyTheMarginsPlacedOnItsClock() {
        let text = SharedMarginReview.entries(layers: [layer("ana")], records: ["ana": [textMargin("t", char: 350)]])
        let media = [SharedMarginReview.Entry(layer: layer("bo", type: .podcast), interjection: textMargin("m", in: "bo", char: nil),
                                              mediaTimeMs: 60_000, isApproximate: false)]
        XCTAssertEqual(SharedMarginReview.placeable(text + media, on: .liveNarration).map(\.interjection.id), ["t"])
        XCTAssertEqual(SharedMarginReview.placeable(text + media, on: .media).map(\.interjection.id), ["m"],
                       "an article playing a recording has a media clock, where a text place has no time")
    }

    /// The reply that started #5409: B answered A's Margin on the article. A finished the article, so the item is in
    /// catch-up, and the review plays A's own Margin, then B's reply, at that place in the reading.
    func testAReplyToTheListenersOwnMarginOnAnArticleIsCatchUpAndPlaysAfterIt() throws {
        let sent = MarginPacketIdentity(packageDigest: "digest-mine", packageScopedId: "margin-0001")
        let mine = ownTextMargin("mine", char: 1_200, sharedAs: [sent])
        let reply = textMargin("reply", char: 1_200, replyLinks: [MarginReplyLink.replying(to: sent, parentConversationId: nil)])
        let entries = SharedMarginReview.entries(layers: [layer("ana")], records: ["ana": [reply]], ownMargins: [mine])
        XCTAssertEqual(entries.map(\.interjection.id), ["reply"])
        XCTAssertNotNil(entries.first?.replyContext?.yoursParentId)
        XCTAssertNotNil(ConversationCatchUp.make(isFinished: true, entries: entries), "Hear the replies and catch-up are offered")

        let steps = SharedMarginReview.playlist(for: entries, ownMargins: [mine])
        XCTAssertEqual(steps.map { $0.ownParent?.id ?? $0.entry?.interjection.id }, ["mine", "reply"])
        XCTAssertEqual(Set(steps.map(\.anchor.mediaTimeMs)), [clock.position(forTextOffset: 1_200)])
        let sequence = try XCTUnwrap(MarginMomentSequence(
            itemId: "item", reviewing: steps.map(\.anchor), returnToMediaTimeMs: clock.position(forTextOffset: 9_000),
            tickAdvanceLimitMs: clock.tickAdvanceLimitMs, endsPaused: true))
        XCTAssertEqual(sequence.unplayed.map(\.marginId), steps.map(\.anchor.marginId))
        XCTAssertLessThan(sequence.startMediaTimeMs, clock.position(forTextOffset: 1_200), "a lead-in in the reading before the pair")
    }

    /// A review's lead-in on text read aloud starts at the sequence's own run-up, snapped to a sentence start, so the
    /// review's shorter lead-in (not the moment's) decides where the reading begins.
    func testTheReadingStartsAtTheSequencesRunUpSnappedToASentence() {
        let text = String(repeating: "A sentence here. ", count: 40)
        let target = clock.position(forTextOffset: 500)
        let start = clock.position(forTextOffset: 400)
        let offset = clock.leadInStartOffset(fromPosition: start, toTargetPosition: target, in: text)
        XCTAssertGreaterThanOrEqual(offset, 400)
        XCTAssertLessThan(offset, 500)
        XCTAssertEqual(offset % 17, 0, "a sentence start")
        XCTAssertEqual(
            clock.leadInStartOffset(forTargetPosition: target, in: text),
            clock.leadInStartOffset(
                fromPosition: MarginMomentSequence.leadInStartMediaTimeMs(forTarget: MarginMomentAnchor(marginId: "t", mediaTimeMs: target)),
                toTargetPosition: target, in: text),
            "the moment's own lead-in is unchanged")
    }
}
