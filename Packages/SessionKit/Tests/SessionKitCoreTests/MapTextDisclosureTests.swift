import Foundation
import SessionKit
import XCTest

/// Model-written Listening Map text leaves the device only for a source marked public (#3449).
final class MapTextDisclosureTests: XCTestCase {
    private let address = "https://example.com/posts/harbour-lights"
    private let checkedAt = Date()

    // MARK: Which sources can have the mark

    func testOnlyAMarkedWebSourceAllowsModelText() {
        XCTAssertTrue(MapTextDisclosure.allowsModelText(of: item(marked: address)))
        XCTAssertFalse(MapTextDisclosure.allowsModelText(of: item(marked: nil)), "no mark, no model text")
        XCTAssertFalse(MapTextDisclosure.allowsModelText(of: item(marked: "https://example.com/posts/another")), "a mark names the address it checked")
    }

    func testTheRowsThatCanNeverEarnTheMark() {
        let rows: [(String, Item)] = [
            ("http", item(reference: "http://example.com/post", marked: "http://example.com/post")),
            ("a secret in the query", item(reference: address + "?token=abc123def456", marked: address + "?token=abc123def456")),
            ("a secret in the path", item(reference: "https://example.com/u/0123456789abcdef0123456789abcdef/feed", marked: "https://example.com/u/0123456789abcdef0123456789abcdef/feed")),
            ("userinfo", item(reference: "https://me:pw@example.com/post", marked: "https://me:pw@example.com/post")),
            ("a paid-feed host", item(reference: "https://www.patreon.com/rss/show", marked: "https://www.patreon.com/rss/show")),
            ("no address", item(reference: nil, type: "url", marked: address)),
            ("a file from Files", item(reference: "file:///private/var/Doc.pdf", type: "file", marked: "file:///private/var/Doc.pdf")),
            ("a file with a web address", item(reference: address, type: "file", marked: address)),
            ("an EPUB", item(reference: address, type: "epub", marked: address)),
            ("an audiobook", item(reference: address, type: "audiobook", marked: address)),
            ("pasted text", item(reference: address, type: "manual", marked: address)),
            ("no source type", item(reference: address, type: nil, marked: address)),
        ]
        for (name, row) in rows {
            XCTAssertNil(MapTextDisclosure.checkableAddress(of: row), name)
            XCTAssertFalse(MapTextDisclosure.allowsModelText(of: row), name)
        }
    }

    func testAnAddressTheListenerMovedLosesItsMark() {
        var moved = item(marked: address)
        moved.externalReference = "https://example.com/posts/renamed"
        XCTAssertFalse(MapTextDisclosure.allowsModelText(of: moved))
    }

    // MARK: What stays on the phone

    func testWithoutTheMarkModelWordsBecomeBareSceneStarts() throws {
        let stripped = MapTextDisclosure.proposal(proposal(), for: item(marked: nil))
        XCTAssertEqual(stripped.scenes.count, 4, "every scene start still travels")
        let model = stripped.scenes[0]
        XCTAssertNil(model.title)
        XCTAssertNil(model.summaryText)
        XCTAssertNil(model.summaryProvenance)
        XCTAssertNil(model.eligibilityReason)
        XCTAssertEqual(model.eligibility, .unknown)
        XCTAssertEqual(stripped.scenes[1], proposal().scenes[1], "the publisher's own words stay")
        XCTAssertEqual(stripped.scenes[2], proposal().scenes[2], "the sender's own words stay")
        XCTAssertEqual(stripped.scenes[3], proposal().scenes[3], "a deterministic label stays")
        XCTAssertEqual(stripped.scenes[0].startAnchor.mediaTimeMs, 0, "the place stays")
        XCTAssertNil(stripped.scenes[0].startAnchor.chapterTitle, "the map builder copies the model's label into the anchors")
        XCTAssertNil(stripped.scenes[0].endAnchor.chapterTitle)
        XCTAssertEqual(stripped.scenes[1].startAnchor.chapterTitle, "Publisher title", "a publisher scene keeps its chapter title")
        let json = String(decoding: try JSONEncoder().encode(stripped), as: UTF8.self)
        XCTAssertFalse(json.contains("Model title") || json.contains("Model summary") || json.contains("Model reason"), "nowhere in the whole map: \(json)")
    }

    func testAStrippedMapStillPassesThePacketRules() {
        let stripped = MapTextDisclosure.proposal(proposal(), for: item(marked: nil))
        XCTAssertEqual(PortableListeningMapContract.violations(in: stripped), [])
        XCTAssertEqual(PortableListeningMapContract.forSharing([stripped]).count, 1)
    }

