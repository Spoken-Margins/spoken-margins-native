import Foundation
import XCTest
@testable import SessionKit

/// Sending replies back (#3221): which of the listener's Margins the "Send replies to <friend>" share offers and
/// pre-selects, and how the friend's reply reads in the originator's review.
final class ReplyBackTests: XCTestCase {
    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + seconds) }

    private func layer(_ id: String, label: String? = nil, importedAt: Double = 100, deleted: Bool = false) -> ImportedCommentaryLayer {
        ImportedCommentaryLayer(
            id: id, itemId: "item", packageDigest: "digest-\(id)", packageId: "package-\(id)",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode", durationMs: 1_800_000),
            displayLabel: label ?? id.capitalized, importedAt: date(importedAt), sourceResolutionStatus: .resolved,
            isEnabled: true, isMuted: false, deletedAt: deleted ? date(importedAt) : nil
        )
    }

    private func own(
        _ id: String, madeAt: Double, atMs: Int = 60_000, replyingTo layerId: String? = nil, parent: String = "f-1",
        voice: Bool = true, written: Bool = false, sharedAs: [MarginPacketIdentity]? = nil, status: String = "active"
    ) -> Interjection {
        Interjection(
            id: id, itemId: "item", sessionId: "session", targetType: .item, targetId: "item", createdAt: date(madeAt),
            roughPercent: 10, anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: atMs),
            audioPath: voice ? "Interjections/\(id).m4a" : nil, audioStatus: "ready", transcriptionStatus: "complete",
            transcript: "Words", cleanedTranscript: nil, displayText: "Words", status: status,
            captureKind: written ? .written : nil,
            replyTo: layerId.map {
                MarginReplyLink(conversationId: "conversation", parentPackageDigest: "digest-\($0)", parentPackageScopedId: parent)
            },
            sharedAs: sharedAs
        )
    }

    private func friendMargin(
        _ id: String, in layerId: String, at ms: Int = 60_000, replyingTo parent: MarginPacketIdentity? = nil, createdAt: Double = 120
    ) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(
            id: id, layerId: layerId, packageScopedId: id, createdAt: date(createdAt),
            anchorEvidence: PortableAnchorEvidence(anchorType: .media), approvedTranscript: "Words",
            audioPath: "ImportedCommentary/\(id).m4a", audioDurationMs: 4_000,
            resolution: ImportedAnchorResolution(evidenceClass: .exactEdition, localMediaTimeMs: ms, confidence: 1),
            replyLinks: parent.map {
                [MarginReplyLink(conversationId: "conversation", parentPackageDigest: $0.packageDigest, parentPackageScopedId: $0.packageScopedId)]
            }
        )
    }

    private func ids(_ margins: [Interjection]) -> [String] { margins.map(\.id) }

    // MARK: The offer (Done when 1)

    func testRepliesArePreselectedAndOtherNewMarginsAreOfferedUnselected() throws {
        let margins = [
            own("before-import", madeAt: 10),
            own("reply", madeAt: 200, replyingTo: "ana"),
            own("extra", madeAt: 210)
        ]
        let offer = try XCTUnwrap(ReplyBackOffer.make(localMargins: margins, layers: [layer("ana")]))
        XCTAssertEqual(offer.title, "Send replies to Ana")
        XCTAssertEqual(ids(offer.replies), ["reply"])
        XCTAssertEqual(ids(offer.others), ["extra"])
        XCTAssertEqual(ids(offer.candidates), ["reply", "extra"], "a Margin made before the import is not offered")
        XCTAssertEqual(offer.candidates.map(offer.isPreselected), [true, false])
    }

    func testNoMarginSinceTheImportMeansNoOffer() {
        XCTAssertNil(ReplyBackOffer.make(localMargins: [own("old", madeAt: 10)], layers: [layer("ana")]))
        XCTAssertNil(ReplyBackOffer.make(localMargins: [own("new", madeAt: 200)], layers: []), "no friend's packet on the item")
        XCTAssertNil(ReplyBackOffer.make(localMargins: [own("new", madeAt: 200)], layers: [layer("ana", deleted: true)]))
    }

    func testOnlyNewMarginsWithNoReplyAreStillOfferedWithNothingSelected() throws {
        let offer = try XCTUnwrap(ReplyBackOffer.make(localMargins: [own("extra", madeAt: 200)], layers: [layer("ana")]))
        XCTAssertEqual(offer.title, "Send replies to Ana")
        XCTAssertEqual(ids(offer.candidates), ["extra"])
        XCTAssertFalse(offer.isPreselected(offer.candidates[0]))
    }

    func testNothingTheFriendSentIsInTheOffer() throws {
        // A friend's Margins live in the imported records, never among the listener's own Margins, so the offer,
        // which is built from the listener's list alone, cannot hold one.
        let offer = try XCTUnwrap(ReplyBackOffer.make(localMargins: [own("reply", madeAt: 200, replyingTo: "ana")], layers: [layer("ana")]))
        XCTAssertEqual(ids(offer.candidates), ["reply"])
        XCTAssertNotEqual(friendMargin("f-1", in: "ana").id, offer.candidates[0].id)
        XCTAssertTrue(offer.candidates.allSatisfy { $0.audioPath?.hasPrefix("Interjections/") ?? true })
    }

    func testADeletedOrNonItemMarginIsNeverOffered() throws {
        var summaryNote = own("summary", madeAt: 200)
        summaryNote.targetType = .summaryTurn
        let margins = [own("gone", madeAt: 200, status: "deleted"), summaryNote, own("kept", madeAt: 201)]
        XCTAssertEqual(ids(try XCTUnwrap(ReplyBackOffer.make(localMargins: margins, layers: [layer("ana")])).candidates), ["kept"])
    }

    func testWrittenMarginsAreOfferedLikeSpokenOnes() throws {
        let margins = [own("note", madeAt: 200, replyingTo: "ana", voice: false, written: true)]
        XCTAssertEqual(ids(try XCTUnwrap(ReplyBackOffer.make(localMargins: margins, layers: [layer("ana")])).replies), ["note"])
    }

    func testTheFriendNamedIsTheOneTheRepliesAnswer() throws {
        let layers = [layer("ana", importedAt: 100), layer("ben", importedAt: 110), layer("cleo", importedAt: 120)]
        let toBen = [own("r1", madeAt: 200, replyingTo: "ben")]
        XCTAssertEqual(try XCTUnwrap(ReplyBackOffer.make(localMargins: toBen, layers: layers)).title, "Send replies to Ben")
        let toTwo = [own("r1", madeAt: 200, replyingTo: "cleo"), own("r2", madeAt: 201, replyingTo: "ana")]
        XCTAssertEqual(try XCTUnwrap(ReplyBackOffer.make(localMargins: toTwo, layers: layers)).title, "Send replies to Cleo and Ana")
        let none = [own("x", madeAt: 200)]
        XCTAssertEqual(try XCTUnwrap(ReplyBackOffer.make(localMargins: none, layers: layers)).title,
                       "Send replies to Ana, Ben and 1 other", "no reply names a friend, so every friend on the item does")
    }

    func testAReplyToAFriendWhosePacketWasDeletedFallsBackToAnOtherNewMargin() throws {
        let margins = [own("reply", madeAt: 200, replyingTo: "gone")]
        let offer = try XCTUnwrap(ReplyBackOffer.make(localMargins: margins, layers: [layer("ana"), layer("gone", deleted: true)]))
        XCTAssertEqual(ids(offer.replies), [])
        XCTAssertEqual(ids(offer.others), ["reply"])
    }

    func testTheOfferDoesNotDependOnTheOrderOfTheInputs() throws {
        let margins = [own("b", madeAt: 201), own("a", madeAt: 201), own("r", madeAt: 200, replyingTo: "ana")]
        let layers = [layer("ana"), layer("ben", importedAt: 150)]
        let first = try XCTUnwrap(ReplyBackOffer.make(localMargins: margins, layers: layers))
        let second = try XCTUnwrap(ReplyBackOffer.make(localMargins: Array(margins.reversed()), layers: Array(layers.reversed())))
        XCTAssertEqual(first, second)
        XCTAssertEqual(ids(first.candidates), ["r", "a", "b"])
    }

    // MARK: The originator's review (Done when 2)

    private var mine: MarginPacketIdentity { MarginPacketIdentity(packageDigest: "digest-mine", packageScopedId: "mine-1") }

    func testAReplyToTheListenersOwnMarginSaysSoAndNamesWhere() throws {
        let margins = [own("m1", madeAt: 10, atMs: 754_000, sharedAs: [mine])]
        let entries = SharedMarginReview.entries(
            layers: [layer("ben")], records: ["ben": [friendMargin("reply", in: "ben", at: 755_000, replyingTo: mine)]],
            ownMargins: margins
        )
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.replyContext?.parent, .yours(interjectionId: "m1", mediaTimeMs: 754_000))
        XCTAssertEqual(entry.replyContext?.caption, "Reply to your Margin at 12:34")
        XCTAssertEqual(entry.anchor.caption, "Reply to your Margin at 12:34")
    }

    func testAReplyAnswersAnotherFriendsMarginByName() throws {
        let theirs = MarginPacketIdentity(packageDigest: "digest-ana", packageScopedId: "ana-1")
        let entries = SharedMarginReview.entries(
            layers: [layer("ana"), layer("ben")],
            records: [
                "ana": [friendMargin("ana-1", in: "ana", at: 3_725_000)],
                "ben": [friendMargin("reply", in: "ben", at: 3_726_000, replyingTo: theirs)]
            ]
        )
        let reply = try XCTUnwrap(entries.first { $0.interjection.id == "reply" })
        XCTAssertEqual(reply.replyContext?.caption, "Reply to Ana's Margin at 1:02:05")
        XCTAssertNil(entries.first { $0.interjection.id == "ana-1" }?.replyContext)
    }

    func testAReplyWhoseParentHasNotArrivedStillSaysItIsAReply() throws {
        let entries = SharedMarginReview.entries(
            layers: [layer("ben")], records: ["ben": [friendMargin("reply", in: "ben", replyingTo: mine)]]
        )
        XCTAssertEqual(entries.first?.replyContext?.parent, .missing)
        XCTAssertEqual(entries.first?.replyContext?.caption, "Reply to a Margin you don't have yet")
    }

    func testAMarginThatIsNotAReplyHasNoContextAndTheOldCallStillWorks() {
        let records = ["ben": [friendMargin("plain", in: "ben")]]
        XCTAssertNil(SharedMarginReview.entries(layers: [layer("ben")], records: records).first?.replyContext)
        XCTAssertNil(SharedMarginReview.entries(layers: [layer("ben")], records: records).first?.anchor.caption)
    }

    func testThePlaylistPlaysTheOwnParentBeforeItsReplyAndOnlyOnce() throws {
        let margins = [own("m1", madeAt: 10, atMs: 754_000, sharedAs: [mine]), own("m2", madeAt: 11, atMs: 900_000, sharedAs: [
            MarginPacketIdentity(packageDigest: "digest-mine", packageScopedId: "mine-2")
        ])]
        let second = MarginPacketIdentity(packageDigest: "digest-mine", packageScopedId: "mine-2")
        let entries = SharedMarginReview.entries(
            layers: [layer("ben")],
            records: ["ben": [
                friendMargin("r1", in: "ben", at: 755_000, replyingTo: mine),
                friendMargin("r2", in: "ben", at: 756_000, replyingTo: mine),
                friendMargin("r3", in: "ben", at: 901_000, replyingTo: second),
                friendMargin("plain", in: "ben", at: 1_000_000)
            ]],
            ownMargins: margins
        )
        let steps = SharedMarginReview.playlist(for: entries, ownMargins: margins)
        XCTAssertEqual(steps.map { $0.entry?.interjection.id ?? "parent:\($0.ownParent?.id ?? "?")" },
                       ["parent:m1", "r1", "r2", "parent:m2", "r3", "plain"])
        let parent = try XCTUnwrap(steps.first)
        XCTAssertTrue(parent.anchor.isYours)
        XCTAssertEqual(parent.anchor.marginId, SharedMarginReview.parentMarginId("m1"))
        XCTAssertEqual(parent.anchor.mediaTimeMs, 755_000, "the parent sits at its reply's place, so the review makes no extra hop")
        XCTAssertEqual(parent.anchor.caption, "Your Margin at 12:34")
        XCTAssertEqual(Set(steps.map(\.anchor.marginId)).count, steps.count, "every step has its own identity")
    }

    func testAWrittenOrMissingParentIsLeftOutOfThePlaylist() {
        let written = own("m1", madeAt: 10, atMs: 754_000, voice: false, written: true, sharedAs: [mine])
        let entries = SharedMarginReview.entries(
            layers: [layer("ben")], records: ["ben": [friendMargin("r1", in: "ben", replyingTo: mine)]], ownMargins: [written]
        )
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(SharedMarginReview.playlist(for: entries, ownMargins: [written]).map { $0.entry?.interjection.id }, ["r1"])
        XCTAssertEqual(SharedMarginReview.playlist(for: entries, ownMargins: []).count, 1)
    }

    func testTheReviewSequencePlaysLeadInThenParentThenReply() throws {
        let margins = [own("m1", madeAt: 10, atMs: 754_000, sharedAs: [mine])]
        let entries = SharedMarginReview.entries(
            layers: [layer("ben")], records: ["ben": [friendMargin("reply", in: "ben", at: 755_000, replyingTo: mine)]],
            ownMargins: margins
        )
        let steps = SharedMarginReview.playlist(for: entries, ownMargins: margins)
        var sequence = try XCTUnwrap(MarginMomentSequence(itemId: "item", reviewing: steps.map(\.anchor)))
        XCTAssertEqual(sequence.phase, .leadIn)
        XCTAssertLessThan(sequence.startMediaTimeMs, 755_000, "the lead-in runs first")
        XCTAssertEqual(sequence.target.marginId, SharedMarginReview.parentMarginId("m1"))
        XCTAssertEqual(sequence.jumpToTarget()?.marginId, SharedMarginReview.parentMarginId("m1"))
        guard case .playNow(let next) = sequence.marginFinished(sourceAtMediaTimeMs: 755_000) else {
            return XCTFail("the reply should follow the parent with no second lead-in")
        }
        XCTAssertEqual(next.marginId, entries[0].marginId)
        XCTAssertEqual(next.caption, "Reply to your Margin at 12:34")
    }

    func testMarginsAlreadySentAreNotOfferedAgainAndANamelessFriendIsYourFriend() throws {
        let sent = [MarginPacketIdentity(packageDigest: "digest-out", packageScopedId: "r1")]
        let margins = [own("r1", madeAt: 200, replyingTo: "ana", sharedAs: sent), own("r2", madeAt: 201, replyingTo: "ana")]
        let offer = try XCTUnwrap(ReplyBackOffer.make(localMargins: margins, layers: [layer("ana", label: "  ")]))
        XCTAssertEqual(ids(offer.candidates), ["r2"])
        XCTAssertEqual(offer.title, "Send replies to your friend")
        XCTAssertNil(ReplyBackOffer.make(localMargins: [margins[0]], layers: [layer("ana")]), "once everything is sent the offer goes")
    }

    func testTheChimeAnnouncesTheFirstMarginOfAStretchAndNeverAMutedFriendsOrASecondOne() {
        let margins = [own("m1", madeAt: 10, atMs: 754_000, sharedAs: [mine])]
        func steps(muted: Bool) -> [SharedMarginReview.Step] {
            var ben = layer("ben")
            ben.isMuted = muted
            let entries = SharedMarginReview.entries(
                layers: [ben, layer("ana")],
                records: ["ben": [friendMargin("reply", in: "ben", at: 755_000, replyingTo: mine)], "ana": [friendMargin("plain", in: "ana", at: 900_000)]],
                ownMargins: margins
            )
            return SharedMarginReview.playlist(for: entries, ownMargins: margins)
        }
        let loud = steps(muted: false)
        XCTAssertEqual(SharedMarginReview.chimedMarginIds(loud), [SharedMarginReview.parentMarginId("m1"), loud[2].anchor.marginId],
                       "the parent announces the reply that follows it; the reply itself does not chime again")
        XCTAssertEqual(SharedMarginReview.chimedMarginIds(steps(muted: true)), [steps(muted: true)[2].anchor.marginId])
    }
}
