import XCTest
@testable import SessionKit

/// "Find in text" matcher (#5035, hidden slice): one row per neighbouring input, offsets in the original text.
final class ItemTextSearchTests: XCTestCase {
    private struct Row {
        var name: String
        var text: String
        var query: String
        /// Expected (start, end) in Characters of `text`; empty for "must not match".
        var expected: [(Int, Int)]
    }

    func testMatchTable() {
        let rows: [Row] = [
            Row(name: "exact", text: "The cell divides.", query: "cell", expected: [(4, 8)]),
            Row(name: "case-insensitive", text: "The Cell divides.", query: "cELL", expected: [(4, 8)]),
            Row(name: "curly apostrophe in text, straight in query", text: "It\u{2019}s done.", query: "it's", expected: [(0, 4)]),
            Row(name: "straight apostrophe in text, curly in query", text: "It's done.", query: "it\u{2019}s", expected: [(0, 4)]),
            Row(name: "curly double quotes", text: "He said \u{201C}stop\u{201D} twice.", query: "\"stop\"", expected: [(8, 14)]),
            Row(name: "NFD text, NFC query", text: "cafe\u{0301} au lait", query: "caf\u{00E9}", expected: [(0, 4)]),
            Row(name: "NFC text, NFD query", text: "caf\u{00E9} au lait", query: "cafe\u{0301}", expected: [(0, 4)]),
            Row(name: "hyphen and line break inside a word", text: "A study of hyphen-\nation here.", query: "hyphenation", expected: [(11, 24)]),
            Row(name: "hyphen, CRLF and indent", text: "hyphen-\r\n  ation", query: "hyphenation", expected: [(0, 15)]),
            Row(name: "typed hyphen with a break in the text", text: "well-\nknown", query: "wellknown", expected: [(0, 11)]),
            Row(name: "hyphen with no line break is kept", text: "a well-known fact", query: "wellknown", expected: []),
            Row(name: "hyphen with no line break matches itself", text: "a well-known fact", query: "well-known", expected: [(2, 12)]),
            Row(name: "ligature in text", text: "The \u{FB01}rst of\u{FB01}ce", query: "first office", expected: [(4, 14)]),
            Row(name: "ligature in text, plain query", text: "the \u{FB01}rst ", query: "first", expected: [(4, 8)]),
            Row(name: "ligature in query, plain text", text: "the first ", query: "\u{FB01}rst", expected: [(4, 9)]),
            Row(name: "soft hyphen in text", text: "inter\u{00AD}national", query: "international", expected: [(0, 14)]),
            Row(name: "typed hyphen finds a compound wrapped at the hyphen", text: "a well-\nknown fact", query: "well-known", expected: [(2, 13)]),
            Row(name: "one ligature is one match, not three", text: "\u{FB03}x", query: "f", expected: [(0, 1)]),
            Row(name: "ellipsis character is one match for a dot", text: "wait\u{2026}", query: ".", expected: [(4, 5)]),
            Row(name: "soft hyphen between spaces leaves one space", text: "a \u{00AD} b", query: "a b", expected: [(0, 5)]),
            Row(name: "empty query", text: "anything", query: "", expected: []),
            Row(name: "whitespace-only query", text: "any thing", query: " \n\t ", expected: []),
            Row(name: "empty text", text: "", query: "a", expected: []),
            Row(name: "near miss", text: "The cell divides.", query: "cells", expected: []),
            Row(name: "lookalike letter", text: "The ce11 divides.", query: "cell", expected: []),
            Row(name: "diacritic is not folded away", text: "caf\u{00E9}", query: "cafe", expected: []),
            Row(name: "punctuation in query", text: "Results (p < 0.05), n=12.", query: "(p < 0.05),", expected: [(8, 19)]),
            Row(name: "newline between words, space in query", text: "one\ntwo", query: "one two", expected: [(0, 7)]),
            Row(name: "whitespace runs between words", text: "one \n\t  two three", query: "one two", expected: [(0, 11)]),
            Row(name: "extra spaces in query", text: "one two", query: "one    two", expected: [(0, 7)]),
            Row(name: "surrounding spaces in query are ignored", text: "one two", query: "  two  ", expected: [(4, 7)]),
            Row(name: "two matches, non-overlapping", text: "aaaa", query: "aa", expected: [(0, 2), (2, 4)]),
            Row(name: "emoji before the match counts one Character", text: "\u{1F600}\u{1F600} ok", query: "ok", expected: [(3, 5)]),
        ]
        for row in rows {
            let result = ItemTextSearch.search(row.query, in: row.text)
            let got = result.matches.map { [$0.start, $0.end] }
            XCTAssertEqual(got, row.expected.map { [$0.0, $0.1] }, row.name)
            XCTAssertFalse(result.hasMore, row.name)
        }
    }

