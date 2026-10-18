import Foundation
import SessionKit
import XCTest

/// When a shared podcast Margin may ask for a transcript of the listener's copy, and which layers a placement
/// pass works on (#318). The app's `ImportedPodcastPlacementCoordinatorTests` run the coordinator around these rules.
final class ImportedPodcastPlacementPolicyTests: XCTestCase {
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)
    private let cooldown = ImportedPodcastPlacementPolicy.transientCooldown

    // MARK: transientTranscriptMayStart

    func testTheCooldownIsSixtySeconds() {
        XCTAssertEqual(cooldown, 60)
    }

    func testNoEarlierTranscriptMayStartWhenTheSlotIsFree() {
        XCTAssertTrue(ImportedPodcastPlacementPolicy.transientTranscriptMayStart(lastStart: nil, now: clock, slotIsFree: true))
    }

    func testAHeldSlotRefusesWhateverTheClockSays() {
        for last in [nil, clock.addingTimeInterval(-3_600), clock] as [Date?] {
            XCTAssertFalse(ImportedPodcastPlacementPolicy.transientTranscriptMayStart(
                lastStart: last, now: clock, slotIsFree: false))
        }
    }

    func testTheCooldownRunsFromTheLastStartAndIncludesItsEnd() {
        let rows: [(String, TimeInterval, Bool)] = [
            ("just started", 0, false),
            ("one second short", cooldown - 1, false),
            ("a hair short", cooldown - 0.001, false),
            ("exactly the cooldown", cooldown, true),
            ("past the cooldown", cooldown + 1, true),
            ("a clock that moved back", -30, false),
        ]
        for (name, elapsed, allowed) in rows {
            XCTAssertEqual(
                ImportedPodcastPlacementPolicy.transientTranscriptMayStart(
                    lastStart: clock, now: clock.addingTimeInterval(elapsed), slotIsFree: true),
                allowed, name)
        }
    }

    // MARK: podcastLayerRecords and commentaryNeedsTranscript

    private func layer(
        id: String, type: SharedItemType = .podcast, deleted: Bool = false, mapPaths: [String: String]? = nil
    ) -> ImportedCommentaryLayer {
        ImportedCommentaryLayer(
            id: id, itemId: "item-1", packageDigest: "digest-\(id)", packageId: "package-\(id)",
            itemIdentity: SharedItemIdentity(itemType: type, title: "Harbour Lights"), importedAt: clock,
            deletedAt: deleted ? clock : nil, episodeMapEvidencePaths: mapPaths)
    }

    private func margin(_ id: String, layerId: String) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(
            id: id, layerId: layerId, packageScopedId: "scoped-\(id)", createdAt: clock,
            anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 1_000), approvedTranscript: "words")
    }

    func testOnlyLivePodcastLayersWithMarginsOrMapArtifactsAreWorkedOn() {
        let layers = [
            layer(id: "ok"),
            layer(id: "deleted", deleted: true),
            layer(id: "article", type: .text),
            layer(id: "unreadable"),
            layer(id: "empty"),
            layer(id: "empty-with-map", mapPaths: ["scene": "SpokenMargins/EpisodeMaps/scene.json"]),
        ]
        let records: [String: [ImportedCommentaryInterjection]?] = [
            "ok": [margin("a", layerId: "ok")],
            "deleted": [margin("b", layerId: "deleted")],
            "article": [margin("c", layerId: "article")],
            "unreadable": nil,
            "empty": [],
            "empty-with-map": [],
        ]
        let work = ImportedPodcastPlacementPolicy.podcastLayerRecords(layers: layers) { records[$0.id] ?? nil }
        XCTAssertEqual(work.map(\.0.id), ["ok", "empty-with-map"])
        XCTAssertEqual(work.map { $0.1.count }, [1, 0])
    }

    func testTranscriptIsNeededWhenAnyMarginOnALiveLayerNeedsOne() {
        let layers = [layer(id: "one"), layer(id: "two")]
        let all: [String: [ImportedCommentaryInterjection]] = [
            "one": [margin("a", layerId: "one"), margin("b", layerId: "one")],
            "two": [margin("c", layerId: "two")],
        ]
        func needs(_ ids: Set<String>) -> Bool {
            ImportedPodcastPlacementPolicy.commentaryNeedsTranscript(
                layers: layers, loadRecords: { all[$0.id] }, recordNeedsTranscript: { ids.contains($0.id) })
        }
        XCTAssertFalse(needs([]))
        XCTAssertTrue(needs(["a"]))
        XCTAssertTrue(needs(["c"]), "the second layer counts too")
        XCTAssertTrue(needs(["a", "b", "c"]))
    }

    func testAMarginOnADeletedOrNonPodcastLayerNeverAsksForATranscript() {
        let layers = [layer(id: "deleted", deleted: true), layer(id: "article", type: .text)]
        let needs = ImportedPodcastPlacementPolicy.commentaryNeedsTranscript(
            layers: layers, loadRecords: { [self.margin("a", layerId: $0.id)] }, recordNeedsTranscript: { _ in true })
        XCTAssertFalse(needs)
    }

    func testNothingToPlaceNeedsNoTranscript() {
        XCTAssertFalse(ImportedPodcastPlacementPolicy.commentaryNeedsTranscript(
            layers: [], loadRecords: { _ in [] }, recordNeedsTranscript: { _ in true }))
        XCTAssertFalse(ImportedPodcastPlacementPolicy.commentaryNeedsTranscript(
            layers: [layer(id: "empty")], loadRecords: { _ in [] }, recordNeedsTranscript: { _ in true }))
    }
}
