import Foundation
import XCTest
@testable import SessionKit

/// The item notebook (#778): an item's own and shared Margins under its chapters, scenes or
/// 10-minute and 10-paragraph stretches, in source order.
final class ItemNotebookTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_790_000_000)
    private let minute = 60_000

    func testAPodcastWithChaptersInterleavesOwnAndSharedMarginsByPosition() {
        let chapters = [
            MediaTimelineChapter(id: "c2", title: "The deal", startMs: 20 * minute, transcriptSegmentId: "s2"),
            MediaTimelineChapter(id: "c1", title: "Cold open", startMs: 0, transcriptSegmentId: "s1"),
        ].map(ItemNotebook.Heading.init)
        let notebook = ItemNotebook.build(
            unit: .media, chapters: chapters, end: 60 * minute,
            ownMargins: [own("o2", ms: 25 * minute), own("o1", ms: 5 * minute)],
            sharedMargins: [shared("s1", local: 22 * minute, evidence: .transcriptVerified), shared("s2", sender: 3 * minute)],
            senderNames: ["layer-1": "Sam"]
        )
        XCTAssertEqual(notebook.sections.map(\.title), ["Cold open", "The deal"])
        XCTAssertEqual(notebook.sections.map { $0.entries.map(\.marginID) }, [["s2", "o1"], ["s1", "o2"]])
        XCTAssertEqual(notebook.sections[0].entries[0].origin, .shared(senderName: "Sam"))
        XCTAssertTrue(notebook.sections[0].entries[0].isApproximate, "placed by the sender's time")
        XCTAssertFalse(notebook.sections[1].entries[0].isApproximate, "a verified match")
        XCTAssertEqual(notebook.sections[1].entries[1].origin, .own)
        XCTAssertEqual(notebook.sections.map(\.kind), [.chapter, .chapter])
    }

    func testChaptersWinOverScenesAndEmptyChaptersStay() {
        let chapters = [ItemNotebook.Heading(id: "a", title: "A", start: 0), ItemNotebook.Heading(id: "b", title: "B", start: 10 * minute)]
        let scenes = [ItemNotebook.Heading(id: "s", title: "Scene", summary: "Gist", start: 0)]
        let notebook = ItemNotebook.build(unit: .media, chapters: chapters, scenes: scenes, ownMargins: [own("o", ms: minute)])
        XCTAssertEqual(notebook.sections.map(\.title), ["A", "B"])
        XCTAssertEqual(notebook.sections[1].entries, [], "a chapter without Margins is still a heading")
    }

    func testAnItemWithOnlyAListeningMapUsesItsScenesAndSummaries() {
        let map = ListeningMap(id: "map", itemId: "item", overview: "", chapters: [
            Chapter(id: "scene-1", title: "Setting up", startChar: 0, endChar: 400, percent: 0),
            Chapter(id: "scene-2", title: "The turn", startChar: 400, endChar: 900, percent: 44),
        ])
        let summaries = ["scene-1": "Why the town flooded.", "scene-2": "Who paid for it."]
        let scenes = map.chapters.map { ItemNotebook.Heading($0, summary: summaries[$0.id]) }
        let notebook = ItemNotebook.build(unit: .text, scenes: scenes, end: 900,
                                          ownMargins: [own("o1", char: 120), own("o2", char: 650)])
        XCTAssertEqual(notebook.sections.map(\.kind), [.scene, .scene])
        XCTAssertEqual(notebook.sections.map(\.summary), ["Why the town flooded.", "Who paid for it."])
        XCTAssertEqual(notebook.sections.map { $0.entries.map(\.marginID) }, [["o1"], ["o2"]])
    }

    func testMediaWithNeitherGetsTenMinuteHeadingsOnlyWhereMarginsAre() {
        let notebook = ItemNotebook.build(
            unit: .media, end: 95 * minute,
            ownMargins: [own("late", ms: 47 * minute), own("early", ms: 3 * minute), own("edge", ms: 10 * minute)]
        )
        XCTAssertEqual(notebook.sections.map(\.title), ["0–10 min", "10–20 min", "40–50 min"])
        XCTAssertEqual(notebook.sections.map(\.kind), [.span, .span, .span])
        XCTAssertEqual(notebook.sections.map { $0.entries.map(\.marginID) }, [["early"], ["edge"], ["late"]])
    }

    func testTextWithNeitherGetsTenParagraphHeadings() {
        let text = (1...23).map { "Paragraph \($0) text." }.joined(separator: "\n\n")
        let starts = ListeningEdition.blocks(in: text).map(\.startChar)
        let notebook = ItemNotebook.build(
            unit: .text, paragraphStarts: starts, end: text.count,
            ownMargins: [own("p3", char: starts[2] + 2), own("p22", char: starts[21]), own("p11", char: starts[10])]
        )
        XCTAssertEqual(notebook.sections.map(\.title), ["Paragraphs 1–10", "Paragraphs 11–20", "Paragraphs 21–23"])
        XCTAssertEqual(notebook.sections.map { $0.entries.map(\.marginID) }, [["p3"], ["p11"], ["p22"]])
        XCTAssertEqual(notebook.sections[1].start, starts[10])
    }

    func testAnUnplacedSharedMarginGoesUnderNotPlacedYet() {
        let chapters = [ItemNotebook.Heading(id: "a", title: "A", start: 0)]
        let unplaced = shared("lost", local: nil, evidence: .unresolved, sender: nil)
        let notebook = ItemNotebook.build(unit: .media, chapters: chapters, ownMargins: [own("o", ms: minute)],
                                          sharedMargins: [unplaced])
        XCTAssertEqual(notebook.sections.map(\.title), ["A", "Not placed yet"])
        XCTAssertEqual(notebook.sections.last?.kind, .notPlacedYet)
        XCTAssertEqual(notebook.sections.last?.entries.map(\.marginID), ["lost"])
        XCTAssertNil(notebook.sections.last?.entries.first?.position)
    }

    func testARecapMarginGoesUnderAtTheEnd() {
        let chapters = [ItemNotebook.Heading(id: "a", title: "A", start: 0)]
        let notebook = ItemNotebook.build(
            unit: .media, chapters: chapters, end: 60 * minute,
            ownMargins: [own("recap", ms: 60 * minute - 400), own("mid", ms: 30 * minute), own("byPercent", ms: 59 * minute, roughPercent: 100)]
        )
        XCTAssertEqual(notebook.sections.map(\.title), ["A", "At the end"])
        XCTAssertEqual(notebook.sections[0].entries.map(\.marginID), ["mid"])
        XCTAssertEqual(notebook.sections[1].entries.map(\.marginID), ["byPercent", "recap"])
        XCTAssertEqual(notebook.sections.map(\.kind), [.chapter, .atTheEnd])
    }

    func testAMarginBeforeTheFirstChapterGoesUnderIt() {
        let chapters = [ItemNotebook.Heading(id: "a", title: "A", start: 2 * minute)]
        let notebook = ItemNotebook.build(unit: .media, chapters: chapters, ownMargins: [own("o", ms: 30_000)])
        XCTAssertEqual(notebook.sections[0].entries.map(\.marginID), ["o"])
    }

    func testSenderNamesComeFromLayerLabels() {
        let names = ItemNotebook.senderNames(from: [layer("l1", label: "Sam"), layer("l2", label: "  "), layer("l3", label: nil)])
        XCTAssertEqual(names, ["l1": "Sam"])
    }

    func testNoMarginsGivesOnlyTheStructure() {
        XCTAssertEqual(ItemNotebook.build(unit: .media, ownMargins: []).sections, [])
        let chapters = [ItemNotebook.Heading(id: "a", title: "A", start: 0)]
        XCTAssertEqual(ItemNotebook.build(unit: .media, chapters: chapters, ownMargins: []).sections.map(\.title), ["A"])
    }

    // MARK: Fixtures

    private func own(_ id: String, ms: Int? = nil, char: Int = 0, roughPercent: Int = 50) -> Interjection {
        Interjection(
            id: id, itemId: "item", sessionId: "session", targetType: .item, targetId: "item",
            createdAt: base, roughPercent: roughPercent,
            anchor: Anchor(anchorType: ms == nil ? .text : .media, startChar: char, endChar: char,
                           anchorBefore: "", anchorAfter: "", mediaTimeMs: ms),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: nil,
            cleanedTranscript: nil, displayText: "A Margin", status: "active"
        )
    }

    private func shared(_ id: String, local: Int? = nil, evidence: AnchorResolutionEvidenceClass = .unresolved, sender: Int? = nil) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(
            id: id, layerId: "layer-1", packageScopedId: "pkg::\(id)", createdAt: base,
            anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: sender),
            approvedTranscript: "Shared", resolution: ImportedAnchorResolution(evidenceClass: evidence, localMediaTimeMs: local)
        )
    }

    private func layer(_ id: String, label: String?) -> ImportedCommentaryLayer {
        ImportedCommentaryLayer(
            id: id, packageDigest: "d", packageId: "p", itemIdentity: SharedItemIdentity(itemType: .text, title: "Item"),
            displayLabel: label, importedAt: base
        )
    }
}
