import Foundation
import XCTest
@testable import SessionKit

/// #2184: a reload that leaves the map as it was must keep Skim's loaded resources; a map change must drop them.
final class SkimResourceKeyTests: XCTestCase {
    private func layer(_ id: String = "friend") -> ImportedCommentaryLayer {
        ImportedCommentaryLayer(
            id: id, itemId: "episode", packageDigest: "digest-\(id)", packageId: "package-\(id)",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode", durationMs: 60_000),
            importedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func mappedEpisode() -> ItemDetailState {
        var item = ItemDetailState()
        item.id = "episode"
        item.title = "Episode"
        item.listeningMapScenes = [
            MediaTimelineChapter(id: "scene-0", title: "Opening", startMs: 0, transcriptSegmentId: "s0"),
            MediaTimelineChapter(id: "scene-1", title: "Middle", startMs: 30_000, transcriptSegmentId: "s1"),
        ]
        item.listeningMapSummarySpans = [SceneSummarySpan(sceneId: "scene-0", startMs: 0, endMs: 30_000, summary: "A recap.")]
        item.importedCommentaryLayers = [layer()]
        return item
    }

    /// Fields an ordinary reload changes (sessions and Margins are of the same kind: none feed the map).
    func testAReloadThatLeavesTheMapAloneKeepsTheKey() {
        let before = mappedEpisode()
        var after = before
        after.status = "in_progress"
        after.text = String(repeating: "A long transcript. ", count: 1_000)
        after.title = "Episode, renamed"
        after.overview = "A new Margin was saved."
        after.mediaDurationMs = 60_000
        XCTAssertEqual(SkimResourceKey(before), SkimResourceKey(after))
    }

    func testEachMapChangeChangesTheKey() {
        let base = SkimResourceKey(mappedEpisode())
        var otherItem = mappedEpisode(); otherItem.id = "another"
        var moved = mappedEpisode(); moved.listeningMapScenes[1].startMs = 31_000
        var noMap = mappedEpisode(); noMap.listeningMapScenes = []
        var newSummary = mappedEpisode()
        newSummary.listeningMapSummarySpans = [SceneSummarySpan(sceneId: "scene-0", startMs: 0, endMs: 30_000, summary: "Another.")]
        var addedLayer = mappedEpisode(); addedLayer.importedCommentaryLayers.append(layer("second"))
        var deletedLayer = mappedEpisode(); deletedLayer.importedCommentaryLayers[0].deletedAt = Date()
        var placedLayer = mappedEpisode(); placedLayer.importedCommentaryLayers[0].sourceResolutionStatus = .resolved
        var matchedEdition = mappedEpisode(); matchedEdition.importedCommentaryLayers[0].resolvedRecipientEditionSHA256 = "abc"
        var newTextMap = mappedEpisode()
        newTextMap.chapters = [Chapter(id: "scene-1", title: "Opening", startChar: 0, endChar: 400, percent: 0)]
        let rows: [(String, ItemDetailState)] = [
            ("a text map was added", newTextMap),
            ("another item", otherItem), ("a scene moved", moved), ("the map went away", noMap),
            ("a summary changed", newSummary), ("a friend's layer arrived", addedLayer),
            ("a layer was deleted", deletedLayer), ("a layer was placed", placedLayer),
            ("a layer matched the edition", matchedEdition),
        ]
        for (name, item) in rows {
            XCTAssertNotEqual(SkimResourceKey(item), base, name)
        }
    }
}