    func testASceneWithNoProvenanceCountsAsModelWritten() {
        let scene = PortableListeningMapScene(id: "s", order: 0, title: "Old title", eligibility: .excluded, startAnchor: start(0), endAnchor: start(1))
        let stripped = MapTextDisclosure.proposal(.init(id: "p", createdAt: checkedAt, generator: "g", scenes: [scene]), for: item(marked: nil))
        XCTAssertNil(stripped.scenes[0].title)
    }

    func testAMarkedSourceKeepsEverything() {
        let original = proposal()
        XCTAssertEqual(MapTextDisclosure.proposal(original, for: item(marked: address)), original)
        XCTAssertEqual(MapTextDisclosure.withheldSceneCount([original], for: item(marked: address)), 0)
    }

    func testThePreviewCountMatchesWhatIsWithheld() {
        XCTAssertEqual(MapTextDisclosure.withheldSceneCount([proposal()], for: item(marked: nil)), 1)
    }

    // MARK: The export goes through it

    func testAnExportWithTheMapOptionOnCarriesNoModelTitleWithoutTheMark() throws {
        for (marked, expectedTitle) in [(false, "Scene 1"), (true, "Model title")] {
            let repository = InMemorySessionRepository()
            var source = item(marked: marked ? address : nil)
            source.media = ItemMedia(sourceType: .remoteStream, url: address, durationMs: 100_000)
            try repository.saveItem(source)
            try repository.savePortableListeningMapProposal(proposal(), itemId: source.id)
            try repository.saveResolvedListeningMapProjection(ResolvedListeningMapProjection(
                id: "projection", itemId: source.id, proposalId: "proposal", algorithmVersion: "episode-projection.exact-edition.v1",
                points: [], intervals: []))
            let map = try XCTUnwrap(ListeningMapExportResolver.resolve(item: source, repository: repository, durationMs: 100_000))
            XCTAssertEqual(map.chapters.first?.title, expectedTitle, "marked: \(marked)")
        }
    }

    // MARK: A record from before this change

    func testAnItemFromBeforeThisChangeDecodesWithNoMark() throws {
        let plain = item(marked: nil)
        let json = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        XCTAssertFalse(json.contains("publicSourceMark"), json)
        XCTAssertNil(try JSONDecoder().decode(Item.self, from: Data(json.utf8)).publicSourceMark)
        let marked = item(marked: address)
        XCTAssertEqual(try JSONDecoder().decode(Item.self, from: try JSONEncoder().encode(marked)), marked)
    }

    // MARK: Helpers

    func testTheReviewNoteIsPlainAndOnlyShownWhenSomethingStays() {
        XCTAssertNil(MapTextDisclosure.withheldNote(sceneCount: 0))
        XCTAssertTrue(MapTextDisclosure.withheldNote(sceneCount: 1)?.contains("1 scene are left out") == true)
        XCTAssertTrue(MapTextDisclosure.withheldNote(sceneCount: 7)?.contains("7 scenes are left out") == true)
        XCTAssertTrue(MapTextDisclosure.withheldNote(sceneCount: 7)?.hasPrefix("Scene summaries stay on this phone.") == true)
    }

    private func item(reference: String? = "https://example.com/posts/harbour-lights", type: String? = "url", marked: String?) -> Item {
        var item = Item(id: "item-1", title: "Harbour Lights", mediaType: "text", text: nil, externalReference: reference,
                        status: "ready", externalReferenceType: type)
        item.publicSourceMark = marked.map { PublicSourceMark(url: $0, checkedAt: checkedAt) }
        return item
    }

    private func start(_ ms: Int) -> PortableAnchorEvidence {
        PortableAnchorEvidence(anchorType: .media, mediaTimeMs: ms)
    }

    private func proposal() -> PortableListeningMapProposalArtifact {
        PortableListeningMapProposalArtifact(id: "proposal", createdAt: checkedAt, generator: "on-device", scenes: [
            PortableListeningMapScene(
                id: "model", order: 0, title: "Model title", summaryText: "Model summary", summaryProvenance: .modelGenerated,
                eligibility: .eligible, eligibilityReason: "Model reason",
                startAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 0, chapterTitle: "Model title"),
                endAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 9_000, chapterTitle: "Model title")),
            PortableListeningMapScene(
                id: "publisher", order: 1, title: "Publisher title", summaryText: "Publisher summary", summaryProvenance: .publisherSupplied,
                eligibility: .eligible,
                startAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 10_000, chapterTitle: "Publisher title"), endAnchor: start(19_000)),
            PortableListeningMapScene(
                id: "sender", order: 2, title: "Sender title", summaryText: "Sender summary", summaryProvenance: .senderAuthored,
                eligibility: .eligible, startAnchor: start(20_000), endAnchor: start(29_000)),
            PortableListeningMapScene(
                id: "label", order: 3, title: "Part 4", summaryText: "Part four", summaryProvenance: .deterministic,
                eligibility: .eligible, startAnchor: start(30_000), endAnchor: start(39_000)),
        ])
    }
}
