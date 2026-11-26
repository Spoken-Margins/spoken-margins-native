import Foundation
@testable import SessionKit
import SessionKitPersistence
import SessionKitSharing
import XCTest
#if canImport(AVFoundation)
import AVFoundation
import AudioToolbox
#endif

/// Sending replies back (#3221), the whole loop with real files and real SQLite: A shares a Margin, B imports it and
/// replies, B sends back only the reply, and A's review holds that reply with its parent link resolved.
final class ReplyBackRoundTripTests: XCTestCase {
    private var root: URL!
    private let digest = String(repeating: "ab", count: 32)
    private var episode: SharedItemIdentity {
        SharedItemIdentity(itemType: .other, title: "Harbour Lights", durationMs: 1_800_000, exactEditionSHA256: digest)
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ReplyBackRoundTripTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testBReplyTravelsBackAndAHearsItAfterItsParent() throws {
        let (ana, ben) = (try Person(name: "Ana", root: root, episode: episode), try Person(name: "Ben", root: root, episode: episode))

        // A shares a Margin at 12:34 with B.
        let first = try ana.record("a-1", madeAt: 10, atMs: 754_000)
        let (anaURL, anaManifest) = try ana.send([first], packageId: "package-a", in: root)
        XCTAssertEqual(anaManifest.requiredCapabilities, [SharedCommentaryLayerArtifact.schemaVersion])

        // B made a Margin before the packet arrived, imports it, then replies and adds two more.
        try ben.record("b-before", madeAt: 20, atMs: 100_000)
        guard case .imported = try ben.importPacket(anaURL, at: 100) else { return XCTFail("B should import A's packet") }
        let bensOffer = { try ReplyBackOffer.make(localMargins: ben.margins(), layers: ben.store.loadImportedCommentaryLayers(itemId: ben.itemId)) }
        XCTAssertNil(try bensOffer(), "B has made nothing since the import")
        let reply = try ben.record("b-reply", madeAt: 200, atMs: 755_000, replyingTo: "a-1")
        try ben.record("b-extra", madeAt: 210, atMs: 900_000)
        try ben.record("b-written", madeAt: 220, atMs: 910_000, written: true)

        // B's Share offers the reply (selected) and the other new Margins (not selected). Nothing of A's, nothing older.
        let offer = try XCTUnwrap(try bensOffer())
        XCTAssertEqual(offer.title, "Share replies with Ana")
        XCTAssertEqual(offer.candidates.map(\.id), ["b-reply", "b-extra", "b-written"])
        XCTAssertEqual(offer.candidates.filter(offer.isPreselected).map(\.id), ["b-reply"])
        let importedFromAna = try ben.importedMargins().map(\.id)
        XCTAssertFalse(offer.candidates.contains { importedFromAna.contains($0.id) })

        // B sends back only the pre-selected reply.
        let (benURL, benManifest) = try ben.send(offer.candidates.filter(offer.isPreselected), packageId: "package-b", in: root)
        XCTAssertEqual(benManifest.requiredCapabilities, [SharedCommentaryLayerArtifact.schemaVersion], "no new capability")
        XCTAssertEqual(
            Set(benManifest.artifacts.map(\.kind)),
            [SpokenMarginsArtifactKind.commentaryLayer, SpokenMarginsArtifactKind.conversation],
            "no new packet key: the reply's link rides the optional conversation artifact of #472"
        )
        let sent = try SpokenMarginsPackageArchive.read(from: benURL, extractingAssetsTo: root.appendingPathComponent("check-b"))
        XCTAssertEqual(sent.commentaryLayers.flatMap(\.interjections).map(\.packageScopedId), ["b-reply"])
        XCTAssertEqual(reply.replyTo?.parentPackageScopedId, "a-1")

        // A imports it and reviews.
        guard case .imported = try ana.importPacket(benURL, at: 300) else { return XCTFail("A should import B's packet") }
        let own = try ana.margins()
        let entries = try SharedMarginReview.entries(itemId: ana.itemId, in: ana.store, ownMargins: own)
        XCTAssertEqual(entries.map(\.interjection.packageScopedId), ["b-reply"], "the review holds the reply and nothing else")
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.mediaTimeMs, 755_000)
        XCTAssertEqual(entry.replyContext?.parent, .yours(interjectionId: Interjection.sessionScopedId(sessionId: ana.sessionId, id: "a-1"), mediaTimeMs: 754_000))
        XCTAssertEqual(entry.replyContext?.caption, "Reply to your Margin at 12:34")

        // The parent link resolves to A's own Margin.
        let graph = MarginReplyGraph.build(
            localMargins: own, layers: try ana.store.loadImportedCommentaryLayers(itemId: ana.itemId), importedMargins: try ana.importedMargins()
        )
        guard case .linked(let link)? = graph.states[.imported(entry.interjection.id)] else {
            return XCTFail("the reply should link to its parent: \(String(describing: graph.states))")
        }
        XCTAssertEqual(link.parent, .local(Interjection.sessionScopedId(sessionId: ana.sessionId, id: "a-1")))

        // One tap plays the lead-in, then A's own Margin, then the reply.
        let steps = SharedMarginReview.playlist(for: entries, ownMargins: own)
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[0].ownParent?.id, "a-1")
        XCTAssertEqual(steps[0].anchor.caption, "Your Margin at 12:34")
        XCTAssertEqual(steps[1].entry?.interjection.packageScopedId, "b-reply")
        XCTAssertEqual(try ana.store.quarantinedRecordCount(), 0)
        XCTAssertEqual(try ben.store.quarantinedRecordCount(), 0)
    }

    /// #3365: a friend can answer one Margin in writing and another in voice. Both reach A's review, in their order,
    /// each saying which of A's Margins it answers; the written one is read aloud, introduced as B's, and gets no
    /// second tone after its parent.
    func testAWrittenReplyAndAVoiceReplyAreBothInTheReviewInOrder() throws {
        let (ana, ben) = (try Person(name: "Ana", root: root, episode: episode), try Person(name: "Ben", root: root, episode: episode))
        try ana.record("a-1", madeAt: 10, atMs: 754_000)
        let (anaURL, _) = try ana.send(try ana.margins(), packageId: "package-a", in: root)
        guard case .imported = try ben.importPacket(anaURL, at: 100) else { return XCTFail("B should import A's packet") }

        let spoken = try ben.record("b-voice", madeAt: 200, atMs: 755_000, replyingTo: "a-1")
        let written = try ben.record("b-written", madeAt: 210, atMs: 790_000, replyingTo: "a-1", written: true)
        let (benURL, benManifest) = try ben.send([written, spoken], packageId: "package-b", in: root)
        XCTAssertEqual(benManifest.requiredCapabilities, [SharedCommentaryLayerArtifact.schemaVersion], "a written reply needs no new capability")
        guard case .imported = try ana.importPacket(benURL, at: 300) else { return XCTFail("A should import B's packet") }

        let imported = try ana.importedMargins()
        let importedWritten = try XCTUnwrap(imported.first { $0.packageScopedId == "b-written" })
        XCTAssertNil(importedWritten.audioPath, "a written Margin arrives with no recording")
        XCTAssertNil(importedWritten.audioDurationMs, "and no length, which is how the item screen tells it from a voice Margin")
        XCTAssertTrue(importedWritten.isWritten)
        XCTAssertFalse(try XCTUnwrap(imported.first { $0.packageScopedId == "b-voice" }).isWritten)

        let own = try ana.margins()
        let entries = try SharedMarginReview.entries(itemId: ana.itemId, in: ana.store, ownMargins: own)
        XCTAssertEqual(entries.map(\.interjection.packageScopedId), ["b-voice", "b-written"], "both are in the review, in place order")
        XCTAssertEqual(entries.map { $0.replyContext?.caption }, Array(repeating: "Reply to your Margin at 12:34", count: 2))
        XCTAssertEqual(entries.map(\.anchor.isReadAloud), [false, true])
        XCTAssertEqual(entries[1].writtenReading, WrittenMarginReading(intro: "Ben wrote:", text: "Words from Ben.", itemId: ana.itemId))
        XCTAssertNil(entries[0].writtenReading)
        XCTAssertTrue(SharedMarginReview.offerMessage(for: entries).hasPrefix("2 new Margins from Ben."))

        // The item screen says these are replies to A's Margin, from Ben, and does not explain what a Margin is to the
        // person who made it (#3889). Worked out from the saved links, so it holds after a relaunch.
        XCTAssertEqual(entries.map { $0.waitingMargin.replyToYouParentId }, Array(repeating: Interjection.sessionScopedId(sessionId: ana.sessionId, id: "a-1"), count: 2))
        let intro = try XCTUnwrap(FriendMarginsIntro(unheardFriendMargins: entries.map(\.waitingMargin)))
        XCTAssertEqual(intro.senderLine, "Replies from Ben")
        XCTAssertEqual(intro.countLine.prefix(30), "2 replies to your Margin · abo")
        XCTAssertNil(intro.explanation)
        let skip = ItemListeningChoices(
            unheardFriendMargins: entries.map(\.waitingMargin), hasFinishedSession: false,
            hasContinuationSession: false, isPreparingAudio: false
        )
        XCTAssertTrue(skip.marginsOnlyTitle?.hasPrefix("Skip to Ben's replies · ") == true, skip.marginsOnlyTitle ?? "nil")

        // One tap: lead-in and tone, A's own Margin, the voice reply, then the written reply, which is announced by the
        // same tone any Margin not preceded by its parent gets.
        let steps = SharedMarginReview.playlist(for: entries, ownMargins: own)
        XCTAssertEqual(steps.count, 3)
        XCTAssertEqual(steps[0].ownParent?.id, "a-1")
        XCTAssertEqual(steps[2].entry?.interjection.packageScopedId, "b-written")
        XCTAssertEqual(SharedMarginReview.chimedMarginIds(steps), [steps[0].anchor.marginId, steps[2].anchor.marginId])
        XCTAssertEqual(try ana.store.quarantinedRecordCount(), 0)
    }

    func testTheListenerCanAddAnotherNewMarginAndItTravelsToo() throws {
        let (ana, ben) = (try Person(name: "Ana", root: root, episode: episode), try Person(name: "Ben", root: root, episode: episode))
        let (anaURL, _) = try ana.send([try ana.record("a-1", madeAt: 10, atMs: 754_000)], packageId: "package-a", in: root)
        try ben.importPacket(anaURL, at: 100)
        try ben.record("b-reply", madeAt: 200, atMs: 755_000, replyingTo: "a-1")
        try ben.record("b-extra", madeAt: 210, atMs: 900_000)
        let offer = try XCTUnwrap(ReplyBackOffer.make(localMargins: ben.margins(), layers: ben.store.loadImportedCommentaryLayers(itemId: ben.itemId)))

        // The extra Margin is ticked by hand: the packet carries both, and A hears the reply with its parent and the
        // extra one as an ordinary Margin.
        let (benURL, _) = try ben.send(offer.candidates, packageId: "package-b", in: root)
        try ana.importPacket(benURL, at: 300)
        let own = try ana.margins()
        let entries = try SharedMarginReview.entries(itemId: ana.itemId, in: ana.store, ownMargins: own)
        XCTAssertEqual(entries.map(\.interjection.packageScopedId), ["b-reply", "b-extra"])
        XCTAssertNotNil(entries[0].replyContext)
        XCTAssertNil(entries[1].replyContext)
        XCTAssertEqual(SharedMarginReview.playlist(for: entries, ownMargins: own).count, 3)
        // One reply and one new Margin: "From Ben", both counted, still no explanation (#3889).
        let intro = try XCTUnwrap(FriendMarginsIntro(unheardFriendMargins: entries.map(\.waitingMargin)))
        XCTAssertEqual(intro.senderLine, "From Ben")
        XCTAssertTrue(intro.countLine.hasPrefix("1 reply and 1 new Margin · about"), intro.countLine)
        XCTAssertNil(intro.explanation)
    }

    func testTwoPacketsFromTheSameFriendNameThemOnceAndOfferTheReplyToTheSecond() throws {
        // Ben imports two packets from Ana and answers the second: the offer holds the reply and names Ana once.
        let (ana, ben) = (try Person(name: "Ana", root: root, episode: episode), try Person(name: "Ben", root: root, episode: episode))
        let (one, _) = try ana.send([try ana.record("a-1", madeAt: 10, atMs: 754_000)], packageId: "package-a1", in: root)
        let (two, _) = try ana.send([try ana.record("a-2", madeAt: 11, atMs: 800_000)], packageId: "package-a2", in: root)
        try ben.importPacket(one, at: 100)
        try ben.importPacket(two, at: 110)
        try ben.record("b-reply", madeAt: 200, atMs: 801_000, replyingTo: "a-2")
        let offer = try XCTUnwrap(ReplyBackOffer.make(localMargins: ben.margins(), layers: ben.store.loadImportedCommentaryLayers(itemId: ben.itemId)))
        XCTAssertEqual(offer.replies.map(\.id), ["b-reply"])
        XCTAssertEqual(offer.title, "Share replies with Ana")
    }
}