    func testOffsetsPointIntoTheOriginalTextNotTheNormalizedCopy() {
        // Ligatures, a soft hyphen, a line-end hyphen and a whitespace run all change the length of the
        // normalized copy before the match. The offsets must still index the stored text.
        let text = "\u{FB01}nd of\u{00AD}fice, hyphen-\nation and  \n  gap, target here"
        let result = ItemTextSearch.search("target", in: text)
        XCTAssertEqual(result.matches.count, 1)
        let match = result.matches[0]
        let chars = Array(text)
        XCTAssertEqual(String(chars[match.start..<match.end]), "target")
        XCTAssertEqual(match.start, chars.count - "target here".count)

        let across = ItemTextSearch.search("hyphenation", in: text).matches[0]
        XCTAssertEqual(String(chars[across.start..<across.end]), "hyphen-\nation")

        let ligature = ItemTextSearch.search("find", in: text).matches[0]
        XCTAssertEqual(String(chars[ligature.start..<ligature.end]), "\u{FB01}nd")
    }

    func testResultsCapAtOneHundredAndSayMoreExist() {
        let text = String(repeating: "word ", count: 150)
        let result = ItemTextSearch.search("word", in: text)
        XCTAssertEqual(result.matches.count, ItemTextSearch.maxMatches)
        XCTAssertTrue(result.hasMore)
        XCTAssertEqual(result.matches.last?.start, 99 * 5)

        let exactly = ItemTextSearch.search("word", in: String(repeating: "word ", count: 100))
        XCTAssertEqual(exactly.matches.count, 100)
        XCTAssertFalse(exactly.hasMore, "exactly 100 matches is not 'more'")
    }

    func testVeryLongTextFindsAMatchAtTheEnd() {
        let text = String(repeating: "lorem ipsum dolor. ", count: 100_000) + "needle at the very end"
        let result = ItemTextSearch.search("Needle at", in: text)
        XCTAssertEqual(result.matches.count, 1)
        XCTAssertEqual(result.matches[0].start, text.count - "needle at the very end".count)
    }

    func testExcerptKeepsContextAndTheMatchRange() {
        let text = "Before the line\nbreak, the quick brown fox jumps over it."
        let match = ItemTextSearch.search("quick brown", in: text).matches[0]
        XCTAssertEqual(match.excerpt, "Before the line break, the quick brown fox jumps over it.")
        let excerpt = Array(match.excerpt)
        XCTAssertEqual(String(excerpt[match.excerptMatchStart..<match.excerptMatchEnd]), "quick brown")
        XCTAssertFalse(match.excerptTruncatedBefore)
        XCTAssertFalse(match.excerptTruncatedAfter)

        let long = String(repeating: "x ", count: 100) + "needle" + String(repeating: " y", count: 100)
        let cut = ItemTextSearch.search("needle", in: long).matches[0]
        XCTAssertTrue(cut.excerptTruncatedBefore)
        XCTAssertTrue(cut.excerptTruncatedAfter)
        let cutChars = Array(cut.excerpt)
        XCTAssertEqual(String(cutChars[cut.excerptMatchStart..<cut.excerptMatchEnd]), "needle")
        XCTAssertLessThan(cutChars.count, 100)
    }

