import Foundation
@testable import SessionKit
import SessionKitSharing
import XCTest

/// The reveal mode a recipient gets when a packet arrives (PKT-09 of the #1039 audit). The test that names the default
/// in the app (Build23RecipientSharingExperienceTests) builds the layer with `.companion` and asserts it is
/// `.companion`; the real defaulting happens here, on import, and every packet in the suite passed
/// `suggestedRevealMode` explicitly, so the `nil` case was never imported.
final class ImportedLayerRevealModeTests: XCTestCase {
    private let created = Date(timeIntervalSince1970: 1_777_000_000)
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportedLayerRevealModeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func importedLayer(suggesting mode: ImportedCommentaryRevealMode?) throws -> ImportedCommentaryLayer {
        let name = "reveal-\(mode?.rawValue ?? "none")"
        let item = SharedItemIdentity(itemType: .text, canonicalURL: "https://example.com/article", title: "A Useful Article")
        let revision = InterjectionShareRevision(
            id: "revision-1", interjectionId: "private-note", itemId: "private-item", sessionId: "private-session",
            createdAt: created, approvedTranscript: "A sender-reviewed thought.",
            anchorBefore: "Before this passage.", anchorAfter: "After this passage.", status: .senderApproved
        )
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: "package-\(name)", createdAt: created, item: item, itemTransportSelection: .reference,
            selections: [.init(
                packageScopedId: "margin-001", revision: revision,
                anchor: .init(anchorType: .text, exactText: "The durable idea that prompted this note."),
                representation: .textOnly
            )],
            suggestedRevealMode: mode
        )
        let url = root.appendingPathComponent("\(name).spokenmargins")
        try exportPacket(prepared, to: url)
        let verified = try SpokenMarginsPackageArchive.read(from: url, extractingAssetsTo: root.appendingPathComponent("\(name)-assets"))
        XCTAssertEqual(verified.manifest.suggestedRevealMode, mode, "the packet says what the sender chose")
        let repository = InMemorySessionRepository()
        _ = try SpokenMarginsPackageImporter.importPackage(
            verified, itemId: "recipient-item", importedAt: created, repository: repository,
            makeLocalID: { kind, packageID in "recipient-\(kind)-\(packageID)" }
        )
        return try XCTUnwrap(try repository.loadImportedCommentaryLayers(itemId: "recipient-item").first)
    }

    func testAPacketWhoseSenderChoseNoRevealModeArrivesAsCompanion() throws {
        let layer = try importedLayer(suggesting: nil)
        XCTAssertNil(layer.suggestedRevealMode, "no suggestion is kept as no suggestion")
        XCTAssertEqual(layer.revealMode, .companion)
    }

    func testAPacketKeepsTheRevealModeItsSenderSuggested() throws {
        for mode in ImportedCommentaryRevealMode.allCases {
            let layer = try importedLayer(suggesting: mode)
            XCTAssertEqual(layer.suggestedRevealMode, mode, "\(mode)")
            XCTAssertEqual(layer.revealMode, mode, "a \(mode) suggestion is the mode the recipient gets")
        }
    }
}
