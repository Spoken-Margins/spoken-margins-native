import Foundation
import XCTest
@testable import SessionKit

/// #777: a Margin row names the chapter and the paragraph where the Margin was made.
final class MarginPlaceIndexTests: XCTestCase {
    private func chapter(_ title: String, _ startChar: Int) -> Chapter {
        Chapter(id: "c\(startChar)", title: title, startChar: startChar, endChar: startChar + 100, percent: 0)
    }

    // MARK: Chapter names

    func testTheChapterNameIsTheLastOneStartingAtOrBeforeTheOffset() {
        let index = MarginPlaceIndex(chapters: [chapter("Housing", 100), chapter("Wages", 400), chapter("Rents", 900)])
        XCTAssertNil(index.chapterName(atChar: 0))
        XCTAssertNil(index.chapterName(atChar: 99))
        XCTAssertEqual(index.chapterName(atChar: 100), "Housing")
        XCTAssertEqual(index.chapterName(atChar: 399), "Housing")
        XCTAssertEqual(index.chapterName(atChar: 400), "Wages")
        XCTAssertEqual(index.chapterName(atChar: 5_000), "Rents")
    }

    func testChaptersInAnyOrderAreFound() {
        let index = MarginPlaceIndex(chapters: [chapter("Rents", 900), chapter("Housing", 100), chapter("Wages", 400)])
        XCTAssertEqual(index.chapterName(atChar: 500), "Wages")
    }

    func testNoChaptersMeansNoName() {
        XCTAssertNil(MarginPlaceIndex(chapters: []).chapterName(atChar: 10))
    }

    func testABlankChapterTitleIsSkippedSoTheEarlierChapterStillNamesThePlace() {
        let index = MarginPlaceIndex(chapters: [chapter("Housing", 100), chapter("  \n ", 400)])
        XCTAssertEqual(index.chapterName(atChar: 450), "Housing")
    }

    func testALongOrMultiLineTitleIsKeptToOneShortLine() {
        let index = MarginPlaceIndex(chapters: [
            chapter("Chapter 3:\n  Why housing costs keep outrunning wages in every region", 0),
        ])
        let name = index.chapterName(atChar: 0)
        XCTAssertEqual(name?.count, MarginPlaceIndex.maximumNameCharacters)
        XCTAssertEqual(name, "Chapter 3: Why housing cost…")
        XCTAssertEqual(MarginPlaceIndex(chapters: [chapter("Chapter 3", 0)]).chapterName(atChar: 0), "Chapter 3")
    }

    // MARK: Paragraphs

    func testParagraphsAreNumberedFromOneByLine() {
        let text = "First paragraph here.\nSecond one.\nThird."
        let index = MarginPlaceIndex(chapters: [], text: text)
        XCTAssertEqual(index.paragraph(atChar: 0), 1)
        XCTAssertEqual(index.paragraph(atChar: 20), 1)
        XCTAssertEqual(index.paragraph(atChar: 22), 2)
        XCTAssertEqual(index.paragraph(atChar: 34), 3)
        XCTAssertEqual(index.paragraph(atChar: 5_000), 3)
    }

    func testBlankLinesAndLeadingBlanksDoNotCountAsParagraphs() {
        let text = "\n\n  Alpha\n \n\n   Beta\n"
        let index = MarginPlaceIndex(chapters: [], text: text)
        let beta = text.distance(from: text.startIndex, to: text.range(of: "Beta")!.lowerBound)
        XCTAssertEqual(index.paragraph(atChar: 0), 1)
        XCTAssertEqual(index.paragraph(atChar: beta), 2)
        XCTAssertEqual(index.paragraph(atChar: beta + 3), 2)
    }

    func testAParagraphNumberOnlyReadsTheTextAsFarAsItIsAsked() {
        let text = "One.\nTwo.\nThree.\nFour."
        let index = MarginPlaceIndex(chapters: [], text: text, readingUpTo: 6)
        XCTAssertEqual(index.paragraph(atChar: 0), 1)
        XCTAssertEqual(index.paragraph(atChar: 6), 2)
    }

    func testOffsetsCountCharactersNotBytes() {
        let text = "Café ☕ ok\nnext one"
        let index = MarginPlaceIndex(chapters: [], text: text)
        XCTAssertEqual(index.paragraph(atChar: 8), 1)
        XCTAssertEqual(index.paragraph(atChar: 10), 2)
    }

    func testNoTextEmptyTextOrANegativeOffsetHasNoParagraph() {
        XCTAssertNil(MarginPlaceIndex(chapters: []).paragraph(atChar: 5))
        XCTAssertNil(MarginPlaceIndex(chapters: [], text: " \n ").paragraph(atChar: 0))
        XCTAssertNil(MarginPlaceIndex(chapters: [], text: "abc").paragraph(atChar: -1))
    }

    // MARK: Places for the Margins tab

    private func entry(_ id: String, item: String = "item", target: InterjectionTargetType = .item,
                       mediaTimeMs: Int? = nil, startChar: Int = 0) -> MarginCollection.PrivateEntry {
        MarginCollection.PrivateEntry(
            interjection: Interjection(
                id: id, itemId: item, sessionId: "s", targetType: target, targetId: item,
                createdAt: Date(timeIntervalSince1970: 0), roughPercent: 0,
                anchor: Anchor(anchorType: mediaTimeMs == nil ? .text : .media, startChar: startChar, endChar: startChar,
                               anchorBefore: "", anchorAfter: "", mediaTimeMs: mediaTimeMs),
                audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: nil,
                cleanedTranscript: nil, displayText: nil, status: "active"),
            itemTitle: "Title", sessionDate: nil)
    }