    func testMatchNamesItsChapter() {
        let text = "Intro text. Methods use a pump. Results show gain."
        let chapters = [
            Chapter(id: "c1", title: "Introduction", startChar: 0, endChar: 12, percent: 0),
            Chapter(id: "c2", title: "Methods", startChar: 12, endChar: 32, percent: 24),
            Chapter(id: "c3", title: "Results", startChar: 32, endChar: 50, percent: 64),
        ]
        let methods = ItemTextSearch.search("pump", in: text, chapters: chapters).matches[0]
        XCTAssertEqual(methods.chapterTitle, "Methods")
        let results = ItemTextSearch.search("gain", in: text, chapters: chapters).matches[0]
        XCTAssertEqual(results.chapterId, "c3")
        XCTAssertNil(ItemTextSearch.search("pump", in: text).matches[0].chapterTitle)
        // A gap between chapters falls back to the one that started before it.
        let gapped = [Chapter(id: "a", title: "Only", startChar: 0, endChar: 5, percent: 0)]
        XCTAssertEqual(ItemTextSearch.search("pump", in: text, chapters: gapped).matches[0].chapterTitle, "Only")
    }

    func testMatchInSkippedTableAndEquationIsLabelled() {
        let text = "Body says total. Table 2 | dose | 5 mg | End. E = mc2 here. Total again."
        let chars = Array(text)
        func offset(_ s: String) -> Int { text.range(of: s).map { chars.count - text[$0.lowerBound...].count } ?? -1 }
        let tableStart = offset("Table 2 |")
        let eqStart = offset("E = mc2")
        let skipped = [
            ItemTextSearch.SkippedSpan(kind: .table, start: tableStart, end: tableStart + 27, label: "Table 2"),
            ItemTextSearch.SkippedSpan(kind: .equation, start: eqStart, end: eqStart + 7),
        ]
        let dose = ItemTextSearch.search("5 mg", in: text, skipped: skipped).matches[0]
        XCTAssertEqual(dose.notReadAloudDescription, "In Table 2 (not read aloud)")
        XCTAssertEqual(dose.playbackOffset, tableStart, "seeks to the table's notice, not the cell")
        XCTAssertEqual(dose.start, offset("5 mg"))

        let equation = ItemTextSearch.search("mc2", in: text, skipped: skipped).matches[0]
        XCTAssertEqual(equation.notReadAloudDescription, "In an equation (not read aloud)")

        let all = ItemTextSearch.search("total", in: text, skipped: skipped).matches
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(all.allSatisfy { $0.notReadAloud == nil && $0.notReadAloudDescription == nil })
        XCTAssertEqual(all[0].playbackOffset, all[0].start)
    }

    func testSkippedSpansComeFromTheDocumentsTableAndEquationSegments() {
        let text = "Intro.\nTable 2\nE=mc2\nEnd."
        let document = StructuredDocument(
            extraction: .init(engine: "test", version: 2, sourceSHA256: nil, pageCount: 1, textSHA256: nil),
            text: text,
            segments: [
                .init(id: "s1", role: .body, range: .init(start: 0, length: 6)),
                .init(id: "s2", role: .table, range: .init(start: 7, length: 7), floatId: "f1"),
                .init(id: "s3", role: .equation, range: .init(start: 15, length: 5)),
                .init(id: "s4", role: .body, range: .init(start: 21, length: 4)),
            ],
            markers: [],
            floats: [.init(id: "f1", kind: .table, label: "Table 2", pageIndex: 0,
                           bounds: .init(x: 0, y: 0, width: 1, height: 1), captionSegmentId: nil, textSegmentId: "s2")])
        let spans = ItemTextSearch.SkippedSpan.spans(in: document)
        XCTAssertEqual(spans, [
            .init(kind: .table, start: 7, end: 14, label: "Table 2"),
            .init(kind: .equation, start: 15, end: 20),
        ])
        let match = ItemTextSearch.search("e=mc2", in: text, skipped: spans).matches[0]
        XCTAssertEqual(match.notReadAloud?.kind, .equation)
    }
}
