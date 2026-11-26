import Foundation
import XCTest
@testable import SessionKit

/// Sending replies back (#3221): which of the listener's Margins the "Share replies with <friend>" share offers and
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
        _ id: String, in layerId: String, at ms: Int = 60_000, replyingTo parent: MarginPacketIdentity? = nil, createdAt: Double = 120,
        evidence: AnchorResolutionEvidenceClass = .exactEdition, senderLeadInMs: Int? = nil
    ) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(
            id: id, layerId: layerId, packageScopedId: id, createdAt: date(createdAt),
            anchorEvidence: PortableAnchorEvidence(anchorType: .media), approvedTranscript: "Words",
            audioPath: "ImportedCommentary/\(id).m4a", audioDurationMs: 4_000,
            resolution: ImportedAnchorResolution(evidenceClass: evidence, localMediaTimeMs: ms, confidence: 1),
            replyLinks: parent.map {
                [MarginReplyLink(conversationId: "conversation", parentPackageDigest: $0.packageDigest, parentPackageScopedId: $0.packageScopedId)]
            },
            senderLeadInMs: senderLeadInMs
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
        XCTAssertEqual(offer.title, "Share replies with Ana")
        XCTAssertEqual(ids(offer.replies), ["reply"])
        XCTAssertEqual(ids(offer.others), ["extra"])
        XCTAssertEqual(ids(offer.candidates), ["reply", "extra"], "a Margin made before the import is not offered")
        XCTAssertEqual(offer.candidates.map(offer.isPreselected), [true, false])
    }

    /// #4688: each pass numbers its Margins from "ij-001", so a reply in a replay can share its id with a Margin of the
    /// first listen that answers nothing. Only the reply starts picked.
    func testOnlyTheReplyStartsPickedWhenAnotherPassHasAMarginWithItsId() throws {
        var reply = own("ij-001", madeAt: 200, replyingTo: "ana"); reply.sessionId = "replay"
        var other = own("ij-001", madeAt: 210); other.sessionId = "first"
        let offer = try XCTUnwrap(ReplyBackOffer.make(localMargins: [reply, other], layers: [layer("ana")]))
        XCTAssertEqual(offer.candidates.map(\.sessionId), ["replay", "first"])
        XCTAssertEqual(offer.candidates.map(offer.isPreselected), [true, false])
    }

    /// #3906, the Design's table: Share, the one verb for sending to a person, and the title follows what the sheet
    /// holds, so the row never calls new Margins replies.
    func testTheTitleSaysShareAndFollowsWhatTheSheetHolds() throws {
        let reply = own("reply", madeAt: 200, replyingTo: "ana"), extra = own("extra", madeAt: 210)
        let one = [layer("ana")]
        let two = [layer("ana", importedAt: 100), layer("ben", importedAt: 110)]
        let three = two + [layer("cleo", importedAt: 120)]
        let nameless = [layer("ana", label: " ")]
        let rows: [(String, [Interjection], [ImportedCommentaryLayer], String)] = [
            ("a linked reply", [reply], one, "Share replies with Ana"),
            ("a reply and another new Margin", [reply, extra], one, "Share replies with Ana"),
            ("only Margins that are not replies", [extra], one, "Share your Margins with Ana"),
            ("replies to two friends", [own("r1", madeAt: 200, replyingTo: "ana"), own("r2", madeAt: 201, replyingTo: "ben")], two, "Share replies with Ana and Ben"),
            ("no reply, two friends on the item", [extra], two, "Share your Margins with Ana and Ben"),
            ("no reply, three friends on the item", [extra], three, "Share your Margins with Ana, Ben and 1 other"),
            ("a reply to a friend with no name", [reply], nameless, "Share replies with your friend"),
            ("no reply, a friend with no name", [extra], nameless, "Share your Margins with your friend")
        ]
        for (label, margins, layers, expected) in rows {
            XCTAssertEqual(try XCTUnwrap(ReplyBackOffer.make(localMargins: margins, layers: layers)).title, expected, label)
        }
    }

    /// The line under "Share replies with" (#4785), with one, two and three friends and no name; none for a share that
    /// holds no reply.
    func testTheCaptionSaysTheFriendCanHearJustTheReplies() throws {
        let reply = own("reply", madeAt: 200, replyingTo: "ana")
        let extra = own("extra", madeAt: 210)
        let two = [layer("ana", importedAt: 100), layer("ben", importedAt: 110)]
        let rows: [(String, [Interjection], [ImportedCommentaryLayer], String?)] = [
            ("one friend", [reply], [layer("ana")], "These arrive marked new, so Ana can hear just them."),
            ("two friends", [own("r1", madeAt: 200, replyingTo: "ana"), own("r2", madeAt: 201, replyingTo: "ben")], two,
             "These arrive marked new, so Ana and Ben can hear just them."),
            ("three friends", [own("r1", madeAt: 200, replyingTo: "ana"), own("r2", madeAt: 201, replyingTo: "ben"),
                               own("r3", madeAt: 202, replyingTo: "cleo")], two + [layer("cleo", importedAt: 120)],
             "These arrive marked new, so Ana, Ben and 1 other can hear just them."),
            ("no name", [reply], [layer("ana", label: " ")], "These arrive marked new, so your friend can hear just them."),
            ("no reply", [extra], [layer("ana")], nil),
        ]
        for (label, margins, layers, expected) in rows {
            XCTAssertEqual(try XCTUnwrap(ReplyBackOffer.make(localMargins: margins, layers: layers)).caption, expected, label)
        }
    }

    func testNoMarginSinceTheImportMeansNoOffer() {
        XCTAssertNil(ReplyBackOffer.make(localMargins: [own("old", madeAt: 10)], layers: [layer("ana")]))
        XCTAssertNil(ReplyBackOffer.make(localMargins: [own("new", madeAt: 200)], layers: []), "no friend's packet on the item")
        XCTAssertNil(ReplyBackOffer.make(localMargins: [own("new", madeAt: 200)], layers: [layer("ana", deleted: true)]))
    }

    func testAFriendWhoseFileNamedNobodyIsNeverOfferedUnderAStandInName() throws {
        for label in ["Unsigned sender", " unsigned  sender ", "Imported collection", " ", ""] {
            let offer = try XCTUnwrap(ReplyBackOffer.make(localMargins: [own("extra", madeAt: 200)], layers: [layer("ana", label: label)]))
            XCTAssertEqual(offer.title, "Share your Margins with your friend", label)
        }
    }

    func testWithNoLinkedReplyTheOrdinarySharesRuleDecidesWhatStartsPicked() throws {
        // #3792: the sheet never opens with nothing chosen. Every candidate starts included, as the ordinary Share
        // does, unless some are starred for sharing: then only those.
        let layers = [layer("ana")]
        var starred = own("starred", madeAt: 210)
        starred.isStarredForSharing = true
        var unstarred = own("plain", madeAt: 200)
        unstarred.isStarredForSharing = false

        let single = try XCTUnwrap(ReplyBackOffer.make(localMargins: [own("extra", madeAt: 200)], layers: layers))
        XCTAssertEqual(single.title, "Share your Margins with Ana")
        XCTAssertEqual(ids(single.candidates), ["extra"])
        XCTAssertEqual(single.candidates.map(single.isPreselected), [true])

        let several = try XCTUnwrap(ReplyBackOffer.make(localMargins: [own("a", madeAt: 200), own("b", madeAt: 201)], layers: layers))
        XCTAssertEqual(several.candidates.map(several.isPreselected), [true, true])

        let mixed = try XCTUnwrap(ReplyBackOffer.make(localMargins: [unstarred, starred], layers: layers))
        XCTAssertEqual(ids(mixed.candidates), ["plain", "starred"])
        XCTAssertEqual(mixed.candidates.map(mixed.isPreselected), [false, true], "starred Margins only, when any is starred")

        let before = own("before-import", madeAt: 10)
        let onlyOld = ReplyBackOffer.make(localMargins: [before, starred], layers: layers)
        XCTAssertEqual(ids(try XCTUnwrap(onlyOld).candidates), ["starred"], "a Margin made before the friend's packet is never on the sheet")
    }

    func testLinkedRepliesStayTheOnlyOnesPickedEvenWhenAnotherMarginIsStarred() throws {
        // #3221, kept: with a linked reply the others stay unpicked, whatever their stars say.
        var starredOther = own("other", madeAt: 210)
        starredOther.isStarredForSharing = true
        let offer = try XCTUnwrap(ReplyBackOffer.make(
            localMargins: [own("reply", madeAt: 200, replyingTo: "ana"), starredOther], layers: [layer("ana")]
        ))
        XCTAssertEqual(offer.candidates.map(offer.isPreselected), [true, false])
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
        XCTAssertEqual(try XCTUnwrap(ReplyBackOffer.make(localMargins: toBen, layers: layers)).title, "Share replies with Ben")
        let toTwo = [own("r1", madeAt: 200, replyingTo: "cleo"), own("r2", madeAt: 201, replyingTo: "ana")]
        XCTAssertEqual(try XCTUnwrap(ReplyBackOffer.make(localMargins: toTwo, layers: layers)).title, "Share replies with Cleo and Ana")
        let none = [own("x", madeAt: 200)]
        XCTAssertEqual(try XCTUnwrap(ReplyBackOffer.make(localMargins: none, layers: layers)).title,
                       "Share your Margins with Ana, Ben and 1 other", "no reply names a friend, so every friend on the item does")
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
        XCTAssertEqual(entry.replyContext?.parent, .yours(interjectionId: "session::m1", mediaTimeMs: 754_000))
        XCTAssertEqual(entry.replyContext?.caption, "Reply to your Margin at 12:34")
        XCTAssertEqual(entry.anchor.caption, "Reply to your Margin at 12:34")
    }

    /// #4233: a Margin moved with no place stores a zero media time. A reply that answers it says so without a time, and
    /// a guessed reply does not follow the parent to the episode's opening.
    func testAReplyToAnOwnMarginWithNoPlaceNamesNoTimeAndNeverFollowsItToZero() throws {
        func unplaced(_ margin: Interjection) -> Interjection {
            var margin = margin
            margin.movedOrigin = MovedMarginOrigin(
                marginId: margin.id, itemId: "item", sessionId: "session", liveMarginId: "live-m1", fromLiveSessionId: "live",
                fromLiveSessionTitle: "Quick session", markedAt: margin.createdAt, movedAt: margin.createdAt, placeKnown: false)
            margin.anchor.mediaTimeMs = 0
            return margin
        }
        let placed = own("m1", madeAt: 10, atMs: 754_000, sharedAs: [mine])
        let moved = unplaced(placed)
        let entries = { (margin: Interjection) in
            SharedMarginReview.entries(
                layers: [self.layer("ben")], records: ["ben": [self.friendMargin("reply", in: "ben", at: 755_000, replyingTo: self.mine)]],
                ownMargins: [margin])
        }
        XCTAssertEqual(try XCTUnwrap(entries(placed).first).replyContext?.parent, .yours(interjectionId: "session::m1", mediaTimeMs: 754_000),
                       "a Margin with a place is unchanged")
        let entry = try XCTUnwrap(entries(moved).first)
        XCTAssertEqual(entry.replyContext?.parent, .yours(interjectionId: "session::m1", mediaTimeMs: nil))
        XCTAssertEqual(entry.replyContext?.caption, "Reply to your Margin")
        // A guessed (approximate) reply to the parent goes where the parent plays. With no place there is none, so the
        // parent plays at the reply's own time, never at 0:00.
        let approximate = SharedMarginReview.Entry(
            layer: entry.layer, interjection: entry.interjection, mediaTimeMs: entry.mediaTimeMs, isApproximate: true,
            replyContext: entry.replyContext)
        let steps = SharedMarginReview.playlist(for: [approximate], ownMargins: [moved])
        let parentStep = try XCTUnwrap(steps.first { $0.ownParent != nil })
        XCTAssertEqual(parentStep.anchor.mediaTimeMs, approximate.mediaTimeMs)
        XCTAssertNotEqual(parentStep.anchor.mediaTimeMs, 0)
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
        XCTAssertEqual(entries.first?.replyContext?.caption, "Reply to a Margin that isn't on this phone")
    }

    func testAMarginThatIsNotAReplyHasNoContextAndTheOldCallStillWorks() throws {
        let records = ["ben": [friendMargin("plain", in: "ben")]]
        // The entry must exist: `.first?` of an empty list is nil too, which passed with no entry at all.
        let entry = try XCTUnwrap(SharedMarginReview.entries(layers: [layer("ben")], records: records).first)
        XCTAssertEqual(entry.interjection.id, "plain")
        XCTAssertNil(entry.replyContext)
        XCTAssertNil(entry.anchor.caption)
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
        XCTAssertEqual(parent.anchor.marginId, SharedMarginReview.parentMarginId("session::m1"))
        XCTAssertEqual(parent.anchor.mediaTimeMs, 755_000, "the parent sits at its reply's place, so the review makes no extra hop")
        XCTAssertEqual(parent.anchor.caption, "Your Margin at 12:34")
        XCTAssertEqual(Set(steps.map(\.anchor.marginId)).count, steps.count, "every step has its own identity")
    }

    func testAClockOnlyReplyKeepsTheParentAtItsOwnExactPlaceAndTheReplyFollowsIt() throws {
        // #3611: Ben's copy has a 30 s pre-roll, so his clock reads 785 s where Ana's Margin sits at 754 s on hers.
        let margins = [own("m1", madeAt: 10, atMs: 754_000, sharedAs: [mine])]
        let entries = SharedMarginReview.entries(
            layers: [layer("ben")],
            records: ["ben": [friendMargin("reply", in: "ben", at: 785_000, replyingTo: mine, evidence: .timestampFallback)]],
            ownMargins: margins
        )
        XCTAssertEqual(entries.first?.isApproximate, true)
        let steps = SharedMarginReview.playlist(for: entries, ownMargins: margins)
        XCTAssertEqual(steps.count, 2)
        let parent = try XCTUnwrap(steps.first)
        XCTAssertEqual(parent.anchor.mediaTimeMs, 754_000, "the lead-in and the parent play from the Margin's own place")
        XCTAssertFalse(parent.anchor.isApproximate)
        XCTAssertEqual(parent.anchor.caption, "Your Margin at 12:34")
        let reply = steps[1]
        XCTAssertEqual(reply.anchor.mediaTimeMs, 754_000, "the reply follows its parent, not the friend's clock")
        XCTAssertTrue(reply.anchor.isApproximate, "how long after the parent the friend spoke is still a guess")
        XCTAssertEqual(reply.anchor.marginId, entries[0].marginId)
        XCTAssertEqual(reply.anchor.caption, "Reply to your Margin at 12:34")
        let sequence = try XCTUnwrap(MarginMomentSequence(itemId: "item", reviewing: steps.map(\.anchor)))
        XCTAssertLessThan(sequence.startMediaTimeMs, 754_000)
    }

    /// #4171: a reply moved to its parent's place is a second anchor built in `playlist`; it keeps the sender's length.
    func testAReplyMovedToItsParentsPlaceKeepsTheSendersLeadIn() throws {
        let margins = [own("m1", madeAt: 10, atMs: 754_000, sharedAs: [mine])]
        // Where the pair plays: a clock-only reply follows its parent's exact place, an exact one moves the parent to it.
        for (ms, evidence, pairAt) in [(785_000, AnchorResolutionEvidenceClass.timestampFallback, 754_000), (760_000, .exactEdition, 760_000)] {
            let entries = SharedMarginReview.entries(
                layers: [layer("ben")],
                records: ["ben": [friendMargin("reply", in: "ben", at: ms, replyingTo: mine, evidence: evidence, senderLeadInMs: 90_000)]],
                ownMargins: margins
            )
            let steps = SharedMarginReview.playlist(for: entries, ownMargins: margins)
            XCTAssertEqual(steps.last?.anchor.leadInMs, 90_000, "\(evidence)")
            // The listener's own Margin plays first at that place, so the review starts the sender's length before IT.
            XCTAssertEqual(steps.first?.anchor.leadInMs, 90_000, "the parent step: \(evidence)")
            let sequence = try XCTUnwrap(MarginMomentSequence(itemId: "item", reviewing: steps.map(\.anchor)))
            XCTAssertEqual(sequence.startMediaTimeMs, pairAt - 90_000, "\(evidence)")
        }
    }

    func testAClockOnlyReplyToAnAlreadyPlayedParentStillSitsAtTheParentsPlace() {
        let margins = [own("m1", madeAt: 10, atMs: 754_000, sharedAs: [mine])]
        let entries = SharedMarginReview.entries(
            layers: [layer("ben")],
            records: ["ben": [
                friendMargin("r1", in: "ben", at: 785_000, replyingTo: mine, evidence: .timestampFallback),
                friendMargin("r2", in: "ben", at: 790_000, replyingTo: mine, evidence: .mapInterpolated)
            ]],
            ownMargins: margins
        )
        let steps = SharedMarginReview.playlist(for: entries, ownMargins: margins)
        XCTAssertEqual(steps.map(\.anchor.mediaTimeMs), [754_000, 754_000, 754_000])
        XCTAssertEqual(steps.filter { $0.ownParent != nil }.count, 1)
    }

    func testAnExactReplyStillMovesTheParentToTheRepliesPlace() throws {
        // The existing rule for a resolved reply is unchanged: no extra hop.
        let margins = [own("m1", madeAt: 10, atMs: 754_000, sharedAs: [mine])]
        let entries = SharedMarginReview.entries(
            layers: [layer("ben")], records: ["ben": [friendMargin("r1", in: "ben", at: 760_000, replyingTo: mine)]], ownMargins: margins
        )
        let steps = SharedMarginReview.playlist(for: entries, ownMargins: margins)
        XCTAssertEqual(steps.map(\.anchor.mediaTimeMs), [760_000, 760_000])
        XCTAssertFalse(steps[0].anchor.isApproximate)
    }

    func testAMovedReplyStaysInPlayingOrderWithTheOtherMargins() throws {
        // The friend's clock puts the reply last (785 s) but its parent sits at 754 s, behind an exact Margin at 760 s.
        let margins = [own("m1", madeAt: 10, atMs: 754_000, sharedAs: [mine])]
        let early = SharedMarginReview.entries(
            layers: [layer("ben")],
            records: ["ben": [
                friendMargin("exact", in: "ben", at: 760_000),
                friendMargin("reply", in: "ben", at: 785_000, replyingTo: mine, evidence: .timestampFallback)
            ]],
            ownMargins: margins
        )
        let steps = SharedMarginReview.playlist(for: early, ownMargins: margins)
        XCTAssertEqual(steps.map { $0.entry?.interjection.id ?? "parent" }, ["parent", "reply", "exact"])
        XCTAssertEqual(steps.map(\.anchor.mediaTimeMs), [754_000, 754_000, 760_000])
        // A clock before the parent, ahead of a later exact Margin.
        let late = SharedMarginReview.entries(
            layers: [layer("ben")],
            records: ["ben": [
                friendMargin("reply", in: "ben", at: 700_000, replyingTo: mine, evidence: .timestampFallback),
                friendMargin("exact", in: "ben", at: 730_000)
            ]],
            ownMargins: margins
        )
        XCTAssertEqual(SharedMarginReview.playlist(for: late, ownMargins: margins).map { $0.entry?.interjection.id ?? "parent" },
                       ["exact", "parent", "reply"])
    }

    func testASecondGuessedReplyFollowsWhereTheParentWasAlreadyPlaced() {
        // The first reply resolved exactly at 760 s, so the parent plays there; a guessed second reply goes with it.
        let margins = [own("m1", madeAt: 10, atMs: 754_000, sharedAs: [mine])]
        let entries = SharedMarginReview.entries(
            layers: [layer("ben")],
            records: ["ben": [
                friendMargin("r1", in: "ben", at: 760_000, replyingTo: mine),
                friendMargin("r2", in: "ben", at: 785_000, replyingTo: mine, evidence: .timestampFallback)
            ]],
            ownMargins: margins
        )
        let steps = SharedMarginReview.playlist(for: entries, ownMargins: margins)
        XCTAssertEqual(steps.map { $0.entry?.interjection.id ?? "parent" }, ["parent", "r1", "r2"])
        XCTAssertEqual(steps.map(\.anchor.mediaTimeMs), [760_000, 760_000, 760_000])
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
        XCTAssertEqual(sequence.target.marginId, SharedMarginReview.parentMarginId("session::m1"))
        XCTAssertEqual(sequence.jumpToTarget()?.marginId, SharedMarginReview.parentMarginId("session::m1"))
        guard case .playNow(let next) = sequence.marginFinished(sourceAtMediaTimeMs: 755_000) else {
            return XCTFail("the reply should follow the parent with no second lead-in")
        }
        XCTAssertEqual(next.marginId, entries[0].marginId)
        XCTAssertEqual(next.caption, "Reply to your Margin at 12:34")
    }

    func testAReplyWhosePacketWasOnlyBuiltIsStillOfferedAndANamelessFriendIsYourFriend() throws {
        // `sharedAs` is saved when the packet file is built, before the iOS share sheet opens, so a cancelled share
        // leaves it set on a reply that never went out. The offer must not lose that reply.
        let built = [MarginPacketIdentity(packageDigest: "digest-out", packageScopedId: "r1")]
        let margins = [own("r1", madeAt: 200, replyingTo: "ana", sharedAs: built), own("r2", madeAt: 201, replyingTo: "ana")]
        let offer = try XCTUnwrap(ReplyBackOffer.make(localMargins: margins, layers: [layer("ana", label: "  ")]))
        XCTAssertEqual(ids(offer.candidates), ["r1", "r2"])
        XCTAssertEqual(offer.candidates.map(offer.isPreselected), [true, true])
        XCTAssertEqual(offer.title, "Share replies with your friend")
        XCTAssertNotNil(ReplyBackOffer.make(localMargins: [margins[0]], layers: [layer("ana")]))
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
        XCTAssertEqual(SharedMarginReview.chimedMarginIds(loud), [SharedMarginReview.parentMarginId("session::m1"), loud[2].anchor.marginId],
                       "the parent announces the reply that follows it; the reply itself does not chime again")
        XCTAssertEqual(SharedMarginReview.chimedMarginIds(steps(muted: true)), [steps(muted: true)[2].anchor.marginId])
    }
}
