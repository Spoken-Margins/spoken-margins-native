import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// "Review new Margins" (#474): which shared Margins are offered, and in what order.
final class SharedMarginReviewTests: XCTestCase {
    private let early = Date(timeIntervalSince1970: 1_700_000_000)
    private let later = Date(timeIntervalSince1970: 1_700_000_600)

    private func layer(
        _ id: String, label: String? = "Ana", enabled: Bool = true, muted: Bool = false,
        status: ImportedSourceResolutionStatus = .resolved, deleted: Bool = false
    ) -> ImportedCommentaryLayer {
        ImportedCommentaryLayer(
            id: id, itemId: "item", packageDigest: "digest-\(id)", packageId: "package-\(id)",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode", durationMs: 1_800_000),
            displayLabel: label, importedAt: early, sourceResolutionStatus: status,
            isEnabled: enabled, isMuted: muted, deletedAt: deleted ? early : nil
        )
    }

    private func margin(
        _ id: String, in layerId: String = "ana", at ms: Int? = 60_000,
        evidence: AnchorResolutionEvidenceClass = .acousticVerified, voice: Bool = true,
        heard: Bool = false, createdAt: Date? = nil, replyLinks: [MarginReplyLink]? = nil, words: String = "Words"
    ) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(
            id: id, layerId: layerId, packageScopedId: id, createdAt: createdAt ?? early,
            anchorEvidence: PortableAnchorEvidence(anchorType: .media), approvedTranscript: words,
            // As an import builds them (`SharingFoundation`): a written Margin has no recording and so no length.
            audioPath: voice ? "ImportedCommentary/\(id).m4a" : nil, audioDurationMs: voice ? 4_000 : nil,
            resolution: ImportedAnchorResolution(evidenceClass: evidence, localMediaTimeMs: ms, confidence: 1),
            firstHeardAt: heard ? later : nil, replyLinks: replyLinks
        )
    }

    private func ids(_ entries: [SharedMarginReview.Entry]) -> [String] { entries.map(\.interjection.id) }

    /// #3059: the big button just plays when the new Margins are still ahead; it asks only about the ones passed.
    func testContinueAsksOnlyAboutMarginsTheListenerIsAlreadyPast() {
        let entries = SharedMarginReview.entries(
            layers: [layer("ana")],
            records: ["ana": [margin("passed", at: 60_000), margin("here", at: 120_000), margin("ahead", at: 300_000)]]
        )
        XCTAssertEqual(ids(SharedMarginReview.entriesBehind(entries, placeMs: 0)), [], "an episode not started: just play")
        XCTAssertEqual(ids(SharedMarginReview.entriesBehind(entries, placeMs: 60_000)), [], "a Margin at the place is still ahead")
        XCTAssertEqual(ids(SharedMarginReview.entriesBehind(entries, placeMs: 120_001)), ["passed", "here"])
        XCTAssertEqual(ids(SharedMarginReview.entriesBehind(entries, placeMs: 1_200_000)), ["passed", "here", "ahead"])
        XCTAssertEqual(ids(SharedMarginReview.entriesBehind(entries, placeMs: nil)), ["passed", "here", "ahead"], "place unknown: ask, as before")
    }

    func testOnlyMarginsTheListenerHasntHeardAreOffered() {
        let entries = SharedMarginReview.entries(
            layers: [layer("ana")],
            records: ["ana": [margin("new", at: 90_000), margin("heard", at: 30_000, heard: true)]]
        )
        XCTAssertEqual(ids(entries), ["new"])
    }

    func testAMarginWithNoPlaceInThisCopyIsLeftOut() {
        let records = [
            margin("ok", at: 10_000),
            margin("unresolved", at: nil, evidence: .unresolved),
            margin("absent", at: 40_000, evidence: .absentFromRecipientEdition),
            margin("textOnly", at: nil, evidence: .articleTextVerified)
        ]
        XCTAssertEqual(ids(SharedMarginReview.entries(layers: [layer("ana")], records: ["ana": records])), ["ok"])
    }

    /// #3365: a written Margin is in the review (its words are read aloud); a voice Margin with no words and no
    /// recording is not, and neither is a written one with no place in this copy.
    func testAWrittenMarginIsOfferedAndAVoiceMarginWithoutItsRecordingIsNot() {
        let records = [
            margin("ok", at: 10_000),
            margin("written", at: 20_000, voice: false),
            margin("written-nowhere", at: nil, evidence: .unresolved, voice: false),
            margin("blank", at: 30_000, voice: false, words: "  \n "),
            margin("placeholder", at: 50_000, voice: false, words: "Voice Margin at 12:34 in “Episode”, recorded 30 Oct 2026")
        ]
        let entries = SharedMarginReview.entries(layers: [layer("ana")], records: ["ana": records])
        XCTAssertEqual(ids(entries), ["ok", "written"])
        XCTAssertEqual(entries.map(\.anchor.isReadAloud), [false, true])
    }

    /// The same table `isWritten` is judged by: it is what keeps "Cole wrote: Voice Margin at 12:34" from being said.
    func testWhichImportedMarginsAreWritten() {
        func isWritten(_ words: String, voice: Bool = false) -> Bool { margin("m", voice: voice, words: words).isWritten }
        XCTAssertTrue(isWritten("Great point about the harbour."))
        XCTAssertTrue(isWritten("  padded with spaces\n"))
        XCTAssertTrue(isWritten("Café très bien, 東京は良い 🎧"), "Unicode")
        XCTAssertTrue(isWritten(String(repeating: "A long note. ", count: 2_000)), "very long")
        XCTAssertTrue(isWritten("Voice Margin at noon is when I listen"), "a note that merely begins that way is a note")
        XCTAssertTrue(isWritten("My Voice Margin at 12:34 was lost"))
        XCTAssertFalse(isWritten(""))
        XCTAssertFalse(isWritten("   "))
        XCTAssertFalse(isWritten("\n\t"))
        XCTAssertFalse(isWritten("Voice Margin"), "the placeholder with every optional part left out (an article, no title, no date)")
        XCTAssertFalse(isWritten("Voice Margin at 12:34"))
        XCTAssertFalse(isWritten("Voice Margin at 1:02:03"))
        XCTAssertFalse(isWritten("Voice Margin in “Harbour Lights”"))
        XCTAssertFalse(isWritten("Voice Margin at 12:34 in “Harbour Lights”, recorded 30 Oct 2026"))
        XCTAssertFalse(isWritten("Voice Margin at 0:05, recorded 1 Nov 2026"))
        XCTAssertFalse(isWritten("  Voice Margin at 12:34 in “Caf\u{65}\u{301}”  "), "padding, and a decomposed é")
        XCTAssertFalse(isWritten("Voice Margin at 12:34 in “…”, recorded 30 Oct 2026"))
        XCTAssertFalse(isWritten("Great point about the harbour.", voice: true), "a Margin with its recording is a voice Margin")
    }

    func testLayersThatWouldNotPlayAutomaticallyAreLeftOut() {
        let layers = [
            layer("ana"),
            layer("off", enabled: false),
            layer("wrong", status: .wrongSource),
            layer("gone", deleted: true)
        ]
        let records = Dictionary(uniqueKeysWithValues: layers.map { ($0.id, [margin("m-\($0.id)", in: $0.id)]) })
        XCTAssertEqual(ids(SharedMarginReview.entries(layers: layers, records: records)), ["m-ana"])
    }

    func testAMutedFriendsMarginsStillCountAsNew() {
        let entries = SharedMarginReview.entries(layers: [layer("ana", muted: true)], records: ["ana": [margin("m1")]])
        XCTAssertEqual(ids(entries), ["m1"], "mute silences the cue, as it does for the automatic prompts")
        XCTAssertTrue(entries[0].layer.isMuted)
    }

    func testMarginsPlayInOrderOfPlaceAcrossFriends() {
        let entries = SharedMarginReview.entries(
            layers: [layer("ana", label: "Ana"), layer("ben", label: "Ben")],
            records: [
                "ana": [margin("a-late", at: 300_000), margin("a-early", at: 20_000)],
                "ben": [margin("b-mid", in: "ben", at: 120_000)]
            ]
        )
        XCTAssertEqual(ids(entries), ["a-early", "b-mid", "a-late"])
    }

    func testTwoMarginsAtTheSamePlaceAreOrderedBySenderThenCreationTime() {
        let layers = [layer("ana", label: "ana"), layer("ben", label: "Ben"), layer("zed", label: nil)]
        let records: [String: [ImportedCommentaryInterjection]] = [
            "ana": [margin("a-2", at: 60_000, createdAt: later), margin("a-1", at: 60_000, createdAt: early)],
            "ben": [margin("b-1", in: "ben", at: 60_000)],
            "zed": [margin("z-1", in: "zed", at: 60_000)]
        ]
        let expected = ["a-1", "a-2", "b-1", "z-1"]
        XCTAssertEqual(ids(SharedMarginReview.entries(layers: layers, records: records)), expected,
                       "ana before Ben ignoring case, a friend's own Margins by when they made them, 'Imported collection' last")
    }

    func testTheSameMarginsPlayTheSameWayWhateverOrderTheyArriveIn() {
        let layers = [layer("a", label: "Sam"), layer("b", label: "sam"), layer("c", label: "Sam")]
        let all: [ImportedCommentaryInterjection] = [
            margin("a1", in: "a", at: 50_000, createdAt: later),
            margin("a2", in: "a", at: 50_000, createdAt: early),
            margin("b1", in: "b", at: 50_000, createdAt: early),
            margin("c1", in: "c", at: 50_000, createdAt: early)
        ]
        func play(_ records: [ImportedCommentaryInterjection], _ layers: [ImportedCommentaryLayer]) -> [String] {
            var byLayer: [String: [ImportedCommentaryInterjection]] = [:]
            for record in records { byLayer[record.layerId, default: []].append(record) }
            return ids(SharedMarginReview.entries(layers: layers, records: byLayer))
        }
        let reference = play(all, layers)
        XCTAssertEqual(reference.count, 4)
        for records in permutations(all) {
            for shuffledLayers in [layers, layers.reversed()] {
                XCTAssertEqual(play(records, shuffledLayers), reference)
            }
        }
        // Same place and the same label up to case: the exact label ("Sam" before "sam"), then when it was made, then its id.
        XCTAssertEqual(reference, ["a2", "c1", "a1", "b1"])
    }

    func testEntriesCarryTheIdentityTheTimelineUses() throws {
        let entry = try XCTUnwrap(SharedMarginReview.entries(layers: [layer("ana")], records: ["ana": [margin("m1", at: 75_000)]]).first)
        XCTAssertEqual(entry.marginId, "shared::ana::m1")
        XCTAssertEqual(entry.anchor, MarginMomentAnchor(marginId: "shared::ana::m1", mediaTimeMs: 75_000, label: "Ana", isApproximate: false))
        XCTAssertEqual(SharedMarginReview.senderLabel(of: layer("x", label: "  ")), "Imported collection")
    }

    func testAMarginPlacedByClockOrMapIsMarkedApproximate() {
        let entries = SharedMarginReview.entries(
            layers: [layer("ana")],
            records: ["ana": [
                margin("exact", at: 10_000, evidence: .exactEdition),
                margin("map", at: 20_000, evidence: .mapInterpolated),
                margin("clock", at: 30_000, evidence: .timestampFallback)
            ]]
        )
        XCTAssertEqual(entries.map(\.isApproximate), [false, true, true])
    }

    func testReadingFromTheRepositoryDropsMarginsOnceTheirVoiceHasPlayed() throws {
        let repository = InMemorySessionRepository()
        _ = try repository.importCommentaryLayer(layer("ana"), interjections: [margin("m1", at: 30_000), margin("m2", at: 90_000)])
        XCTAssertEqual(ids(try SharedMarginReview.entries(itemId: "item", in: repository)), ["m1", "m2"])
        XCTAssertTrue(try SharedMarginReview.entries(itemId: "elsewhere", in: repository).isEmpty)

        _ = try repository.markImportedCommentaryInterjectionHeard(id: "m1", at: later)
        XCTAssertEqual(ids(try SharedMarginReview.entries(itemId: "item", in: repository)), ["m2"])
    }

    private func ownMargin(
        _ id: String, session: String = "s", item: String = "item", sharedAs: [MarginPacketIdentity]? = nil
    ) -> Interjection {
        Interjection(
            id: id, itemId: item, sessionId: session, targetType: .item, targetId: item, createdAt: early, roughPercent: 0,
            anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 754_000),
            audioPath: "\(id).m4a", audioStatus: "ready", transcriptionStatus: "complete", transcript: "Words", cleanedTranscript: nil,
            displayText: "Words", status: "active", sharedAs: sharedAs
        )
    }

    /// #3353: a friend's reply says which of the listener's Margins it answers, even when the listener shared that
    /// Margin in an earlier listening session than the one the item screen holds.
    func testAReplyToAMarginSharedInAnEarlierSessionFindsItsParent() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("SharedMarginReviewTests-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try SQLiteSessionStore(path: path)
        try store.saveItem(Item(id: "item", title: "Episode", mediaType: "text", text: "One.", externalReference: nil, status: "Ready"))
        for (id, seconds) in [("session-shared", 1.0), ("session-later", 50.0)] {
            try store.saveSession(Session(
                id: id, itemId: "item", createdAt: Date(timeIntervalSince1970: seconds), updatedAt: Date(timeIntervalSince1970: seconds),
                status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: "item",
                position: Position(), completionPercent: 0, playbackRate: 1
            ))
        }
        let sent = MarginPacketIdentity(packageDigest: "digest-mine", packageScopedId: "margin-0001")
        try store.saveInterjection(ownMargin("mine", session: "session-shared", sharedAs: [sent]))

        // The friend's reply, imported with the link to that Margin.
        let link = MarginReplyLink.replying(to: sent, parentConversationId: nil)
        _ = try store.importCommentaryLayer(layer("ana"), interjections: [margin("reply", at: 755_000, replyLinks: [link])])

        let detail = try ItemDetailLoader.load(
            id: "item", store: store, snapshotItemId: nil, snapshotSessionId: nil, placementPasses: SharedMarginPlacementPasses())
        XCTAssertTrue(detail.interjections.isEmpty, "the open item holds only the newest session's Margins")
        let rows = try MarginRowsReading.item("item", store: store).privateRows.map(\.interjection)
        XCTAssertEqual(rows.map(\.id), ["mine"])

        func caption(ownMargins: [Interjection]) -> String? {
            SharedMarginReview.entries(
                layers: detail.importedCommentaryLayers, records: detail.importedCommentaryInterjections, ownMargins: ownMargins
            ).first?.replyContext?.caption
        }
        XCTAssertEqual(caption(ownMargins: detail.interjections), "Reply to a Margin you don't have yet", "what the item screen alone gave")
        let own = SharedMarginReview.ownMargins(itemId: "item", openItem: detail.interjections, rows: rows)
        XCTAssertEqual(caption(ownMargins: own), "Reply to your Margin at 12:34")
    }

    func testOwnMarginsOfAnItemAreMergedByIdWithEveryPacketIdentity() {
        let first = MarginPacketIdentity(packageDigest: "d1", packageScopedId: "m-1")
        let second = MarginPacketIdentity(packageDigest: "d2", packageScopedId: "m-1")
        let merged = SharedMarginReview.ownMargins(
            itemId: "item",
            openItem: [ownMargin("m-1", sharedAs: [first]), ownMargin("new"), ownMargin("elsewhere", item: "other")],
            rows: [ownMargin("m-1", sharedAs: [second]), ownMargin("old"), ownMargin("also-elsewhere", item: "other")]
        )
        XCTAssertEqual(merged.map(\.id), ["m-1", "new", "old"])
        XCTAssertEqual(Set(merged[0].sharedAs ?? []), [first, second], "a list read before the share doesn't hide the identity")
        XCTAssertTrue(SharedMarginReview.ownMargins(itemId: "item", openItem: [], rows: []).isEmpty)
    }

    func testTheOfferNamesHowManyAndWhose() throws {
        func entries(_ senders: [String]) -> [SharedMarginReview.Entry] {
            let layers = senders.enumerated().map { layer("l\($0.offset)", label: $0.element) }
            var records: [String: [ImportedCommentaryInterjection]] = [:]
            for (index, layer) in layers.enumerated() { records[layer.id] = [margin("m\(index)", in: layer.id, at: 10_000 * (index + 1))] }
            return SharedMarginReview.entries(layers: layers, records: records)
        }
        XCTAssertEqual(SharedMarginReview.offerMessage(for: entries(["Ana"])),
                       "1 new Margin from Ana. Hear it in place first, then carry on from where you were.")
        XCTAssertEqual(SharedMarginReview.offerMessage(for: entries(["Ana", "Ben"])),
                       "2 new Margins from Ana and Ben. Hear them in place first, then carry on from where you were.")
        XCTAssertEqual(SharedMarginReview.offerMessage(for: entries(["Ana", "Ben", "Cy"])),
                       "3 new Margins from Ana, Ben and Cy. Hear them in place first, then carry on from where you were.")
        XCTAssertEqual(SharedMarginReview.offerMessage(for: entries(["Ana", "Ben", "Cy", "Di", "Ed"])),
                       "5 new Margins from Ana, Ben and 3 others. Hear them in place first, then carry on from where you were.")
        let twoFromOne = SharedMarginReview.entries(layers: [layer("ana")], records: ["ana": [margin("a", at: 1_000), margin("b", at: 2_000)]])
        XCTAssertEqual(SharedMarginReview.offerMessage(for: twoFromOne),
                       "2 new Margins from Ana. Hear them in place first, then carry on from where you were.")
    }

    func testAnOfferTurnedDownStaysQuietUntilAnotherMarginArrives() {
        var memory = NewMarginsOfferMemory()
        XCTAssertFalse(memory.isDeclined(itemId: "ep", margins: ["m1"]), "nothing has been turned down yet")

        memory.decline(itemId: "ep", margins: ["m1", "m2"])
        XCTAssertTrue(memory.isDeclined(itemId: "ep", margins: ["m1", "m2"]))
        XCTAssertTrue(memory.isDeclined(itemId: "ep", margins: ["m2"]), "hearing one some other way doesn't bring the offer back")
        XCTAssertFalse(memory.isDeclined(itemId: "ep", margins: ["m1", "m2", "m3"]), "a new Margin arrived")
        XCTAssertFalse(memory.isDeclined(itemId: "other", margins: ["m1"]), "per item")

        memory.decline(itemId: "ep", margins: ["m1", "m2", "m3"])
        XCTAssertTrue(memory.isDeclined(itemId: "ep", margins: ["m3", "m1"]))
        XCTAssertTrue(memory.isDeclined(itemId: "ep", margins: []), "nothing new is nothing to ask about")
    }

    /// A review plays what the list says, in that order, end to end.
    func testAListFromTheReviewDrivesASequenceThroughEveryMargin() throws {
        let entries = SharedMarginReview.entries(
            layers: [layer("ana", label: "Ana"), layer("ben", label: "Ben")],
            records: [
                "ana": [margin("a1", at: 60_000), margin("a2", at: 240_000)],
                "ben": [margin("b1", in: "ben", at: 60_000)]
            ]
        )
        var sequence = try XCTUnwrap(MarginMomentSequence(itemId: "item", reviewing: entries.map(\.anchor), returnToMediaTimeMs: 900_000))
        var heard: [String] = []
        var position = sequence.startMediaTimeMs
        for _ in 0..<2_000 where sequence.phase != .listening {
            let next = position + 500
            guard let playing = sequence.progressed(from: position, to: next) else {
                position = next
                continue
            }
            heard.append(playing.label ?? "?")
            position = finish(&sequence, at: next, heard: &heard)
        }
        XCTAssertEqual(heard, ["Ana", "Ben", "Ana"])
        XCTAssertEqual(sequence.phase, .listening)
    }

    /// Reports the playing voice as finished the way the conductor does, following a hop or the next Margin.
    private func finish(_ sequence: inout MarginMomentSequence, at position: Int, heard: inout [String]) -> Int {
        while true {
            switch sequence.marginFinished(sourceAtMediaTimeMs: position) {
            case .seek(let ms): return ms
            case .continueSource, .reviewDone: return position
            case .playNow(let margin): heard.append(margin.label ?? "?")
            }
        }
    }

    private func permutations<T>(_ items: [T]) -> [[T]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { index -> [[T]] in
            var rest = items
            let head = rest.remove(at: index)
            return permutations(rest).map { [head] + $0 }
        }
    }
}
