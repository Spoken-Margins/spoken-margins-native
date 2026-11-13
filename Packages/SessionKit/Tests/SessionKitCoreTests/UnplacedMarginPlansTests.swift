import XCTest
@testable import SessionKit

/// #3789: a podcast Margin the placement pass couldn't place still plays, at the sender's time or after the others,
/// and its row says so in plain words. Table tests over neighbouring inputs.
final class UnplacedMarginPlansTests: XCTestCase {
    private let senderMs = 60_000

    private struct Row {
        let name: String
        let evidence: AnchorResolutionEvidenceClass
        var ambiguous = false
        var sender: Int? = 60_000
        var placedAt: Int?
        var duration: Int?
        let expected: SharedMarginPlacementPlan
    }

    func testEveryPlacementOnAPodcastLayerHasOneWayToPlay() {
        let rows = [
            Row(name: "placed", evidence: .exactEdition, placedAt: 5_000, expected: .placed(mediaTimeMs: 5_000)),
            Row(name: "placed by map", evidence: .mapInterpolated, placedAt: 5_000, expected: .roughly(mediaTimeMs: 5_000)),
            Row(name: "placed by clock", evidence: .timestampFallback, placedAt: 5_000, expected: .roughly(mediaTimeMs: 5_000)),
            Row(name: "not found", evidence: .unresolved, expected: .roughly(mediaTimeMs: 60_000)),
            Row(name: "found twice", evidence: .ambiguous, expected: .roughly(mediaTimeMs: 60_000)),
            Row(name: "flagged ambiguous", evidence: .acousticVerified, ambiguous: true, placedAt: 5_000, expected: .roughly(mediaTimeMs: 60_000)),
            Row(name: "zero is a time", evidence: .unresolved, sender: 0, expected: .roughly(mediaTimeMs: 0)),
            Row(name: "no sender time", evidence: .unresolved, sender: nil, expected: .afterOthers),
            Row(name: "negative sender time", evidence: .unresolved, sender: -1, expected: .afterOthers),
            Row(name: "cut edition", evidence: .absentFromRecipientEdition, expected: .afterOthers),
            Row(name: "past the end of a known copy", evidence: .unresolved, duration: 59_000, expected: .afterOthers),
            Row(name: "exactly at the end", evidence: .unresolved, duration: 60_000, expected: .roughly(mediaTimeMs: 60_000)),
            Row(name: "duration not known yet", evidence: .unresolved, duration: nil, expected: .roughly(mediaTimeMs: 60_000))
        ]
        for row in rows {
            for finishedPass in [false, true] {
                let record = margin(evidence: row.evidence, ambiguous: row.ambiguous, sender: row.sender, placedAt: row.placedAt)
                XCTAssertEqual(SharedMarginPrompts.plan(record, in: layer(finishedPass: finishedPass), durationMs: row.duration),
                               row.expected, "\(row.name), pass finished: \(finishedPass)")
            }
        }
    }

    func testOnlyAPodcastPacketFromTheSameEpisodeFallsBackToTheSenderTime() {
        let unplaced = margin(evidence: .unresolved, sender: senderMs)
        for type in [SharedItemType.text, .pdf, .epub, .other] {
            XCTAssertEqual(SharedMarginPrompts.plan(unplaced, in: layer(finishedPass: true, type: type), durationMs: nil), .notPlayable, "\(type)")
        }
        var wrong = layer(finishedPass: true)
        wrong.sourceResolutionStatus = .wrongSource
        XCTAssertEqual(SharedMarginPrompts.plan(unplaced, in: wrong, durationMs: nil), .notPlayable)
    }

    func testAMarginAfterThePassIsOfferedAndPlaysAtTheSendersTime() {
        let notFound = margin(evidence: .unresolved, sender: senderMs)
        let done = layer(finishedPass: true)
        XCTAssertTrue(SharedMarginPrompts.isPlayable(notFound, in: done))
        XCTAssertEqual(SharedMarginPrompts.mediaTimeMs(notFound, in: done), senderMs)
        XCTAssertTrue(SharedMarginPrompts.isLayerPlaybackEligible(done, records: [notFound]))
        let prompts = SharedMarginPrompts.prompts(layers: [done], recordsByLayerID: ["layer": [notFound]],
                                                  announcedIDs: [], includeAnnounced: false)
        XCTAssertEqual(prompts.count, 1)
    }

    func testAMarginWithNoUsableTimeIsOfferedButNeverCrossedByThePlayhead() {
        let none = margin(evidence: .unresolved, sender: nil)
        let done = layer(finishedPass: true)
        XCTAssertTrue(SharedMarginPrompts.isPlayable(none, in: done))
        XCTAssertNil(SharedMarginPrompts.mediaTimeMs(none, in: done))
        let prompts = SharedMarginPrompts.prompts(layers: [done], recordsByLayerID: ["layer": [none]],
                                                  announcedIDs: [], includeAnnounced: false)
        XCTAssertEqual(prompts.count, 1)
        var before = SessionSnapshot()
        before.currentMediaTimeMs = 0
        var after = SessionSnapshot()
        after.currentMediaTimeMs = 9_000_000
        XCTAssertTrue(SharedMarginPrompts.crossed(prompts: prompts, previous: before, current: after).isEmpty)
    }

