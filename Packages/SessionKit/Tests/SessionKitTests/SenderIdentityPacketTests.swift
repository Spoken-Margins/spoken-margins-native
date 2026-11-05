import Foundation
@testable import SessionKit
import SessionKitSharing
import ShippedPacketReader
import XCTest
import SessionKitTestInputs

/// The sender's random id travels in an optional packet artifact (#2846, #1729 item 14). Packets without one must stay
/// exactly what Builds 32 and 34 write, and packets with one must open in them.
final class SenderIdentityPacketTests: XCTestCase {
    private let created = Date(timeIntervalSince1970: 1_777_000_000)
    private let senderA = "0123456789abcdef0123456789abcdef"
    private let senderB = "fedcba9876543210fedcba9876543210"
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SenderIdentityPacketTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func prepare(_ name: String, senderID: String?) throws -> PreparedSpokenMarginsPackage {
        let revision = InterjectionShareRevision(
            id: "revision-1", interjectionId: "private-note", itemId: "private-item",
            // A real session id gives each Margin a share token, which is how a re-share is recognised.
            sessionId: "session-11111111-1111-1111-1111-111111111111",
            createdAt: created, approvedTranscript: "A sender-reviewed thought.",
            anchorBefore: "Before this passage.", anchorAfter: "After this passage.", status: .senderApproved
        )
        return try SpokenMarginsPackageBuilder.prepare(
            packageId: "package-\(name)", createdAt: created,
            item: SharedItemIdentity(itemType: .text, canonicalURL: "https://example.com/article", title: "A Useful Article"),
            itemTransportSelection: .reference,
            selections: [.init(
                packageScopedId: "margin-001", revision: revision,
                anchor: .init(anchorType: .text, exactText: "The durable idea that prompted this note."),
                representation: .textOnly
            )],
            senderDisplayLabel: "A Friend", senderID: senderID
        )
    }

    private func read(_ name: String, senderID: String?) throws -> (VerifiedSpokenMarginsPackage, URL) {
        let url = root.appendingPathComponent("\(name).spokenmargins")
        try exportPacket(try prepare(name, senderID: senderID), to: url) // the shipped reader opens it too
        return (try SpokenMarginsPackageArchive.read(from: url, extractingAssetsTo: root.appendingPathComponent("\(name)-assets")), url)
    }

    private func importLayer(_ verified: VerifiedSpokenMarginsPackage, into repository: InMemorySessionRepository, itemId: String) throws -> ImportedCommentaryLayer {
        _ = try SpokenMarginsPackageImporter.importPackage(
            verified, itemId: itemId, importedAt: created, repository: repository,
            makeLocalID: { kind, packageID in "\(itemId)-\(kind)-\(packageID)" }
        )
        return try XCTUnwrap(try repository.loadImportedCommentaryLayers(itemId: itemId).first)
    }

    func testAPacketWithoutASenderIdHasNoSenderArtifact() throws {
        let (verified, _) = try read("none", senderID: nil)
        XCTAssertFalse(verified.manifest.artifacts.contains { $0.kind == SpokenMarginsArtifactKind.senderIdentity })
        XCTAssertTrue(verified.senderIdentities.isEmpty)
    }

    func testAPacketCarriesTheSenderIdAsAnOptionalArtifactTheShippedReaderSkips() throws {
        let (verified, _) = try read("with", senderID: senderA) // exportPacket already ran the shipped reader on it
        let descriptor = try XCTUnwrap(verified.manifest.artifacts.first { $0.kind == SpokenMarginsArtifactKind.senderIdentity })
        XCTAssertFalse(descriptor.required, "a required artifact would lock Builds 32 and 34 out")
        XCTAssertEqual(verified.manifest.requiredCapabilities, [SharedCommentaryLayerArtifact.schemaVersion],
                       "no new required capability")
        XCTAssertEqual(verified.senderIdentities.map(\.senderId), [senderA])
    }

    func testABadSenderIdIsLeftOutWhenWritingSoThePacketStaysPlain() throws {
        for bad in ["", "short", String(repeating: "a", count: 65), "has space has space has space", "ünïcödé-ünïcödé-ünïcödé"] {
            let (verified, _) = try read("bad-\(abs(bad.hashValue))", senderID: bad)
            XCTAssertTrue(verified.senderIdentities.isEmpty, "\(bad) must not be written")
        }
    }

    func testTheImportedLayerKeepsTheSenderId() throws {
        let (verified, _) = try read("keep", senderID: senderA)
        let layer = try importLayer(verified, into: InMemorySessionRepository(), itemId: "item-1")
        XCTAssertEqual(layer.senderId, senderA)
        let (plain, _) = try read("plain", senderID: nil)
        XCTAssertNil(try importLayer(plain, into: InMemorySessionRepository(), itemId: "item-1").senderId)
    }

