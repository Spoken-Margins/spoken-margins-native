import Foundation
@testable import SessionKit
import SessionKitPersistence
import SessionKitSharing
import ShippedPacketReader
import SQLite3
import XCTest
import ZIPFoundation

/// A reply's link to its parent Margin travels in packets that Build 29 still opens (#472).
final class MarginReplyPacketTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MarginReplyPacketTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Done when 2: only a packet with a reply changes

    func testAPacketWithoutRepliesIsByteForByteWhatBuild29Writes() throws {
        let shippedURL = root.appendingPathComponent("build29.spokenmargins")
        try ShippedPacketReader.writeTextPacket(
            to: shippedURL, packageId: "package-a", createdAt: fixedDate, title: "A Useful Article",
            canonicalURL: "https://example.com/article", senderDisplayLabel: "A",
            margins: [.init(packageScopedId: "margin-001", transcript: "First thought.", exactText: "durable idea")]
        )
        let alice = try Listener(name: "A", root: root)
        let margin = try alice.write("First thought.", id: "margin-001")
        let (currentURL, _) = try alice.share([margin], packageId: "package-a", scopedIds: ["margin-001"], in: root)

        let shipped = try readRawArchive(shippedURL)
        let current = try readRawArchive(currentURL)
        XCTAssertEqual(Array(current.keys).sorted(), Array(shipped.keys).sorted())
        XCTAssertEqual(current["manifest.json"], shipped["manifest.json"], "manifest changed for a packet with no replies")
        XCTAssertEqual(current, shipped)
        XCTAssertFalse(String(decoding: try XCTUnwrap(current["manifest.json"]), as: UTF8.self).contains("conversation"))
    }

    func testAReplyGoesInAnOptionalConversationArtifactWithNoNewCapability() throws {
        let (alice, bob) = (try Listener(name: "A", root: root), try Listener(name: "B", root: root))
        let (aliceURL, _) = try alice.share([try alice.write("Root thought.", id: "a-1")], packageId: "package-a", scopedIds: ["a-1"], in: root)
        try bob.importPacket(aliceURL)
        let reply = try bob.reply(to: "a-1", "I disagree.", id: "b-1")
        let (_, manifest) = try bob.share([reply], packageId: "package-b", scopedIds: ["b-1"], in: root)

        XCTAssertEqual(manifest.requiredCapabilities, [SharedCommentaryLayerArtifact.schemaVersion])
        let descriptor = try XCTUnwrap(manifest.artifacts.first { $0.kind == SpokenMarginsArtifactKind.conversation })
        XCTAssertFalse(descriptor.required)
        XCTAssertEqual(descriptor.schemaVersion, MarginConversationArtifact.schemaVersion)
        XCTAssertEqual(manifest.artifacts.map(\.kind), [SpokenMarginsArtifactKind.commentaryLayer, SpokenMarginsArtifactKind.conversation])
    }

    // MARK: Done when 3: Build 29 hears a reply as an ordinary Margin

    func testBuild29ImportsAPacketWithAReplyAndTheReplyIsAnOrdinaryMargin() throws {
        let (alice, bob) = (try Listener(name: "A", root: root), try Listener(name: "B", root: root))
        let (aliceURL, _) = try alice.share([try alice.write("Root thought.", id: "a-1")], packageId: "package-a", scopedIds: ["a-1"], in: root)
        try bob.importPacket(aliceURL)
        let reply = try bob.reply(to: "a-1", "I disagree.", id: "b-1")
        let plain = try bob.write("Unrelated note.", id: "b-2")
        let (bobURL, _) = try bob.share([reply, plain], packageId: "package-b", scopedIds: ["b-1", "b-2"], in: root)

        XCTAssertEqual(try ShippedPacketReader.importedMargins(at: bobURL).sorted { $0.packageScopedId < $1.packageScopedId }, [
            .init(packageScopedId: "b-1", approvedTranscript: "I disagree."),
            .init(packageScopedId: "b-2", approvedTranscript: "Unrelated note."),
        ])
    }

    // MARK: Done when 1: Build 29 decodes the records this build saves

    func testBuild29DecodesSavedMarginsThatCarryReplyLinks() throws {
        let (alice, bob) = (try Listener(name: "A", root: root), try Listener(name: "B", root: root))
        let (aliceURL, _) = try alice.share([try alice.write("Root thought.", id: "a-1")], packageId: "package-a", scopedIds: ["a-1"], in: root)
        try bob.importPacket(aliceURL)
        let reply = try bob.reply(to: "a-1", "I disagree.", id: "b-1")
        let (bobURL, _) = try bob.share([reply], packageId: "package-b", scopedIds: ["b-1"], in: root)
        let carol = try Listener(name: "C", root: root)
        try carol.importPacket(bobURL)

        let savedReply = try XCTUnwrap(try bob.store.loadInterjections(sessionId: bob.sessionId).first { $0.id == "b-1" })
        XCTAssertNotNil(savedReply.replyTo)
        XCTAssertEqual(savedReply.sharedAs?.count, 1)
        let arrived = try XCTUnwrap(try carol.importedMargins().first)
        XCTAssertEqual(arrived.replyLinks, [savedReply.replyTo!])

        let bobPayload = try storedPayload(bob.databasePath, kind: "interjection", idSuffix: "b-1")
        XCTAssertTrue(String(decoding: bobPayload, as: UTF8.self).contains("replyTo"))
        XCTAssertEqual(try ShippedPacketReader.decodeStoredRecord(kind: "interjection", payload: bobPayload), "b-1")
        let carolPayload = try storedPayload(carol.databasePath, kind: "imported_commentary_interjection", idSuffix: arrived.id)
        XCTAssertTrue(String(decoding: carolPayload, as: UTF8.self).contains("replyLinks"))
        XCTAssertEqual(try ShippedPacketReader.decodeStoredRecord(kind: "imported_commentary_interjection", payload: carolPayload), arrived.id)
        XCTAssertEqual(try carol.store.quarantinedRecordCount(), 0)
    }

    // MARK: Done when 4: links, and the states that aren't errors

    func testAReplyWhoseParentHasNotArrivedIsMissingThenLinks() throws {
        let (alice, bob, carol) = (try Listener(name: "A", root: root), try Listener(name: "B", root: root), try Listener(name: "C", root: root))
        let (aliceURL, _) = try alice.share([try alice.write("Root thought.", id: "a-1")], packageId: "package-a", scopedIds: ["a-1"], in: root)
        try bob.importPacket(aliceURL)
        let (bobURL, _) = try bob.share([try bob.reply(to: "a-1", "I disagree.", id: "b-1")], packageId: "package-b", scopedIds: ["b-1"], in: root)

        try carol.importPacket(bobURL)
        let reply = try XCTUnwrap(try carol.importedMargins().first)
        guard case .parentMissing(let link) = try carol.graph().states[.imported(reply.id)] else {
            return XCTFail("expected a missing parent, got \(String(describing: try carol.graph().states[.imported(reply.id)]))")
        }
        XCTAssertEqual(link.parentPackageScopedId, "a-1")
        XCTAssertTrue(try carol.graph().threads.isEmpty)

        try carol.importPacket(aliceURL)
        let parent = try XCTUnwrap(try carol.importedMargins().first { $0.packageScopedId == "a-1" })
        XCTAssertEqual(try carol.graph().states[.imported(reply.id)], .linked(.init(link: link, parent: .imported(parent.id))))
    }

    func testImportingTheSamePacketTwiceIsADuplicateAndLeavesTheThreadsAlone() throws {
        let (alice, bob) = (try Listener(name: "A", root: root), try Listener(name: "B", root: root))
        let (aliceURL, _) = try alice.share([try alice.write("Root thought.", id: "a-1")], packageId: "package-a", scopedIds: ["a-1"], in: root)
        try bob.importPacket(aliceURL)
        let (bobURL, _) = try bob.share([try bob.reply(to: "a-1", "I disagree.", id: "b-1")], packageId: "package-b", scopedIds: ["b-1"], in: root)
        try alice.importPacket(bobURL)
        let before = try alice.graph()

        guard case .duplicate = try alice.importPacket(bobURL) else { return XCTFail("expected a duplicate") }
        XCTAssertEqual(try alice.graph(), before)
        XCTAssertEqual(before.threads.values.map(\.count), [1])
    }

    func testARepeatedLinkCollapsesAndAReplyToTwoParentsIsAFork() throws {
        let (alice, bob, carol) = (try Listener(name: "A", root: root), try Listener(name: "B", root: root), try Listener(name: "C", root: root))
        let (aliceURL, _) = try alice.share(
            [try alice.write("First.", id: "a-1"), try alice.write("Second.", id: "a-2")],
            packageId: "package-a", scopedIds: ["a-1", "a-2"], in: root
        )
        try bob.importPacket(aliceURL)
        let (repeatedURL, _) = try bob.share(
            [try bob.reply(to: "a-1", "Once.", id: "b-1")], packageId: "package-b", scopedIds: ["b-1"], in: root,
            rewriteReplies: { $0 + $0 }
        )
        let secondParent = try bob.replyLink(to: "a-2")
        let missingParent = MarginReplyLink.replying(
            to: MarginPacketIdentity(packageDigest: String(repeating: "0", count: 64), packageScopedId: "gone"),
            parentConversationId: nil
        )
        let (forkURL, _) = try bob.share(
            [try bob.reply(to: "a-1", "To both.", id: "b-2")], packageId: "package-b-fork", scopedIds: ["b-2"], in: root,
            rewriteReplies: { $0 + [.init(packageScopedId: "b-2", link: secondParent), .init(packageScopedId: "b-2", link: missingParent)] }
        )
        XCTAssertEqual(try ShippedPacketReader.importedMargins(at: forkURL).map(\.packageScopedId), ["b-2"])

        for url in [aliceURL, repeatedURL, forkURL] { try carol.importPacket(url) }
        let imported = try carol.importedMargins()
        let id = { (scoped: String) in try XCTUnwrap(imported.first { $0.packageScopedId == scoped }).id }
        let graph = try carol.graph()
        guard case .linked(let once) = graph.states[.imported(try id("b-1"))] else { return XCTFail("repeated link did not collapse") }
        XCTAssertEqual(once.parent, .imported(try id("a-1")))
        guard case .fork(let parents) = graph.states[.imported(try id("b-2"))] else { return XCTFail("expected a fork") }
        XCTAssertEqual(parents.map(\.parent), [.imported(try id("a-1")), .imported(try id("a-2")), nil])
        XCTAssertEqual(parents.last?.link, missingParent)
    }

    func testTheArchiveRejectsAReplyLinkThatNamesNoMarginInThePacket() throws {
        let (alice, bob) = (try Listener(name: "A", root: root), try Listener(name: "B", root: root))
        let (aliceURL, _) = try alice.share([try alice.write("Root.", id: "a-1")], packageId: "package-a", scopedIds: ["a-1"], in: root)
        try bob.importPacket(aliceURL)
        let link = try bob.replyLink(to: "a-1")
        XCTAssertThrowsError(try bob.share(
            [try bob.reply(to: "a-1", "Reply.", id: "b-1")], packageId: "package-b", scopedIds: ["b-1"], in: root,
            rewriteReplies: { _ in [.init(packageScopedId: "not-in-packet", link: link)] }
        )) { XCTAssertEqual($0 as? SpokenMarginsPackageArchiveError, .invalidManifest("a reply link is invalid")) }
    }

    // MARK: Done when 5: three listeners, real SQLite, both import orders

    func testThreeListenersEndWithTheSameThreadsInEitherImportOrder() throws {
        for carolImportsBobFirst in [false, true] {
            let run = root.appendingPathComponent(carolImportsBobFirst ? "b-first" : "a-first", isDirectory: true)
            let (alice, bob, carol) = (try Listener(name: "A", root: run), try Listener(name: "B", root: run), try Listener(name: "C", root: run))

            // A shares Margins.
            let (aliceURL, _) = try alice.share(
                [try alice.write("The opening is wrong.", id: "a-1"), try alice.write("Nice line.", id: "a-2")],
                packageId: "package-a", scopedIds: ["a-1", "a-2"], in: run
            )
            // B imports them and replies to one.
            try bob.importPacket(aliceURL)
            let (bobURL, _) = try bob.share(
                [try bob.reply(to: "a-1", "It is right, read on.", id: "b-1")], packageId: "package-b", scopedIds: ["b-1"], in: run
            )
            // C imports both packets, in both orders, and replies to B's reply.
            for url in carolImportsBobFirst ? [bobURL, aliceURL] : [aliceURL, bobURL] { try carol.importPacket(url) }
            let (carolURL, _) = try carol.share(
                [try carol.reply(to: "b-1", "Both of you have a point.", id: "c-1")], packageId: "package-c", scopedIds: ["c-1"], in: run
            )
            // A imports B's and C's packets; B imports C's, so everyone holds every packet.
            for url in [bobURL, carolURL] { try alice.importPacket(url) }
            try bob.importPacket(carolURL)

            let threads = try [alice, bob, carol].map { try $0.graph().threads }
            XCTAssertEqual(threads[0], threads[1], "A and B differ")
            XCTAssertEqual(threads[1], threads[2], "B and C differ")
            let aDigest = try alice.sharedIdentity("a-1").packageDigest
            let bDigest = try bob.sharedIdentity("b-1").packageDigest
            let cDigest = try carol.sharedIdentity("c-1").packageDigest
            let conversation = MarginReplyLink.conversationId(rootedAt: .init(packageDigest: aDigest, packageScopedId: "a-1"))
            XCTAssertEqual(threads[0], [conversation: [
                .init(reply: .init(packageDigest: bDigest, packageScopedId: "b-1"), parent: .init(packageDigest: aDigest, packageScopedId: "a-1")),
                .init(reply: .init(packageDigest: cDigest, packageScopedId: "c-1"), parent: .init(packageDigest: bDigest, packageScopedId: "b-1")),
            ]])

            // A sees B's reply under A's own Margin, and C's under B's.
            let aliceGraph = try alice.graph()
            let bobReply = try XCTUnwrap(try alice.importedMargins().first { $0.packageScopedId == "b-1" })
            let carolReply = try XCTUnwrap(try alice.importedMargins().first { $0.packageScopedId == "c-1" })
            guard case .linked(let toAlice) = aliceGraph.states[.imported(bobReply.id)],
                  case .linked(let toBob) = aliceGraph.states[.imported(carolReply.id)] else {
                return XCTFail("replies not linked for A: \(aliceGraph.states)")
            }
            XCTAssertEqual(toAlice.parent, .local("a-1"))
            XCTAssertEqual(toBob.parent, .imported(bobReply.id))
            for listener in [alice, bob, carol] { XCTAssertEqual(try listener.store.quarantinedRecordCount(), 0) }
        }
    }

    // MARK: Helpers

    private var fixedDate: Date { Date(timeIntervalSince1970: 1_777_000_000) }

    private func readRawArchive(_ url: URL) throws -> [String: Data] {
        let archive = try Archive(url: url, accessMode: .read)
        var result: [String: Data] = [:]
        for entry in archive {
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            result[entry.path] = data
        }
        return result
    }

    /// The payload the store wrote for a record, read straight from the SQLite file.
    private func storedPayload(_ path: String, kind: String, idSuffix: String) throws -> Data {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw SessionKitError.persistenceFailed("open") }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, payload FROM records WHERE kind = ?;", -1, &statement, nil) == SQLITE_OK else {
            throw SessionKitError.persistenceFailed("prepare")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, kind, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        while sqlite3_step(statement) == SQLITE_ROW {
            if String(cString: sqlite3_column_text(statement, 0)!).hasSuffix(idSuffix) {
                return Data(String(cString: sqlite3_column_text(statement, 1)!).utf8)
            }
        }
        throw SessionKitError.persistenceFailed("no \(kind) record \(idSuffix)")
    }
}

