import XCTest
@testable import SessionKit

/// #4447: Skim's arrows must be recomputed when the item detail changes what Skim stops at, and only then. The app
/// asks `skimStopInputsDiffer` on every assignment of the selected item, so a false negative leaves a stale (or
/// missing) arrow beside the chapter title and a false positive repeats the work on every unrelated refresh.
final class ItemDetailSkimInputsTests: XCTestCase {
    private func margin(_ id: String) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(
            id: id, layerId: "layer", packageScopedId: "margin-\(id)", createdAt: Date(timeIntervalSince1970: 1_777_000_000),
            anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 60_000), approvedTranscript: "words")
    }

    private func detail(_ configure: (inout ItemDetailState) -> Void = { _ in }) -> ItemDetailState {
        var state = ItemDetailState()
        state.id = "item"
        configure(&state)
        return state
    }

    func testChangesToWhatSkimStopsAtAreReported() {
        let empty = detail()
        let rows: [(String, ItemDetailState)] = [
            ("another item", detail { $0.id = "other" }),
            ("text chapters arrive", detail { $0.chapters = [Chapter(id: "c", title: "One", startChar: 0, endChar: 9, percent: 50)] }),
            ("media chapters arrive", detail { $0.mediaChapters = [MediaTimelineChapter(id: "m", title: "One", startMs: 0, transcriptSegmentId: "s")] }),
            ("Listening Map scenes arrive", detail { $0.listeningMapScenes = [MediaTimelineChapter(id: "s1", title: "Scene", startMs: 0, transcriptSegmentId: "s")] }),
            ("a friend's layer records arrive", detail { $0.importedCommentaryInterjections = ["layer": [margin("a")]] }),
        ]
        for (name, changed) in rows {
            XCTAssertTrue(changed.skimStopInputsDiffer(from: empty), "\(name): Skim must look again")
            XCTAssertTrue(empty.skimStopInputsDiffer(from: changed), "\(name): and again when they leave")
        }
    }

    func testAFriendsRecordsChangingWithinALayerIsReported() {
        let one = detail { $0.importedCommentaryInterjections = ["layer": [margin("a")]] }
        let two = detail { $0.importedCommentaryInterjections = ["layer": [margin("a"), margin("b")]] }
        XCTAssertTrue(two.skimStopInputsDiffer(from: one))
    }

    func testChangesThatCannotMoveAStopAreNotReported() {
        let base = detail { $0.chapters = [Chapter(id: "c", title: "One", startChar: 0, endChar: 9, percent: 50)] }
        let rows: [(String, ItemDetailState)] = [
            ("the same item again", base),
            ("a new title", { var s = base; s.title = "Renamed"; return s }()),
            ("a new status", { var s = base; s.status = "ready"; return s }()),
            ("a new overview", { var s = base; s.overview = "Words"; return s }()),
            ("a published date", { var s = base; s.publishedDateText = "Nov 1"; return s }()),
        ]
        for (name, same) in rows {
            XCTAssertFalse(same.skimStopInputsDiffer(from: base), "\(name): no stop moved, so no recompute")
        }
    }
}
