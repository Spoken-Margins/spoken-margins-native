import Foundation
import XCTest
@testable import SessionKit

/// #2256: a system-voice play from a saved offset (a resume, a rate change, a hand-over) projected the whole remaining
/// text again on the playing thread, so the projection the open prewarmed was missed. It now takes the tail of the whole
/// projection.
final class SystemSpeechResumeProjectionTests: XCTestCase {
    override func setUp() { SpeechTextNormalizer.projectionMemo.forget() }
    override func tearDown() { SpeechTextNormalizer.projectionMemo.forget() }

    /// Long enough for the memo, with the shapes the projection rewrites: markup, links, bracket citations, runs of
    /// whitespace, CRLF, emoji, a social card and a defanged domain.
    private func article(blocks: Int = 60) -> String {
        let block = """
        Paragraph opens <b>here</b> and cites [the study](https://example.com/a/b) before it ends. See [1] and [2, 3].

        Two  spaces,\ttab\r\nand a line break   , then 😀 emoji and caf\u{E9} text. Visit meridian-protocol[.]org now.

        [

        Writer@writer

        A post body that stays audible.

        3:00 PM · Aug 11, 2026 · 29.7M Views

        1.42K Replies · 975 Reposts · 23.3K Likes

        ](https://x.com/writer/status/1)

        """
        return String(repeating: block, count: blocks)
    }

    /// What the old code did: project the remaining text on its own, then map back.
    private func projectedFromTheOffset(_ source: String, _ offset: Int) -> NormalizedSpeechText {
        let characters = Array(source)
        let start = max(0, min(offset, characters.count))
        let tail = SpeechTextNormalizer.projectForSystemSpeech(String(characters[start...]))
        return NormalizedSpeechText(
            text: tail.text,
            sourceOffsets: tail.sourceOffsets.map { start + $0 },
            sourceLength: characters.count
        )
    }

    func testAResumeProjectsNothingAgainWhenTheOpenAlreadyProjectedTheText() {
        let text = article(blocks: 160)
        XCTAssertGreaterThan(text.utf8.count, SpeechProjectionMemo.minimumBytes)
        SpeechTextNormalizer.prewarm(text, kinds: .system)
        let offset = text.count / 2
        let remaining = String(Array(text)[offset...])
        XCTAssertGreaterThan(remaining.utf8.count, SpeechProjectionMemo.minimumBytes)

        let tail = SpeechTextNormalizer.projectForSystemSpeech(text, fromSourceOffset: offset)

        XCTAssertFalse(tail.text.isEmpty)
        XCTAssertFalse(
            SpeechTextNormalizer.projectionMemo.remembers(remaining, kind: .systemSpeech),
            "a resume must take the tail of the whole projection, not project the remaining text again"
        )
        XCTAssertTrue(SpeechTextNormalizer.projectionMemo.remembers(text, kind: .systemSpeech))
    }

