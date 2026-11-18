import Foundation
@testable import SessionKit
import SessionKitPersistence
import SessionKitSharing
import ShippedPacketReader
import SQLite3
import XCTest
import SessionKitTestInputs

/// The packet side of "a sender picks how much of the episode a friend hears before a Margin" (#4171; the rule itself is
/// `SenderLeadInTests`, which also runs on Linux). The length rides on the Margin's record as an optional `leadInMs`,
/// written only when it isn't the 20 s default or an earlier share used another length. Packets from before the setting
/// import with no length, and packets with it open in the shipped builds: `exportPacket` reads each one with the frozen
/// Build 29 reader.
final class LeadInPacketTests: XCTestCase {
    private let created = Date(timeIntervalSince1970: 1_777_000_000)
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeadInPacketTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func prepare(
        _ name: String, leadInMs: Int?, previousLeadInMs: Int? = nil,
        representation: ReviewedRepresentationSelection = .textOnly
    ) throws -> PreparedSpokenMarginsPackage {
        let revision = InterjectionShareRevision(
            id: "revision-1", interjectionId: "note", itemId: "private-item",
            sessionId: "session-11111111-1111-1111-1111-111111111111",
            createdAt: created, approvedTranscript: "A sender-reviewed thought.",
            anchorBefore: "Before this passage.", anchorAfter: "After this passage.", status: .senderApproved
        )
        let anchor = PortableAnchorEvidence(anchorType: .text, exactText: "The durable idea that prompted this note.")
        let selection = ReviewedInterjectionSelection(
            packageScopedId: "margin-001", revision: revision, anchor: anchor, representation: representation,
            leadInMs: leadInMs, previousLeadInMs: previousLeadInMs)
        return try SpokenMarginsPackageBuilder.prepare(
            packageId: "package-\(name)", createdAt: created,
            item: SharedItemIdentity(itemType: .text, canonicalURL: "https://example.com/article", title: "A Useful Article"),
            itemTransportSelection: .reference, selections: [selection], senderDisplayLabel: "A Friend"
        )
    }

    /// The Margin's record as it is written in the packet's commentary layer.
    private func recordJSON(_ package: PreparedSpokenMarginsPackage) throws -> [String: Any] {
        let data = try XCTUnwrap(package.artifactData["artifacts/commentary-layer.json"])
        let layer = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap((layer["interjections"] as? [[String: Any]])?.first)
    }

    private func importMargin(_ name: String, leadInMs: Int?, previousLeadInMs: Int? = nil, into repository: some SessionRepository) throws -> (ImportedCommentaryLayer, ImportedCommentaryInterjection) {
        let url = root.appendingPathComponent("\(name).spokenmargins")
        try exportPacket(try prepare(name, leadInMs: leadInMs, previousLeadInMs: previousLeadInMs), to: url) // Build 29's reader opens it too
        let verified = try SpokenMarginsPackageArchive.read(from: url, extractingAssetsTo: root.appendingPathComponent("\(name)-assets"))
        _ = try SpokenMarginsPackageImporter.importPackage(
            verified, itemId: "item", importedAt: created, repository: repository,
            makeLocalID: { kind, packageID in "\(name)-\(kind)-\(packageID)" }
        )
        let layer = try XCTUnwrap(try repository.loadImportedCommentaryLayers(itemId: "item").first { $0.packageId == "package-\(name)" })
        return (layer, try XCTUnwrap(try repository.loadImportedCommentaryInterjections(layerId: layer.id).first))
    }

    func testTheDefaultWritesNoKeyAndAnotherLengthWritesOne() throws {
        XCTAssertNil(try recordJSON(prepare("default", leadInMs: nil))["leadInMs"], "the packet an older build makes is unchanged")
        XCTAssertNil(try recordJSON(prepare("twenty", leadInMs: 20_000))["leadInMs"], "20 s is the default and travels as nothing")
        XCTAssertEqual(try recordJSON(prepare("minute", leadInMs: 60_000))["leadInMs"] as? Int, 60_000)
        XCTAssertEqual(try recordJSON(prepare("short", leadInMs: 5_000))["leadInMs"] as? Int, 5_000)
    }