    func testReviewListsUnplacedMarginsAtTheSenderTimeAndNoTimeOnesLast() {
        let placed = margin(id: "placed", evidence: .exactEdition, sender: 10_000, placedAt: 30_000)
        let rough = margin(id: "rough", evidence: .unresolved, sender: 90_000)
        let none = margin(id: "none", evidence: .unresolved, sender: nil)
        let cut = margin(id: "cut", evidence: .absentFromRecipientEdition, sender: 1_000)
        let done = layer(finishedPass: true)
        let entries = SharedMarginReview.entries(layers: [done], records: ["layer": [none, cut, rough, placed]], durationMs: 3_600_000)
        XCTAssertEqual(entries.map(\.interjection.id), ["placed", "rough", "cut", "none"])
        XCTAssertEqual(entries.map(\.playsAfterOthers), [false, false, true, true])
        XCTAssertEqual(entries.map(\.isApproximate), [false, true, true, true])
        XCTAssertEqual(entries[1].mediaTimeMs, 90_000)
        XCTAssertGreaterThanOrEqual(entries[2].mediaTimeMs, entries[1].mediaTimeMs)
        let past = SharedMarginReview.entries(layers: [done], records: ["layer": [rough]], durationMs: 80_000)
        XCTAssertEqual(past.map(\.playsAfterOthers), [true], "a sender time past the copy's end moves after the others")
        let unknown = SharedMarginReview.entries(layers: [done], records: ["layer": [rough]], durationMs: nil)
        XCTAssertEqual(unknown.map(\.playsAfterOthers), [false])
    }

    /// #3788: the friend's intro comes from `entries` alone, so it exists on the first read of a just-imported
    /// packet (episode not downloaded, no pass run, only the sender's clock), and a layer from another episode
    /// gives none.
    func testTheArrivalIntroExistsOnTheFirstReadAndNeverForAnotherEpisode() throws {
        let web = margin(id: "web", evidence: .unresolved, sender: 134_000)
        let none = margin(id: "none", evidence: .unresolved, sender: nil)
        for finishedPass in [false, true] {
            let entries = SharedMarginReview.entries(layers: [layer(finishedPass: finishedPass)], records: ["layer": [web, none]])
            let intro = try XCTUnwrap(FriendMarginsIntro(unheardFriendMargins: entries.map(\.waitingMargin)), "pass finished: \(finishedPass)")
            XCTAssertEqual(intro.senderLine, "From Cole")
            XCTAssertTrue(intro.countLine.hasPrefix("2 Margins"), intro.countLine)
        }
        var other = layer(finishedPass: false)
        other.sourceResolutionStatus = .wrongSource
        let wrong = SharedMarginReview.entries(layers: [other], records: ["layer": [web, none]])
        XCTAssertTrue(wrong.isEmpty)
        XCTAssertNil(FriendMarginsIntro(unheardFriendMargins: wrong.map(\.waitingMargin)))
    }

    func testAnAlreadyHeardMarginIsNotOfferedAgain() {
        var heard = margin(evidence: .unresolved, sender: senderMs)
        heard.firstHeardAt = Date(timeIntervalSince1970: 1)
        XCTAssertTrue(SharedMarginReview.entries(layers: [layer(finishedPass: true)], records: ["layer": [heard]]).isEmpty)
    }

    func testRowWordsAreTheThreePodcastPhrasesWhateverThePassIsDoing() {
        XCTAssertEqual(SharedMarginPlacementWording.podcastLine(for: .placed(mediaTimeMs: 1)), "Placed here")
        XCTAssertEqual(SharedMarginPlacementWording.podcastLine(for: .roughly(mediaTimeMs: 1)), "Placed roughly here")
        XCTAssertEqual(SharedMarginPlacementWording.podcastLine(for: .afterOthers), "Plays after the others")
        XCTAssertNil(SharedMarginPlacementWording.podcastLine(for: .notPlayable))
        let engineering = ["couldn't place", "placement resolution", "margin placement", "placing in your copy",
                           "matching positions", "not placed yet", "sent without a position", "tied to exact places",
                           "more than one place"]
        for finishedPass in [false, true] {
            for evidence in [AnchorResolutionEvidenceClass.unresolved, .ambiguous, .absentFromRecipientEdition, .exactEdition] {
                let record = margin(evidence: evidence, sender: senderMs, placedAt: evidence == .exactEdition ? 5_000 : nil)
                let line = SharedMarginPlacementWording.line(for: record, in: layer(finishedPass: finishedPass), durationMs: nil)
                XCTAssertNotNil(line, "\(evidence)")
                for word in engineering { XCTAssertFalse((line ?? "").lowercased().contains(word), "\(evidence): \(line ?? "")") }
            }
        }
    }