    /// Source offsets inside a social card: from its opening bracket to the end of its closing link.
    private func cardRanges(in text: String) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var searchFrom = text.startIndex
        while let open = text.range(of: "[\n\nWriter@writer", range: searchFrom..<text.endIndex),
              let close = text.range(of: "status/1)", range: open.upperBound..<text.endIndex) {
            ranges.append(text.distance(from: text.startIndex, to: open.lowerBound)..<text.distance(from: text.startIndex, to: close.upperBound))
            searchFrom = close.upperBound
        }
        return ranges
    }

    /// A play resumes from an offset it was told, which is the source offset of a spoken character (the voice's
    /// progress markers map to them). From each of those, the tail must say what the projection of the remaining text
    /// said. A resume from inside a social card is the one exception, because the card is rewritten as a whole: the
    /// tail of the whole projection skips the card's rest, where the remaining text alone started in the middle of it.
    func testTheTailOfTheWholeProjectionReadsAsTheProjectionOfTheRemainingText() {
        let text = article()
        let cards = cardRanges(in: text)
        XCTAssertEqual(cards.count, 60)
        let whole = SpeechTextNormalizer.projectForSystemSpeech(text)
        var offsets = Set(stride(from: 0, to: whole.sourceOffsets.count, by: whole.sourceOffsets.count / 40).map { whole.sourceOffsets[$0] })
        offsets.formUnion([0, 1, text.count - 1, text.count, text.count + 50, -5])

        var different: [Int] = []
        for offset in offsets.sorted() {
            let tail = SpeechTextNormalizer.projectForSystemSpeech(text, fromSourceOffset: offset)
            let old = projectedFromTheOffset(text, offset)
            XCTAssertEqual(tail.sourceLength, old.sourceLength)
            XCTAssertEqual(tail.text.count, tail.sourceOffsets.count)
            if cards.contains(where: { $0.contains(offset) && offset != $0.lowerBound }) {
                // Inside a card: the same article text after it, and none of the card's metadata.
                XCTAssertFalse(tail.text.contains("Views"), "offset \(offset)")
                XCTAssertFalse(tail.text.contains("Replies"), "offset \(offset)")
                XCTAssertEqual(tail.text.components(separatedBy: "Paragraph opens").dropFirst().joined(separator: "|"),
                               old.text.components(separatedBy: "Paragraph opens").dropFirst().joined(separator: "|"),
                               "offset \(offset)")
            } else if tail != old {
                different.append(offset)
            }
        }
        XCTAssertEqual(different, [], "offsets where the tail reads differently from the remaining text's own projection")
    }

    /// A resume from the middle of something the projection rewrites as a unit (a link's address) starts at the next
    /// spoken word. The remaining text alone would have read the address's tail aloud.
    func testAResumeFromInsideALinkAddressSkipsToTheNextSpokenWord() {
        let text = article()
        let address = "https://example.com/a/b"
        let open = text.range(of: address)!
        let inside = text.distance(from: text.startIndex, to: open.lowerBound) + 10
        let tail = SpeechTextNormalizer.projectForSystemSpeech(text, fromSourceOffset: inside)
        XCTAssertTrue(tail.text.hasPrefix("before it ends"), tail.text.prefix(40).description)
    }

    func testTheTailNeverStartsWithASpaceOrBeforeTheOffset() {
        let text = article()
        for offset in stride(from: 0, to: text.count, by: text.count / 40) {
            let tail = SpeechTextNormalizer.projectForSystemSpeech(text, fromSourceOffset: offset)
            XCTAssertFalse(tail.text.first?.isWhitespace ?? false, "offset \(offset)")
            XCTAssertTrue(tail.sourceOffsets.allSatisfy { $0 >= max(0, offset) }, "offset \(offset)")
        }
    }

    func testAShortTextIsProjectedFromTheOffsetAsBefore() {
        let text = "Intro 😀 read [the reference](https://example.com/path) and finish."
        XCTAssertLessThan(text.utf8.count, SpeechProjectionMemo.minimumBytes)
        for offset in 0...text.count + 2 {
            XCTAssertEqual(
                SpeechTextNormalizer.projectForSystemSpeech(text, fromSourceOffset: offset),
                projectedFromTheOffset(text, offset),
                "offset \(offset)"
            )
        }
    }

    func testAResumeAtTheEndOrPastItHasNothingToSay() {
        let text = article()
        XCTAssertTrue(SpeechTextNormalizer.projectForSystemSpeech(text, fromSourceOffset: text.count).text.isEmpty)
        XCTAssertTrue(SpeechTextNormalizer.projectForSystemSpeech(text, fromSourceOffset: text.count + 10).text.isEmpty)
    }

    /// A lead and a vowel jamo around an emoji join into one character once the emoji is dropped, so the projected
    /// text has fewer characters than offsets. A resume past the last character must not run off the text.
    func testAResumeAfterJoinedCharactersDoesNotRunOffTheText() {
        let text = String(repeating: "Plain words to pad the text out. ", count: 700) + "\u{1100}😀\u{1161}\u{1100}😀\u{1161}"
        XCTAssertGreaterThan(text.utf8.count, SpeechProjectionMemo.minimumBytes)
        let whole = SpeechTextNormalizer.projectForSystemSpeech(text)
        XCTAssertLessThan(whole.text.count, whole.sourceOffsets.count, "the case this test is about")
        for offset in [text.count - 4, text.count - 3, text.count - 2, text.count - 1, text.count, text.count + 3] {
            let tail = SpeechTextNormalizer.projectForSystemSpeech(text, fromSourceOffset: offset)
            XCTAssertEqual(tail.sourceLength, text.count)
        }
    }
}