    /// The sender takes a length back: the packet says 20 s out loud, because a missing key can't tell the friend's held
    /// copy to return to the default. After a share that also said 20 s, or never carried a length, it writes nothing.
    func testTakingTheLengthBackIsSaidOutLoud() throws {
        XCTAssertEqual(try recordJSON(prepare("back", leadInMs: 20_000, previousLeadInMs: 60_000))["leadInMs"] as? Int, 20_000)
        XCTAssertNil(try recordJSON(prepare("still-default", leadInMs: 20_000, previousLeadInMs: 20_000))["leadInMs"])
        XCTAssertEqual(try recordJSON(prepare("changed", leadInMs: 120_000, previousLeadInMs: 60_000))["leadInMs"] as? Int, 120_000)
    }

    func testARecordingCarriesTheLengthToo() throws {
        let url = root.appendingPathComponent("voice.m4a")
        try Data(repeating: 1, count: 16).write(to: url)
        let package = try prepare("voice", leadInMs: 60_000, representation: .originalAudio(sourceURL: url, durationMs: 4_000))
        XCTAssertEqual(try recordJSON(package)["leadInMs"] as? Int, 60_000, "every kind of Margin has a run-up")
    }

    func testTheLengthIsNeverARequiredCapability() throws {
        XCTAssertEqual(try prepare("long", leadInMs: 120_000).manifest.requiredCapabilities,
                       try prepare("plain", leadInMs: nil).manifest.requiredCapabilities)
    }

    func testAPacketFromBeforeTheSettingImportsWithNoLength() throws {
        let (_, margin) = try importMargin("old", leadInMs: nil, into: InMemorySessionRepository())
        XCTAssertNil(margin.senderLeadInMs)
    }

    func testTheLengthArrivesWithTheMargin() throws {
        let (_, margin) = try importMargin("minute-import", leadInMs: 60_000, into: InMemorySessionRepository())
        XCTAssertEqual(margin.senderLeadInMs, 60_000)
        let (_, back) = try importMargin("back-import", leadInMs: 20_000, previousLeadInMs: 60_000, into: InMemorySessionRepository())
        XCTAssertEqual(back.senderLeadInMs, 20_000)
    }

    /// The writer never puts a length in a packet that a reader would have to clamp (the reader's own clamp is
    /// `SenderLeadInTests.testAnImportedMarginClampsWhatThePacketAsked`).
    func testTheWriterStaysWithinWhatAReaderAccepts() throws {
        XCTAssertEqual(try recordJSON(prepare("too-long", leadInMs: 9_000_000))["leadInMs"] as? Int, 300_000)
        let (_, zero) = try importMargin("zero", leadInMs: 0, into: InMemorySessionRepository())
        XCTAssertEqual(zero.senderLeadInMs, 0, "0 is a length, not an absent one")
    }

    func testTheLibraryKeepsTheLengthAndBuild29StillOpensTheRow() throws {
        let path = root.appendingPathComponent("library.sqlite").path
        let store = try SQLiteSessionStore(path: path)
        let (layer, imported) = try importMargin("stored", leadInMs: 60_000, into: store)
        try store.saveImportedCommentaryInterjection(imported)
        let stored = try XCTUnwrap(try store.loadImportedCommentaryInterjections(layerId: layer.id).first)
        XCTAssertEqual(stored.senderLeadInMs, 60_000)

        // The row as the previous build reads it from the same database: it ignores the new key.
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT payload FROM records WHERE kind = 'imported_commentary_interjection';", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        let payload = Data(String(cString: sqlite3_column_text(statement, 0)!).utf8)
        XCTAssertTrue(String(decoding: payload, as: UTF8.self).contains("senderLeadInMs"), "the new key is in the stored row")
        XCTAssertNoThrow(try ShippedPacketReader.decodeStoredRecord(kind: "imported_commentary_interjection", payload: payload))
        XCTAssertEqual(try store.quarantinedRecordCount(), 0)
    }
}