    func testOnlyTheDifferentEpisodeWordsRemainAsAPlacementProblem() {
        XCTAssertNil(FriendArrivalWords.placementProblem(.resolved))
        for status in [ImportedSourceResolutionStatus.pending, .contextOnly, .ambiguous, .unavailable] {
            XCTAssertNil(FriendArrivalWords.placementProblem(status), "\(status)")
        }
        XCTAssertEqual(FriendArrivalWords.placementProblem(.wrongSource),
                       "This may not be the same episode or article these Margins were made on.")
    }

    func testThePinnedCardLineShowsOnlyForARoughPlacement() {
        XCTAssertEqual(SharedMarginPlacementWording.pinnedCardLine(for: .roughly(mediaTimeMs: 1)),
                       "Approximate position: ads can differ between copies.")
        XCTAssertNil(SharedMarginPlacementWording.pinnedCardLine(for: .placed(mediaTimeMs: 1)))
        XCTAssertNil(SharedMarginPlacementWording.pinnedCardLine(for: .afterOthers))
    }

    /// #3789: the open item's length decides "past the end", so a sender time beyond it plays after the others, and
    /// a whole-episode Play left at the end offers those Margins instead of skipping them.
    func testTheItemsLengthDecidesPastTheEndAndPlayAtTheEndOffersThoseMargins() {
        let end = 1_800_000
        let session = Session(
            id: "s", itemId: "item", updatedAt: Date(timeIntervalSince1970: 1), status: "in_progress", phase: .itemPlayback,
            currentTargetType: .itemTextTTS, currentTargetId: "item",
            position: Position(charOffset: 0, mediaTimeMs: end - 5_000), completionPercent: 99, playbackRate: 1)
        var midway = session
        midway.position = Position(charOffset: 0, mediaTimeMs: 600_000)
        midway.completionPercent = 33
        let table: [(String, Int?, Int?, [Session], [String])] = [
            ("sender time past the length, at the end", end + 60_000, end, [session], ["m"]),
            ("sender time past the length, mid-way: waits at the end", end + 60_000, end, [midway], []),
            ("sender time inside the length is placed in place, not after the others", 90_000, end, [session], ["m"]),
            ("length unknown: the sender time is trusted", end + 60_000, nil, [midway], []),
        ]
        for (name, senderMs, duration, sessions, behind) in table {
            let entries = SharedMarginReview.entries(
                layers: [layer(finishedPass: true)], records: ["layer": [margin(evidence: .unresolved, sender: senderMs)]],
                durationMs: duration)
            XCTAssertEqual(entries.map(\.playsAfterOthers), [(senderMs ?? 0) > (duration ?? .max)], name)
            XCTAssertEqual(PlayRule.marginsBehindSavedPlace(entries, sessions: sessions, addedAgainAt: nil).map(\.interjection.id), behind, name)
        }
    }

    /// #3788: the "N Margins" pill gives way only while the friend's intro shows. The intro exists exactly when an
    /// unheard friend Margin does, so a listener with their own Margins and none waiting keeps the count.
    func testTheFriendIntroReplacesTheMarginCountOnlyWhileItShows() {
        let waiting = SharedMarginReview.entries(layers: [layer(finishedPass: true)], records: ["layer": [margin(evidence: .unresolved, sender: 5_000)]])
        var heard = margin(evidence: .unresolved, sender: 5_000)
        heard.firstHeardAt = Date(timeIntervalSince1970: 1)
        let afterHearing = SharedMarginReview.entries(layers: [layer(finishedPass: true)], records: ["layer": [heard]])
        XCTAssertNotNil(FriendMarginsIntro(unheardFriendMargins: waiting.map(\.waitingMargin)), "a Margin waits: the intro counts")
        XCTAssertNil(FriendMarginsIntro(unheardFriendMargins: afterHearing.map(\.waitingMargin)), "all heard: the pill returns")
        XCTAssertNil(FriendMarginsIntro(unheardFriendMargins: []), "the listener's own Margins alone: the pill stays")
    }

    private func layer(finishedPass: Bool, type: SharedItemType = .podcast) -> ImportedCommentaryLayer {
        var value = ImportedCommentaryLayer(id: "layer", itemId: "item", packageDigest: "d", packageId: "p",
                                            itemIdentity: SharedItemIdentity(itemType: type, title: "Episode"),
                                            displayLabel: "Cole", importedAt: Date(timeIntervalSince1970: 0),
                                            sourceResolutionStatus: .resolved, isEnabled: true)
        if finishedPass { value.resolvedRecipientEditionSHA256 = "digest" }
        return value
    }

    private func margin(id: String = "m", evidence: AnchorResolutionEvidenceClass, ambiguous: Bool = false,
                        sender: Int?, placedAt: Int? = nil) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(
            id: id, layerId: "layer", packageScopedId: "packet-\(id)", createdAt: Date(timeIntervalSince1970: 0),
            anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: sender),
            approvedTranscript: "Words",
            resolution: ImportedAnchorResolution(evidenceClass: evidence, localMediaTimeMs: placedAt, isAmbiguous: ambiguous))
    }
}