    func testAnArtifactWithAnExtraFieldIsRefusedLikeEveryOtherArtifactShape() throws {
        let url = root.appendingPathComponent("extra.spokenmargins")
        var prepared = try prepare("extra", senderID: senderA)
        let path = "artifacts/sender-identity.json"
        prepared.rewrite(path) { #"{"id":"sender-identity","schemaVersion":"spoken-margins.sender-identity.v1","senderId":"\#(senderA)","name":"Dana"}"# }
        XCTAssertThrowsError(try SpokenMarginsPackageArchive.write(prepared, to: url))
    }

    func testTwoSenderArtifactsAreRefused() throws {
        var prepared = try prepare("two", senderID: senderA)
        var manifest = prepared.manifest
        let extra = SpokenMarginsArtifactDescriptor(
            id: "sender-identity-2", kind: SpokenMarginsArtifactKind.senderIdentity,
            schemaVersion: SenderIdentityArtifact.schemaVersion, path: "artifacts/sender-identity-2.json", required: false)
        manifest.artifacts.append(extra)
        var data = prepared.artifactData
        data[extra.path] = Data(#"{"id":"sender-identity-2","schemaVersion":"spoken-margins.sender-identity.v1","senderId":"\#(senderB)"}"#.utf8)
        prepared = PreparedSpokenMarginsPackage(manifest: manifest, artifactData: data, assetFiles: prepared.assetFiles)
        XCTAssertThrowsError(try SpokenMarginsPackageArchive.write(prepared, to: root.appendingPathComponent("two.spokenmargins")))
    }

    /// A friend on an older build shared without an id; after they upgrade, their re-share names one (#2846).
    func testASenderWhoStartsSendingAnIdCanBeHiddenForMarginsTheyShareAgain() throws {
        let repository = InMemorySessionRepository()
        let (older, _) = try read("older", senderID: nil)
        let (newer, _) = try read("newer", senderID: senderA) // the same Margin again, in a new packet
        let oldLayer = try importLayer(older, into: repository, itemId: "item-1")
        XCTAssertNil(oldLayer.senderId)

        let disposition = try SpokenMarginsPackageImporter.importPackage(
            newer, itemId: "item-1", importedAt: created, repository: repository,
            makeLocalID: { kind, packageID in "item-1-second-\(kind)-\(packageID)" }
        )
        guard case .duplicate = disposition else { return XCTFail("the repeated Margin is held once, got \(disposition)") }
        let layers = try repository.loadImportedCommentaryLayers(itemId: "item-1")
        XCTAssertEqual(layers.map(\.senderId), [senderA], "the older layer learned who it is from, so hiding reaches its Margin")
        var hidden = HiddenSenders()
        hidden.hide(senderA)
        XCTAssertTrue(hidden.visible(layers).isEmpty)
    }

    func testAResendNeverChangesAnIdAlreadyKept() throws {
        let repository = InMemorySessionRepository()
        let (first, _) = try read("kept-a", senderID: senderA)
        let (second, _) = try read("kept-b", senderID: senderB)
        _ = try importLayer(first, into: repository, itemId: "item-1")
        _ = try SpokenMarginsPackageImporter.importPackage(
            second, itemId: "item-1", importedAt: created, repository: repository,
            makeLocalID: { kind, packageID in "item-1-second-\(kind)-\(packageID)" }
        )
        XCTAssertEqual(try repository.loadImportedCommentaryLayers(itemId: "item-1").map(\.senderId), [senderA])
    }

    // MARK: hiding

    func testHidingASenderHidesTheirMarginsAcrossTwoImportsAndUndoRestoresThem() throws {
        let repository = InMemorySessionRepository()
        let (first, _) = try read("first", senderID: senderA)
        let (second, _) = try read("second", senderID: senderB)
        let layerA = try importLayer(first, into: repository, itemId: "item-1")
        let layerB = try importLayer(second, into: repository, itemId: "item-2")
        var hidden = HiddenSenders()
        XCTAssertEqual(hidden.visible([layerA, layerB]).map(\.id), [layerA.id, layerB.id])

        XCTAssertTrue(hidden.hide(layerA.senderId, displayLabel: layerA.displayLabel, at: created))
        XCTAssertEqual(hidden.visible([layerA, layerB]).map(\.id), [layerB.id], "only the hidden sender's layer goes")

        // A later import from the same sender, on another item, is hidden too.
        let (later, _) = try read("later", senderID: senderA)
        let laterLayer = try importLayer(later, into: repository, itemId: "item-3")
        XCTAssertEqual(hidden.visible([layerA, layerB, laterLayer]).map(\.id), [layerB.id])
        XCTAssertEqual(hidden.listed.map(\.displayLabel), ["A Friend"])

        hidden.unhide(senderA)
        XCTAssertEqual(hidden.visible([layerA, layerB, laterLayer]).map(\.id), [layerA.id, layerB.id, laterLayer.id])
        XCTAssertTrue(hidden.listed.isEmpty)
    }

    func testALayerWithNoSenderIdIsNeverHiddenAndCannotBeHiddenBySender() throws {
        let (plain, _) = try read("nosender", senderID: nil)
        let layer = try importLayer(plain, into: InMemorySessionRepository(), itemId: "item-1")
        var hidden = HiddenSenders()
        XCTAssertFalse(hidden.hide(layer.senderId), "nothing to hide by")
        XCTAssertFalse(hidden.hide("not a sender id"))
        XCTAssertEqual(hidden.visible([layer]).map(\.id), [layer.id])
    }




}

private extension PreparedSpokenMarginsPackage {
    /// Replaces one artifact's bytes (the descriptor's size and digest are filled in again on write).
    mutating func rewrite(_ path: String, _ json: () -> String) {
        var data = artifactData
        data[path] = Data(json().utf8)
        self = PreparedSpokenMarginsPackage(manifest: manifest, artifactData: data, assetFiles: assetFiles)
    }
}
