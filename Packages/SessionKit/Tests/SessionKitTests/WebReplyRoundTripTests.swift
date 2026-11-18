import Foundation
@testable import SessionKit
import SessionKitPersistence
import SessionKitSharing
import SessionKitTestInputs
import XCTest

/// A friend answers on the web listener (#4107, B2). The web writes the reply packet in TypeScript
/// (`Web/src/packet/fixtures.ts`), naming the app packet it answers by `packet:<digest>:<Margin id>`. These tests close
/// the loop from the app's side with the web's real files:
///
/// - `app-parent.spokenmargins` is the packet Ana's app writes (a written Margin `a-1` at 12:34). The web reads it, and
///   `web-reply.spokenmargins` / `web-reply-unnamed.spokenmargins` answer it. The first test fails when the app's
///   writer would now write a different packet, so the web's reply can never name a digest Ana's app no longer writes.
///   Regenerate with `SM_WRITE_FIXTURES=1`, then `node Web/src/packet/fixtures.ts`.
/// - Ana imports the web reply and her review threads it under her own Margin, named from the packet.
/// - A reply from a web friend with no name says "Shared Margin", never "A friend".
final class WebReplyRoundTripTests: XCTestCase {
    private var root: URL!

    /// The episode Ana listens to, as the web fixtures describe it (`Web/src/packet/fixtures.ts`): a podcast episode known
    /// by its GUID, which is how the app matches a friend's packet to its own copy.
    static let episode = SharedItemIdentity(
        itemType: .podcast, title: "Episode 1 (example episode)", showTitle: "Example Show",
        episodeGUID: "example-episode-guid-1", durationMs: 1_800_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebReplyRoundTripTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func fixtureFolder() throws -> URL {
        try TestInputs.url(.contracts, "fixtures/web-packets")
    }

    /// Ana's packet: a written Margin `a-1` at 12:34, sent with a fixed id and creation date, so the same call always
    /// writes the same content digest.
    private func writeAnasPacket(_ ana: Person) throws -> (URL, SpokenMarginsPackageManifest) {
        let first = try ana.record("a-1", madeAt: 10, atMs: 754_000, written: true)
        return try ana.send([first], packageId: "package-app-parent", in: root)
    }

    func testAppParentFixtureIsCurrent() throws {
        let ana = try Person(name: "Ana", root: root, episode: Self.episode)
        let (written, manifest) = try writeAnasPacket(ana)
        let committed = try fixtureFolder().appendingPathComponent("app-parent.spokenmargins")

        if ProcessInfo.processInfo.environment["SM_WRITE_FIXTURES"] == "1" {
            try? FileManager.default.removeItem(at: committed)
            try FileManager.default.copyItem(at: written, to: committed)
        }
        let fixture = try SpokenMarginsPackageArchive.read(
            from: committed, extractingAssetsTo: root.appendingPathComponent("committed"))
        XCTAssertEqual(
            fixture.manifest.contentDigest, manifest.contentDigest,
            "the app now writes a different packet: run with SM_WRITE_FIXTURES=1, then node Web/src/packet/fixtures.ts")
        XCTAssertEqual(fixture.manifest.senderDisplayLabel, "Ana")
        XCTAssertEqual(fixture.commentaryLayers.flatMap(\.interjections).map(\.packageScopedId), ["a-1"])
    }

    func testWebReplyThreadsUnderAnasMargin() throws {
        let ana = try Person(name: "Ana", root: root, episode: Self.episode)
        _ = try writeAnasPacket(ana)

        let reply = try fixtureFolder().appendingPathComponent("web-reply.spokenmargins")
        guard case .imported = try ana.importPacket(reply, at: 300) else { return XCTFail("Ana should import the web reply") }

        let layers = try ana.store.loadImportedCommentaryLayers(itemId: ana.itemId)
        XCTAssertEqual(layers.map(\.displayLabel), ["Web fixture"])
        let own = try ana.margins()
        let entries = try SharedMarginReview.entries(itemId: ana.itemId, in: ana.store, ownMargins: own)
        XCTAssertEqual(entries.count, 2, "one written reply and one voice reply")
        for entry in entries {
            guard case .yours(let parentId, let parentMs)? = entry.replyContext?.parent else {
                return XCTFail("\(entry.interjection.packageScopedId) does not answer Ana's Margin: \(String(describing: entry.replyContext))")
            }
            XCTAssertEqual(parentId, "a-1")
            XCTAssertEqual(parentMs, 754_000)
            XCTAssertEqual(entry.replyContext?.caption, "Reply to your Margin at 12:34")
        }

        let graph = MarginReplyGraph.build(localMargins: own, layers: layers, importedMargins: try ana.importedMargins())
        for margin in try ana.importedMargins() {
            guard case .linked(let link)? = graph.states[.imported(margin.id)] else {
                return XCTFail("\(margin.packageScopedId) should link to its parent: \(String(describing: graph.states))")
            }
            XCTAssertEqual(link.parent, .local("a-1"))
        }
        XCTAssertEqual(try ana.store.quarantinedRecordCount(), 0)
    }

    func testUnnamedWebReplyCardSaysSharedMargin() throws {
        let ana = try Person(name: "Ana", root: root, episode: Self.episode)
        _ = try writeAnasPacket(ana)

        let reply = try fixtureFolder().appendingPathComponent("web-reply-unnamed.spokenmargins")
        guard case .imported = try ana.importPacket(reply, at: 300) else { return XCTFail("Ana should import the unnamed reply") }

        let layer = try XCTUnwrap(try ana.store.loadImportedCommentaryLayers(itemId: ana.itemId).first)
        XCTAssertTrue((layer.displayLabel ?? "").trimmingCharacters(in: .whitespaces).isEmpty, "the web file carries no sender name")
        let subject = PinnedMarginCard.Subject.friend(layer.displayLabel)
        XCTAssertNil(subject.name)
        XCTAssertEqual(subject.title, "Shared Margin", "never \"A friend\", which would be a name")
        // It still threads under Ana's Margin: the name is separate from the link.
        let entries = try SharedMarginReview.entries(itemId: ana.itemId, in: ana.store, ownMargins: try ana.margins())
        XCTAssertEqual(entries.compactMap { $0.replyContext?.caption }, ["Reply to your Margin at 12:34", "Reply to your Margin at 12:34"])
    }
}