    private func item(_ id: String, text: String?) -> Item {
        Item(id: id, title: "Title", mediaType: "text", text: text, externalReference: nil, status: "ready")
    }

    private func map(_ itemId: String, _ chapters: [Chapter]) -> ListeningMap {
        ListeningMap(id: "map-\(itemId)", itemId: itemId, overview: "", chapters: chapters)
    }

    func testATextItemGetsItsChapterAndParagraph() {
        let text = "Intro line.\nSecond line.\nThird line."
        let entries = [entry("a", startChar: 0), entry("b", startChar: 14), entry("c", startChar: 28)]
        let places = MarginPlaces.places(
            for: entries, items: [item("item", text: text)],
            loadMap: { _ in self.map("item", [self.chapter("Start", 0), self.chapter("End", 25)]) })
        XCTAssertEqual(places[entries[0].id], MarginPlaces.Place(chapterName: "Start", paragraph: 1))
        XCTAssertEqual(places[entries[1].id], MarginPlaces.Place(chapterName: "Start", paragraph: 2))
        XCTAssertEqual(places[entries[2].id], MarginPlaces.Place(chapterName: "End", paragraph: 3))
    }

    /// A publisher-chapter map stores each chapter's index as its `startChar` (0, 1, 2), so a podcast Margin's
    /// offset can't be compared with it: this one would read "Intro" if it were.
    func testAMediaMarginHasNoPlaceHere() {
        let entries = [entry("m", mediaTimeMs: 1_200_000, startChar: 0), entry("n", mediaTimeMs: 1_300_000, startChar: 15_000)]
        let chapters = [chapter("Intro", 0), chapter("Ads", 1), chapter("Interview", 2)]
        let places = MarginPlaces.places(
            for: entries, items: [item("item", text: "One.\nTwo.")], loadMap: { _ in self.map("item", chapters) })
        XCTAssertTrue(places.isEmpty)
    }

    func testTextMarginsOnAMixedItemStillGetTheirPlace() {
        let entries = [entry("m", mediaTimeMs: 1_000, startChar: 0), entry("t", startChar: 6)]
        let places = MarginPlaces.places(
            for: entries, items: [item("item", text: "One.\nTwo.")], loadMap: { _ in self.map("item", [self.chapter("Start", 0)]) })
        XCTAssertNil(places[entries[0].id])
        XCTAssertEqual(places[entries[1].id], MarginPlaces.Place(chapterName: "Start", paragraph: 2))
    }

    func testAnItemWithNoMapAndNoTextHasNoPlaceAndIsLeftOut() {
        let entries = [entry("t", startChar: 3)]
        let places = MarginPlaces.places(for: entries, items: [item("item", text: nil)], loadMap: { _ in nil })
        XCTAssertTrue(places.isEmpty)
    }

    func testAResponseIsNotInTheSourceSoItHasNoPlace() {
        let entries = [entry("r", target: .assistantTurn, startChar: 10)]
        let places = MarginPlaces.places(
            for: entries, items: [item("item", text: "One.\nTwo.")],
            loadMap: { _ in self.map("item", [self.chapter("Start", 0)]) })
        XCTAssertTrue(places.isEmpty)
    }

    func testEachItemUsesItsOwnMapAndText() {
        let entries = [entry("a", item: "one", startChar: 0), entry("b", item: "two", startChar: 0)]
        let places = MarginPlaces.places(
            for: entries, items: [item("one", text: "x"), item("two", text: "y")],
            loadMap: { id in self.map(id, [self.chapter("Chapter of \(id)", 0)]) })
        XCTAssertEqual(places[entries[0].id]?.chapterName, "Chapter of one")
        XCTAssertEqual(places[entries[1].id]?.chapterName, "Chapter of two")
    }

    func testBuildCarriesEachMarginsPlaceOnlyWhenGivenAWayToReadMaps() throws {
        let source = item("item", text: "Intro line.\nSecond line.")
        let session = Session(
            id: "s", itemId: "item", createdAt: nil, updatedAt: nil, status: "in_progress", phase: .itemPlayback,
            currentTargetType: .itemTextTTS, currentTargetId: "item", position: Position(), completionPercent: 0, playbackRate: 1)
        let margin = entry("m", startChar: 14).interjection
        func build(_ loadMap: ((String) -> ListeningMap?)?) throws -> MarginCollection.Entries {
            try MarginCollection.build(
                items: [source], sessions: [session], loadMap: loadMap,
                loadInterjections: { _ in [margin] }, loadImportedLayers: { [] }, loadImportedInterjections: { _ in [] })
        }
        let withMaps = try build { _ in self.map("item", [self.chapter("Start", 0)]) }
        XCTAssertEqual(withMaps.privateRows.first?.place, MarginPlaces.Place(chapterName: "Start", paragraph: 2))
        XCTAssertNil(try build(nil).privateRows.first?.place)
        XCTAssertEqual(try build(nil).privateRows.first?.id, withMaps.privateRows.first?.id)
    }
}
