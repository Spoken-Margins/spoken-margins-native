import Foundation
@testable import SessionKit
import SessionKitPersistence
import SessionKitSharing
@testable import CoopPacket
import XCTest

/// A friend shares again after adding Margins (#858), with real packets: written the way the app
/// writes them (a new share time and new packet digest each time, the Margins counted from 1 in each
/// packet), read back, and imported into a real SQLite Library. exportPacket also imports every
/// packet with the Build 29 reader. The table of neighbouring inputs is in
/// SessionKitCoreTests/ImportedMarginResendsTests; this checks the whole path.
final class CoopResendTests: XCTestCase {
    private var root: URL!
    private var packetsMade = 0
    private var senderSessions: [String: String] = [:]

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "CoopResendTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private struct Said {
        let words: String
        let atMs: Int
        init(_ words: String, at atMs: Int) { self.words = words; self.atMs = atMs }
    }

    private let one = Said("The ad read starts here.", at: 60_000)
    private let two = Said("This is the claim I doubt.", at: 600_000)
    private let three = Said("Back to the claim: the numbers don't add up.", at: 1_200_000)

    func testAnUpdateAfterTheOriginalAddsOnlyWhatIsNew() throws {
        let first = try share("Ada", [one, two])
        let update = try share("Ada", [one, two, three])
        let store = try freshStore()
        XCTAssertTrue(try open(first, in: store).isImported)
        XCTAssertTrue(try open(update, in: store).isImported)
        XCTAssertEqual(try heard(in: store), [one.words, two.words, three.words].sorted())
        XCTAssertEqual(try layers(in: store).count, 2, "the original, and a layer for the one new Margin")
        // Opening either again adds nothing.
        XCTAssertFalse(try open(first, in: store).isImported)
        XCTAssertFalse(try open(update, in: store).isImported)
        XCTAssertEqual(try heard(in: store).count, 3)
    }

    func testAnUpdateBeforeTheOriginalGivesTheSameMargins() throws {
        let first = try share("Ada", [one, two])
        let update = try share("Ada", [one, two, three])
        let store = try freshStore()
        XCTAssertTrue(try open(update, in: store).isImported)
        XCTAssertFalse(try open(first, in: store).isImported, "everything in it is already held")
        XCTAssertEqual(try heard(in: store), [one.words, two.words, three.words].sorted())
        XCTAssertEqual(try layers(in: store).count, 1)
    }

    func testARepliesParentIsFoundWhicheverPacketItNames() throws {
        let first = try share("Ada", [one, two])
        let update = try share("Ada", [one, two, three])
        // Ben answers Ada's second Margin from each of her packets.
        let toFirst = try share("Ben", [Said("I doubt it too.", at: 600_000)], replyingTo: (first, "margin-0002"))
        let toUpdate = try share("Ben", [Said("The numbers are in the show notes.", at: 1_200_000)], replyingTo: (update, "margin-0003"))
        for order in [[first, update, toFirst, toUpdate], [toUpdate, toFirst, update, first], [update, toFirst, first, toUpdate]] {
            let store = try freshStore()
            for packet in order { _ = try open(packet, in: store) }
            let all = try layers(in: store)
            let margins = try all.flatMap { try store.loadImportedCommentaryInterjections(layerId: $0.id) }
            let graph = MarginReplyGraph.build(localMargins: [], layers: all, importedMargins: margins)
            XCTAssertEqual(margins.count, 5, "each Margin once")
            for reply in margins where reply.replyLinks != nil {
                guard case .linked(let link)? = graph.states[.imported(reply.id)],
                      case .imported(let parentId)? = link.parent else {
                    return XCTFail("\(reply.approvedTranscript) has no parent in order \(order.map(\.name))")
                }
                let parent = try XCTUnwrap(margins.first { $0.id == parentId })
                XCTAssertEqual(parent.approvedTranscript, reply.replyLinks?.first?.parentPackageScopedId == "margin-0002" ? two.words : three.words)
            }
        }
    }

    func testTwoFriendsWhoSaidTheSameThingKeepBothMargins() throws {
        let store = try freshStore()
        _ = try open(try share("Ada", [one, two]), in: store)
        _ = try open(try share("Ben", [one, two]), in: store)
        XCTAssertEqual(try heard(in: store).count, 4)
        XCTAssertEqual(try layers(in: store).count, 2)
    }

    func testAMarginTheFriendDroppedStaysAndTheNumberingShiftsHarmlessly() throws {
        // Dropping "one" renumbers the update (margin-0001 is now "two").
        let first = try share("Ada", [one, two])
        let update = try share("Ada", [two, three])
        for order in [[first, update], [update, first]] {
            let store = try freshStore()
            for packet in order { _ = try open(packet, in: store) }
            XCTAssertEqual(try heard(in: store), [one.words, two.words, three.words].sorted(), "order \(order.map(\.name))")
        }
    }

    func testAuditSameDisplayLabelDifferentPeopleKeepBoth() throws {
        let first = try share("Sam", [one], person: "Sam A")
        let second = try share("Sam", [one], person: "Sam B")
        for order in [[first, second], [second, first]] {
            let store = try freshStore()
            for packet in order { _ = try open(packet, in: store) }
            XCTAssertEqual(try heard(in: store).count, 2)
        }
    }

    func testAuditRealPacketsAgreeInAllTwentyFourOrders() throws {
        let first = try share("Ada", [one, two])
        let update = try share("Ada", [one, two, three])
        let toFirst = try share("Ben", [Said("Agreed", at: 600_000)], replyingTo: (first, "margin-0002"))
        let toUpdate = try share("Ben", [Said("Another thought", at: 1_200_000)], replyingTo: (update, "margin-0003"))
        let report = try CoopCheck.run([first, update, toFirst, toUpdate].map { root.appending(path: "\($0.name).spokenmargins") })
        XCTAssertTrue(report.passed, report.text)
        XCTAssertTrue(report.text.contains("24 orders"), report.text)
    }

    func testAuditIdenticalReplyWordsToDifferentParentsKeepBoth() throws {
        let ada = try share("Ada", [one])
        let chris = try share("Chris", [one])
        let benA = try share("Ben", [Said("Agreed", at: 60_000)], replyingTo: (ada, "margin-0001"))
        let benC = try share("Ben", [Said("Agreed", at: 60_000)], replyingTo: (chris, "margin-0001"))
        let report = try CoopCheck.run([ada, chris, benA, benC].map { root.appending(path: "\($0.name).spokenmargins") })
        XCTAssertTrue(report.passed, report.text)
        XCTAssertTrue(report.text.contains("4 held Margin(s)"), report.text)
        XCTAssertTrue(report.text.contains("2 linked"), report.text)
    }

    func testAuditRepresentationProvenanceSurvivesRenumbering() throws {
        let first = try share("Ada", [one, two])
        let update = try share("Ada", [two, three])
        let originalRecord = try XCTUnwrap(first.contents.commentaryLayers.first?.interjections.last)
        let updatedRecord = try XCTUnwrap(update.contents.commentaryLayers.first?.interjections.first)
        XCTAssertNotEqual(originalRecord.packageScopedId, updatedRecord.packageScopedId)
        XCTAssertEqual(originalRecord.defaultRepresentationId, updatedRecord.defaultRepresentationId)
        XCTAssertNotNil(MarginShareProvenance.token(representationID: originalRecord.defaultRepresentationId))
    }

    // MARK: Helpers

    private struct Shared {
        let name: String
        let contents: VerifiedSpokenMarginsPackage
        var digest: String { contents.manifest.contentDigest ?? "" }
    }

    private func share(
        _ sender: String, _ margins: [Said], replyingTo parent: (Shared, String)? = nil, person: String? = nil
    ) throws -> Shared {
        let person = person ?? sender
        if senderSessions[person] == nil { senderSessions[person] = "session-source-" + UUID().uuidString }
        packetsMade += 1
        let name = "\(sender)-\(packetsMade)"
        // The app stamps each share with the time of sharing, so a re-share never repeats it.
        let sharedAt = Date(timeIntervalSince1970: 1_777_000_000 + Double(packetsMade) * 86_400)
        let link = parent.map { MarginReplyLink.replying(to: MarginPacketIdentity(packageDigest: $0.0.digest, packageScopedId: $0.1), parentConversationId: nil) }
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: "package-\(name)",
            createdAt: sharedAt,
            item: SharedItemIdentity(
                itemType: .podcast, canonicalURL: "https://podcasts.example.com/episodes/harbour-lights",
                title: "Harbour Lights", showTitle: "Example Show", episodeGUID: "harbour-lights",
                enclosureURL: "https://cdn.example.com/audio/harbour-lights.mp3", durationMs: 1_800_000
            ),
            itemTransportSelection: .reference,
            selections: margins.enumerated().map { index, said in
                ReviewedInterjectionSelection(
                    packageScopedId: String(format: "margin-%04d", index + 1),
                    revision: InterjectionShareRevision(
                        id: "revision-\(name)-\(index)", interjectionId: "note-\(sender)-\(said.atMs)", itemId: "sender-item",
                        sessionId: senderSessions[person]!, createdAt: sharedAt,
                        approvedTranscript: said.words, anchorBefore: "", anchorAfter: "", status: .senderApproved
                    ),
                    anchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: said.atMs),
                    representation: .textOnly,
                    replyTo: link
                )
            },
            senderDisplayLabel: sender
        )
        let url = root.appending(path: "\(name).spokenmargins")
        try exportPacket(prepared, to: url)
        return Shared(name: name, contents: try SpokenMarginsPackageArchive.read(from: url, extractingAssetsTo: root.appending(path: "assets-\(name)")))
    }

    private func freshStore() throws -> SQLiteSessionStore {
        try SQLiteSessionStore(path: root.appending(path: "library-\(UUID().uuidString).sqlite").path)
    }

    private func open(_ packet: Shared, in store: SQLiteSessionStore) throws -> ImportedCommentaryImportDisposition {
        try SpokenMarginsPackageImporter.importPackage(packet.contents, itemId: "episode", repository: store)
    }

    private func layers(in store: SQLiteSessionStore) throws -> [ImportedCommentaryLayer] {
        try store.loadImportedCommentaryLayers(itemId: "episode")
    }

    /// The words of every Margin the listener holds, sorted.
    private func heard(in store: SQLiteSessionStore) throws -> [String] {
        try layers(in: store).flatMap { try store.loadImportedCommentaryInterjections(layerId: $0.id) }
            .map(\.approvedTranscript).sorted()
    }
}

private extension ImportedCommentaryImportDisposition {
    var isImported: Bool {
        if case .imported = self { return true }
        return false
    }
}
