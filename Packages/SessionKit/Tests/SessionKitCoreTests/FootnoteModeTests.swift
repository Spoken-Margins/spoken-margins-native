import XCTest
@testable import SessionKit

/// #3777: where a listener hears an article's footnotes, and which notes the player has already read.
final class FootnoteModeTests: XCTestCase {
    func testNothingStoredOrAnUnreadableValueReadsAsWhereCited() {
        for stored in [nil, "", "WhereCited", "where_cited", "chime ", "1", "atEnd\n"] as [String?] {
            XCTAssertEqual(FootnoteMode(storedValue: stored), .whereCited, "\(String(describing: stored))")
        }
        XCTAssertEqual(FootnoteMode.default, .whereCited)
    }

    func testEveryStoredValueRoundTrips() {
        XCTAssertEqual(FootnoteMode.allCases.map(\.rawValue), ["whereCited", "chime", "atEnd"],
                       "these strings are in listeners' UserDefaults; renaming one resets their choice")
        for mode in FootnoteMode.allCases {
            XCTAssertEqual(FootnoteMode(storedValue: mode.rawValue), mode)
        }
        XCTAssertEqual(FootnoteMode.storageKey, "footnoteMode")
    }

    func testThePickerOffersEveryModeInTheDesignsOrder() {
        XCTAssertEqual(FootnoteMode.pickerChoices, [.whereCited, .chime, .atEnd])
        XCTAssertEqual(Set(FootnoteMode.pickerChoices), Set(FootnoteMode.allCases), "no mode is stored that the picker cannot show")
        XCTAssertTrue(FootnoteMode.pickerChoices.contains(.default), "the default is a choice the picker can show selected")
    }

    func testThePickerShowsAChoiceForEveryStoredValue() {
        XCTAssertEqual(FootnoteMode.pickerChoices.map(\.pickerTitle), ["Read where cited", "Chime where cited", "Read at the end"])
        XCTAssertEqual(FootnoteMode.chime.pickerTitle, "Chime where cited")
        for stored in [nil, "", "garbage", "whereCited"] as [String?] {
            XCTAssertEqual(FootnoteMode.pickerSelection(storedValue: stored), .whereCited, "\(String(describing: stored))")
        }
        XCTAssertEqual(FootnoteMode.pickerSelection(storedValue: "atEnd"), .atEnd)
        XCTAssertEqual(FootnoteMode.pickerSelection(storedValue: "chime"), .chime)
    }

    func testOnlyReadingAtTheEndLeavesNoNoteChunksInThePlan() {
        XCTAssertTrue(FootnoteMode.whereCited.plansAsides)
        XCTAssertTrue(FootnoteMode.chime.plansAsides, "chime carries the same chunks and skips them at play time")
        XCTAssertFalse(FootnoteMode.atEnd.plansAsides)
    }

    func testPreparedAudioUnderThePlainIdentityKeepsItsNotesAtTheEnd() {
        let table: [(FootnoteMode, Bool, Bool)] = [
            (.whereCited, false, true),
            (.whereCited, true, false),
            (.chime, false, true),
            (.chime, true, false),
            (.atEnd, false, false),
            (.atEnd, true, false),
        ]
        for (mode, prepared, expected) in table {
            XCTAssertEqual(mode.asidesForPlan(preparedAudioExistsUnderPlainIdentity: prepared), expected,
                           "\(mode) prepared=\(prepared)")
        }
    }

    // MARK: Heard notes

    private typealias Tag = NarrationChunkPlanner.FootnoteTag

    /// Plays chunk `index` of `tags` to its end and returns the set.
    private func played(_ index: Int, of tags: [Tag?], into heard: FootnoteHeardSet = FootnoteHeardSet(),
                        itemId: String = "a") -> FootnoteHeardSet {
        var heard = heard
        heard.recordPlayedToEnd(chunkAt: index, tags: tags, itemId: itemId)
        return heard
    }

    func testANoteIsHeardOnlyOnceItsAsidePlayedToItsEnd() {
        let tags: [Tag?] = [nil, .aside("3"), nil]
        XCTAssertFalse(FootnoteHeardSet().hasHeardNote("3", itemId: "a"))
        XCTAssertTrue(played(1, of: tags).hasHeardNote("3", itemId: "a"))
    }

    func testOnlyAnAsideCountsAsHeard() {
        let tags: [Tag?] = [nil, .definition("3")]
        for index in [0, 1, -1, 2, 99] {
            XCTAssertEqual(played(index, of: tags), FootnoteHeardSet(), "chunk \(index)")
        }
    }

    /// A note longer than the chunk budget is several aside chunks with one label. Skipping during the second leaves
    /// the note unheard, so the notes chapter still reads it.
    func testALongNoteIsHeardOnlyWhenItsLastChunkEnds() {
        let tags: [Tag?] = [nil, .aside("1"), .aside("1"), nil, .definition("1")]
        let afterFirst = played(1, of: tags)
        XCTAssertFalse(afterFirst.hasHeardNote("1", itemId: "a"), "the first of two aside chunks is not the whole note")
        XCTAssertFalse(afterFirst.skips(.definition("1"), itemId: "a"))
        let afterLast = played(2, of: tags)
        XCTAssertTrue(afterLast.hasHeardNote("1", itemId: "a"))
        XCTAssertTrue(afterLast.skips(.definition("1"), itemId: "a"))
    }