/// One listener with their own SQLite Library and a copy of the same article.
private final class Listener {
    let name: String
    let store: SQLiteSessionStore
    let databasePath: String
    let itemId = "article"
    var sessionId: String { "session-\(name)" }
    private let folder: URL
    private var imports = 0
    private let createdAt = Date(timeIntervalSince1970: 1_777_000_000)

    init(name: String, root: URL) throws {
        self.name = name
        folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        databasePath = folder.appendingPathComponent("library.sqlite").path
        store = try SQLiteSessionStore(path: databasePath)
    }

    @discardableResult
    func write(_ text: String, id: String, replyTo: MarginReplyLink? = nil) throws -> Interjection {
        let margin = Interjection(
            id: id, itemId: itemId, sessionId: sessionId, targetType: .item, targetId: itemId,
            createdAt: createdAt, roughPercent: 10,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 12, anchorBefore: "", anchorAfter: ""),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: text,
            cleanedTranscript: nil, displayText: text, status: "active", captureKind: .written, replyTo: replyTo
        )
        try store.saveInterjection(margin)
        return margin
    }

    func reply(to parentScopedId: String, _ text: String, id: String) throws -> Interjection {
        try write(text, id: id, replyTo: try replyLink(to: parentScopedId))
    }

    func replyLink(to parentScopedId: String) throws -> MarginReplyLink {
        for layer in try store.loadImportedCommentaryLayers(itemId: itemId) {
            if let parent = try store.loadImportedCommentaryInterjections(layerId: layer.id)
                .first(where: { $0.packageScopedId == parentScopedId }) {
                return parent.replyLink(in: layer)
            }
        }
        throw SessionKitError.persistenceFailed("\(name) has no imported Margin \(parentScopedId)")
    }

    /// Writes a packet (read back by Build 29, see exportPacket) and records what was shared.
    func share(
        _ margins: [Interjection],
        packageId: String,
        scopedIds: [String],
        in directory: URL,
        rewriteReplies: (([MarginConversationArtifact.Reply]) -> [MarginConversationArtifact.Reply])? = nil
    ) throws -> (URL, SpokenMarginsPackageManifest) {
        let selections = zip(margins, scopedIds).map { margin, scopedId in
            ReviewedInterjectionSelection(
                packageScopedId: scopedId,
                revision: InterjectionShareRevision(
                    id: "revision-\(margin.id)", interjectionId: margin.id, itemId: margin.itemId,
                    sessionId: margin.sessionId, createdAt: createdAt, approvedTranscript: margin.displayText ?? "",
                    anchorBefore: "", anchorAfter: "", status: .senderApproved
                ),
                anchor: PortableAnchorEvidence(anchorType: .text, exactText: "durable idea"),
                representation: .textOnly,
                replyTo: margin.replyTo
            )
        }
        var prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: packageId, createdAt: createdAt,
            item: SharedItemIdentity(itemType: .text, canonicalURL: "https://example.com/article", title: "A Useful Article"),
            itemTransportSelection: .reference, selections: selections,
            senderDisplayLabel: name, suggestedRevealMode: .companion
        )
        if let rewriteReplies {
            let path = "artifacts/margin-conversation.json"
            let original = try JSONDecoder().decode(MarginConversationArtifact.self, from: XCTUnwrap(prepared.artifactData[path]))
            var artifactData = prepared.artifactData
            artifactData[path] = try SpokenMarginsPackageArchive.encodeArtifact(
                MarginConversationArtifact(replies: rewriteReplies(original.replies)))
            prepared = PreparedSpokenMarginsPackage(manifest: prepared.manifest, artifactData: artifactData, assetFiles: prepared.assetFiles)
        }
        let url = directory.appendingPathComponent("\(packageId).spokenmargins")
        let manifest = try exportPacket(prepared, to: url)
        try SpokenMarginsPackageExportRecord.recordExport(manifest: manifest, selections: selections, repository: store)
        return (url, manifest)
    }

    @discardableResult
    func importPacket(_ url: URL) throws -> ImportedCommentaryImportDisposition {
        imports += 1
        let contents = try SpokenMarginsPackageArchive.read(
            from: url, extractingAssetsTo: folder.appendingPathComponent("import-\(imports)", isDirectory: true))
        return try SpokenMarginsPackageImporter.importPackage(contents, itemId: itemId, importedAt: createdAt, repository: store)
    }

    func importedMargins() throws -> [ImportedCommentaryInterjection] {
        try store.loadImportedCommentaryLayers(itemId: itemId).flatMap { try store.loadImportedCommentaryInterjections(layerId: $0.id) }
    }

    func sharedIdentity(_ marginId: String) throws -> MarginPacketIdentity {
        try XCTUnwrap(try store.loadInterjections(sessionId: sessionId).first { $0.id == marginId }?.sharedAs?.first)
    }

    func graph() throws -> MarginReplyGraph {
        MarginReplyGraph.build(
            localMargins: try store.loadInterjections(sessionId: sessionId),
            layers: try store.loadImportedCommentaryLayers(itemId: itemId),
            importedMargins: try importedMargins()
        )
    }
}
