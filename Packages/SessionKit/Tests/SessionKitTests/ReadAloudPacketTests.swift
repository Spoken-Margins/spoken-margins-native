import Foundation
@testable import SessionKit
import SessionKitPersistence
import SessionKitSharing
import ShippedPacketReader
import SQLite3
import XCTest
import SessionKitTestInputs

/// The packet side of "a sender and a listener choose whether a written Margin is read aloud" (owner, 2026-11-05, #3427;
/// the model side is `ReadAloudChoiceTests`, which also runs on Linux). The sender's choice rides on the Margin's record
/// as an optional key written only when it is "no". Packets from before the setting import as read aloud, and packets
/// with it open in the shipped builds: `exportPacket` reads each one with the frozen Build 29 reader.
final class ReadAloudPacketTests: XCTestCase {
    private let created = Date(timeIntervalSince1970: 1_777_000_000)
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadAloudPacketTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func prepare(_ name: String, readAloud: Bool?, turnsBackOn: Bool = false, representation: ReviewedRepresentationSelection = .textOnly) throws -> PreparedSpokenMarginsPackage {
        let revision = InterjectionShareRevision(
            id: "revision-1", interjectionId: "note", itemId: "private-item",
            sessionId: "session-11111111-1111-1111-1111-111111111111",
            createdAt: created, approvedTranscript: "A sender-reviewed thought.",
            anchorBefore: "Before this passage.", anchorAfter: "After this passage.", status: .senderApproved
        )
        let anchor = PortableAnchorEvidence(anchorType: .text, exactText: "The durable idea that prompted this note.")
        let selection = ReviewedInterjectionSelection(
            packageScopedId: "margin-001", revision: revision, anchor: anchor, representation: representation, readAloud: readAloud ?? true, turnsReadAloudBackOn: turnsBackOn)
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

    private func importMargin(_ name: String, readAloud: Bool?, turnsBackOn: Bool = false, into repository: some SessionRepository) throws -> (ImportedCommentaryLayer, ImportedCommentaryInterjection) {
        let url = root.appendingPathComponent("\(name).spokenmargins")
        try exportPacket(try prepare(name, readAloud: readAloud, turnsBackOn: turnsBackOn), to: url) // Build 29's reader opens it too
        let verified = try SpokenMarginsPackageArchive.read(from: url, extractingAssetsTo: root.appendingPathComponent("\(name)-assets"))
        _ = try SpokenMarginsPackageImporter.importPackage(
            verified, itemId: "item", importedAt: created, repository: repository,
            makeLocalID: { kind, packageID in "\(name)-\(kind)-\(packageID)" }
        )
        let layer = try XCTUnwrap(try repository.loadImportedCommentaryLayers(itemId: "item").first { $0.packageId == "package-\(name)" })
        return (layer, try XCTUnwrap(try repository.loadImportedCommentaryInterjections(layerId: layer.id).first))
    }

    func testTheDefaultWritesNoKeyAndTheSenderSayingNoWritesOne() throws {
        XCTAssertNil(try recordJSON(prepare("default", readAloud: nil))["readAloud"], "the packet an older build makes is unchanged")
        XCTAssertNil(try recordJSON(prepare("yes", readAloud: true))["readAloud"], "'yes' is the default and travels as nothing")
        XCTAssertEqual(try recordJSON(prepare("no", readAloud: false))["readAloud"] as? Bool, false)
    }

    /// #3472: when the sender's last share said "no" and this one says "yes", the packet says so, because a missing key
    /// cannot tell a held copy to read aloud again. Build 29's reader opens it, like any packet with the key.
    func testTurningItBackOnIsSaidOutLoudAndStillOpensInBuild29() throws {
        XCTAssertEqual(try recordJSON(prepare("back-on", readAloud: true, turnsBackOn: true))["readAloud"] as? Bool, true)
        XCTAssertEqual(try recordJSON(prepare("still-off", readAloud: false, turnsBackOn: true))["readAloud"] as? Bool, false, "off wins")
        let (_, margin) = try importMargin("back-on-import", readAloud: true, turnsBackOn: true, into: InMemorySessionRepository())
        XCTAssertEqual(margin.senderReadAloud, true)
        XCTAssertTrue(margin.readsAloud)
        XCTAssertEqual(try prepare("back-on-caps", readAloud: true, turnsBackOn: true).manifest.requiredCapabilities,
                       try prepare("plain-caps", readAloud: nil).manifest.requiredCapabilities)
        let url = root.appendingPathComponent("voice-back-on.m4a")
        try Data(repeating: 1, count: 16).write(to: url)
        let voice = try prepare("voice-back-on", readAloud: true, turnsBackOn: true, representation: .originalAudio(sourceURL: url, durationMs: 4_000))
        XCTAssertNil(try recordJSON(voice)["readAloud"], "a recording carries no choice")
    }

    func testAMarginThatGoesAsARecordingNeverCarriesTheChoice() throws {
        let url = root.appendingPathComponent("voice.m4a")
        try Data(repeating: 1, count: 16).write(to: url)
        let package = try prepare("voice", readAloud: false, representation: .originalAudio(sourceURL: url, durationMs: 4_000))
        XCTAssertNil(try recordJSON(package)["readAloud"], "a recording is not read by the voice, so there is nothing to choose")
    }

    func testTheChoiceIsNeverARequiredCapability() throws {
        XCTAssertEqual(try prepare("muted", readAloud: false).manifest.requiredCapabilities,
                       try prepare("plain", readAloud: nil).manifest.requiredCapabilities)
    }

    func testAPacketFromBeforeTheSettingImportsAsReadAloud() throws {
        let (_, margin) = try importMargin("old", readAloud: nil, into: InMemorySessionRepository())
        XCTAssertNil(margin.senderReadAloud)
        XCTAssertTrue(margin.readsAloud)
        XCTAssertTrue(SharedMarginAudio.canOffer(margin))
    }

    func testTheSendersNoArrivesAndNothingIsOfferedOrStoppedAt() throws {
        let (_, margin) = try importMargin("muted", readAloud: false, into: InMemorySessionRepository())
        XCTAssertEqual(margin.senderReadAloud, false)
        XCTAssertFalse(margin.readsAloud)
        XCTAssertFalse(SharedMarginAudio.canOffer(margin))
    }

    func testTheLibraryKeepsTheChoiceAndBuild29StillOpensTheRow() throws {
        let path = root.appendingPathComponent("library.sqlite").path
        let store = try SQLiteSessionStore(path: path)
        let (layer, imported) = try importMargin("stored", readAloud: false, into: store)
        var chosen = imported
        chosen.listenerReadAloud = true
        try store.saveImportedCommentaryInterjection(chosen)
        try store.saveImportedCommentaryInterjection(imported) // a stale copy
        let stored = try XCTUnwrap(try store.loadImportedCommentaryInterjections(layerId: layer.id).first)
        XCTAssertEqual(stored.senderReadAloud, false)
        XCTAssertEqual(stored.listenerReadAloud, true)
        XCTAssertTrue(stored.readsAloud)

        // The row as the previous build reads it from the same database: it ignores both keys.
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT payload FROM records WHERE kind = 'imported_commentary_interjection';", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        let payload = Data(String(cString: sqlite3_column_text(statement, 0)!).utf8)
        let text = String(decoding: payload, as: UTF8.self)
        XCTAssertTrue(text.contains("senderReadAloud") && text.contains("listenerReadAloud"), "the new keys are in the stored row")
        XCTAssertNoThrow(try ShippedPacketReader.decodeStoredRecord(kind: "imported_commentary_interjection", payload: payload))
        XCTAssertEqual(try store.quarantinedRecordCount(), 0)
    }
}