    func testAnotherNotesChunkAfterOursDoesNotHideTheEnd() {
        let tags: [Tag?] = [.aside("1"), .aside("2"), .aside("2")]
        XCTAssertTrue(played(0, of: tags).hasHeardNote("1", itemId: "a"), "note 1 ends at chunk 0 even though note 2 follows")
        XCTAssertFalse(played(1, of: tags).hasHeardNote("2", itemId: "a"))
    }

    func testTheNotesChapterSkipsExactlyTheNotesThatWereHeard() {
        let tags: [Tag?] = [nil, .aside("1"), nil, .definition("1"), .definition("2")]
        let heard = played(1, of: tags)
        XCTAssertTrue(heard.skips(.definition("1"), itemId: "a"))
        XCTAssertFalse(heard.skips(.definition("2"), itemId: "a"), "a note never heard is read at the end")
        XCTAssertFalse(heard.skips(.aside("1"), itemId: "a"), "an aside is never skipped, so Hear note can replay it")
        XCTAssertFalse(heard.skips(nil, itemId: "a"), "body text is never skipped")
    }

    func testTwoItemsKeepTheirNotesApart() {
        let heard = played(0, of: [.aside("1")], itemId: "first")
        XCTAssertTrue(heard.skips(.definition("1"), itemId: "first"))
        XCTAssertFalse(heard.skips(.definition("1"), itemId: "second"))
    }

    func testLabelsAreMatchedExactly() {
        let heard = played(0, of: [.aside("note-1")])
        for other in ["1", "Note-1", "note-1 ", "NOTE-1", ""] {
            XCTAssertFalse(heard.hasHeardNote(other, itemId: "a"), "\(other.debugDescription)")
        }
        XCTAssertTrue(heard.hasHeardNote("note-1", itemId: "a"))
    }

    func testForgettingAnItemLeavesTheOthers() {
        var heard = played(0, of: [.aside("1")], itemId: "a")
        heard = played(0, of: [.aside("1")], into: heard, itemId: "b")
        heard.forget(itemId: "a")
        XCTAssertFalse(heard.hasHeardNote("1", itemId: "a"))
        XCTAssertTrue(heard.hasHeardNote("1", itemId: "b"))
        heard.forget(itemId: "missing")
        XCTAssertTrue(heard.hasHeardNote("1", itemId: "b"))
    }

    /// With the planner's real output, including a note long enough to be several aside chunks: playing only the first
    /// of them leaves its definition to be read, and playing the last one skips it.
    func testItSkipsTheDefinitionChunksOfAPlannedArticle() {
        let longNote = (1...30).map { "Detail number \($0) of the long caveat." }.joined(separator: " ")
        let article = """
        The first claim stands.[^1] The second claim needs care.[^2] The third is plain.

        [^1]: A source for the first claim.

        [^2]: \(longNote)
        """
        let plan = NarrationChunkPlanner.articlePlan(article, asides: true)
        let tags = plan.chunks.map(\.footnote)
        let asideIndexes: [String: [Int]] = tags.enumerated().reduce(into: [:]) { result, pair in
            if case .aside(let label)? = pair.element { result[label, default: []].append(pair.offset) }
        }
        XCTAssertEqual(asideIndexes["1"]?.count, 1, "a short note is one aside chunk")
        XCTAssertGreaterThan(asideIndexes["2"]?.count ?? 0, 1, "the long note is several aside chunks")

        // A long note's definition is several chunks too, so compare the labels the chapter still reads, not the count.
        func definitionsPlayed(after heard: FootnoteHeardSet) -> Set<String> {
            Set(tags.filter { !heard.skips($0, itemId: "item") }.compactMap { tag -> String? in
                if case .definition(let label)? = tag { return label }
                return nil
            })
        }
        var heard = played(asideIndexes["1"]![0], of: tags, itemId: "item")
        XCTAssertEqual(definitionsPlayed(after: heard), Set(["2"]), "the notes chapter reads only the note that was not heard")
        heard = played(asideIndexes["2"]![0], of: tags, into: heard, itemId: "item")
        XCTAssertEqual(definitionsPlayed(after: heard), Set(["2"]), "the first chunk of the long note is not the whole note")
        heard = played(asideIndexes["2"]!.last!, of: tags, into: heard, itemId: "item")
        XCTAssertEqual(definitionsPlayed(after: heard), [], "both notes were heard, so the chapter reads neither")
        XCTAssertEqual(tags.filter { !heard.skips($0, itemId: "item") && $0 == nil }.count, tags.filter { $0 == nil }.count,
                       "no body chunk is skipped")
    }
}
