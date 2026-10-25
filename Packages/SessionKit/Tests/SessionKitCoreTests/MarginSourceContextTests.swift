import Foundation
import XCTest
@testable import SessionKit

/// #2482: on arXiv 1706.03762 a written Margin made in "Abstract · paragraph 7" showed the title page's author block as
/// its context. A paper's front matter is a run of lines with no sentence-ending punctuation, so the sentence shoulder
/// saved with the Margin reaches back through it into the permission notice. The context showed the first 600
/// characters of that shoulder, which is the far end of it, and the passage never appeared.
final class MarginSourceContextTests: XCTestCase {
    private let profile = RuntimeCapabilityProfile(
        id: "phone-tablet-online", displayName: "Phone/Tablet Online",
        capabilities: [
            "sync": ["canonical_persistence"],
            "playback": ["realtime_tts"],
            "interjection": ["record_audio", "capture_text_anchor"]
        ]
    )

    private final class Reader: AudioPlaybackClient {
        var charOffset: Int?
        func prepareSpeechText(_ text: String) throws -> String { text }
        func play(targetId: String) throws {}
        func play(targetId: String, from charOffset: Int) throws { self.charOffset = charOffset }
        func pause() throws {}
        func currentCharOffset() -> Int? { charOffset }
        func currentPlaybackPosition() -> PlaybackPosition? {
            charOffset.map { PlaybackPosition(textStart: $0, textEnd: $0 + 1, anchorConfidence: .textRange) }
        }
    }

    private final class Microphone: RecordingClient {
        func beginRecording() throws {}
        func cancelRecording() throws {}
        func finishRecording(audioRef: String?) throws -> String { "interjections/test.m4a" }
    }

    private let notice = "Provided proper attribution is provided, Google hereby grants permission to reproduce the tables and figures in this paper solely for use in journalistic or scholarly works."
    private let abstractParagraph = "The dominant sequence transduction models are based on complex recurrent or convolutional neural networks in an encoder-decoder configuration. The best performing models also connect the encoder and decoder through an attention mechanism."

    /// Page 1 as the app's extractor reads it: the notice, the title, then each author's name, affiliation and email as
    /// its own line with no full stop, then the Abstract.
    private func paperText() -> String {
        var lines = [notice, "Attention Is All You Need"]
        for number in 1...8 {
            lines += ["Author Number\(number)", "Research Institute \(number)", "author\(number)@example.com"]
        }
        lines += ["Abstract", abstractParagraph, "1 Introduction", "Recurrent neural networks have been firmly established."]
        return lines.joined(separator: "\n")
    }

    private func writtenMargin(atOffset offset: Int, in text: String) throws -> Anchor {
        let item = Item(id: "paper", title: "Paper", mediaType: "text", text: text, externalReference: nil, status: "ready")
        let reader = Reader()
        let engine = SessionEngine(
            profile: profile, repository: InMemorySessionRepository(items: [item.id: item]), audio: reader, recorder: Microphone())
        _ = try engine.startSession(itemId: item.id)
        reader.charOffset = offset
        let capture = try engine.beginWrittenInterjection()
        return capture.anchor
    }

    func testAMarginInTheAbstractShowsTheAbstractNotTheAuthorBlock() throws {
        let text = paperText()
        let start = (text as NSString).range(of: abstractParagraph).location
        let anchor = try writtenMargin(atOffset: start, in: text)

        let context = try XCTUnwrap(MarginCollection.sourceContext(anchorBefore: anchor.anchorBefore, anchorAfter: anchor.anchorAfter))

        XCTAssertFalse(anchor.anchorBefore.contains("Author Number"), anchor.anchorBefore)
        XCTAssertFalse(context.contains("@example.com"), context)
        XCTAssertTrue(context.hasPrefix(abstractParagraph.prefix(80)), context)
    }

    func testALineThatEndsNoSentenceStopsTheShoulder() throws {
        // Lines that end a sentence stay in the shoulder across paragraph breaks; the heading before them does not.
        let text = "Some heading\nThe first paragraph ends here. It has two sentences.\nThe second paragraph starts here. Then it goes on."
        let start = (text as NSString).range(of: "Then it goes on").location
        let anchor = try writtenMargin(atOffset: start, in: text)

        XCTAssertEqual(anchor.anchorBefore, "The first paragraph ends here. It has two sentences.\nThe second paragraph starts here.")
        XCTAssertEqual(anchor.anchorAfter, "Then it goes on.")
    }

    func testProseKeepsItsShoulderAcrossParagraphBreaks() throws {
        let text = "One sentence here.\nAnother one follows.\nThe margin goes here. And it continues."
        let start = (text as NSString).range(of: "The margin goes here").location
        let anchor = try writtenMargin(atOffset: start, in: text)

        XCTAssertEqual(anchor.anchorBefore, "One sentence here.\nAnother one follows.")
    }

    func testTheRowsParagraphNumberAndTheContextNameTheSamePassage() throws {
        let text = paperText()
        let start = (text as NSString).range(of: abstractParagraph).location
        let anchor = try writtenMargin(atOffset: start, in: text)
        let index = MarginPlaceIndex(chapters: [], text: text)
        let paragraph = try XCTUnwrap(index.paragraph(atChar: anchor.startChar))
        let lines = text.components(separatedBy: "\n")

        let context = try XCTUnwrap(MarginCollection.sourceContext(anchorBefore: anchor.anchorBefore, anchorAfter: anchor.anchorAfter))

        XCTAssertEqual(lines[paragraph - 1], abstractParagraph, "paragraph \(paragraph) is the passage")
        XCTAssertTrue(context.contains(lines[paragraph - 1]), context)
    }

    func testHardWrappedProseKeepsItsShoulder() throws {
        let text = "First sentence of the book. Second one follows it. It was the best of\ntimes, it was the worst.\nWe went on."
        let start = (text as NSString).range(of: "We went on").location
        let anchor = try writtenMargin(atOffset: start, in: text)

        XCTAssertEqual(anchor.anchorBefore, "First sentence of the book. Second one follows it. It was the best of\ntimes, it was the worst.")
    }

    func testLinesEndingInOtherSentencePunctuationAreSentences() throws {
        for ending in [":", "…", "。", "！", "»", "—"] {
            let text = "Opening words\(ending)\nThe passage starts here. And goes on."
            let start = (text as NSString).range(of: "The passage").location
            let anchor = try writtenMargin(atOffset: start, in: text)
            XCTAssertEqual(anchor.anchorBefore, "Opening words\(ending)", ending)
        }
    }

    /// #2527: a PDF's lines are cut at the page's width, so a sentence can run on to a line that starts in capitals.
    func testHardWrappedPDFLinesKeepTheirShoulderWhateverTheNextLineStartsWith() throws {
        let rows: [(name: String, text: String, kept: String)] = [
            ("capital after a function word",
             "Title Line\nThe dominant models rely on a new simple network architecture, the\nTransformer, based solely on attention mechanisms. We went on.",
             "The dominant models rely on a new simple network architecture, the\nTransformer, based solely on attention mechanisms."),
            ("capital after a hyphenated break",
             "Title Line\nThe dominant models rely on state-of-the-\nArt systems that were tuned by hand. We went on.",
             "The dominant models rely on state-of-the-\nArt systems that were tuned by hand."),
            ("capital after a comma on a long line",
             "Title Line\nThe dominant models rely on a new simple network architecture, as shown before,\nGoogle Brain later did the same. We went on.",
             "The dominant models rely on a new simple network architecture, as shown before,\nGoogle Brain later did the same."),
            ("a footnote number after the full stop",
             "Title Line\nThe dominant models rely on a new network architecture, as noted.1\nAnother sentence follows it here. We went on.",
             "The dominant models rely on a new network architecture, as noted.1\nAnother sentence follows it here."),
            ("an indented continuation on the Margin's own line",
             "Title Line\nThe dominant models rely on a new simple network architecture that\n   works well in practice. We went on.",
             "The dominant models rely on a new simple network architecture that\n   works well in practice."),
        ]
        for row in rows {
            let start = (row.text as NSString).range(of: "We went on").location
            let anchor = try writtenMargin(atOffset: start, in: row.text)
            XCTAssertEqual(anchor.anchorBefore, row.kept, row.name)
        }
    }

    func testAHeadingBeforeWrappedProseStillEndsTheShoulder() throws {
        let rows = [
            "Attention Is All You Need",
            "1 Introduction",
            "Abstract",
            "author@example.com",
            // A short heading can end in a function word or a hyphen; only a line near the page's width runs on.
            "Who This Is For",
            "Who We Are",
            "Turn It On",
            "Notes -",
            // A section number ends in a digit after a full stop, but it is no footnote.
            "Table 3.1",
            "Version 2.0",
            "Appendix A.1",
        ]
        for heading in rows {
            let text = "\(heading)\nThe dominant models rely on a new simple network architecture, the\nTransformer, based on attention. We went on."
            let start = (text as NSString).range(of: "We went on").location
            let anchor = try writtenMargin(atOffset: start, in: text)
            XCTAssertEqual(
                anchor.anchorBefore,
                "The dominant models rely on a new simple network architecture, the\nTransformer, based on attention.", heading)
        }
    }

    /// #2527: a short line before one that starts with a digit or a bracket stays a heading, as a numbered heading
    /// follows a short line the same way.
    func testAShortLineBeforeADigitOrBracketIsAHeading() throws {
        for opening in ["2 The next part starts here.", "[3] The next part starts here."] {
            let text = "Short line here\n\(opening) We went on."
            let start = (text as NSString).range(of: "We went on").location
            let anchor = try writtenMargin(atOffset: start, in: text)
            XCTAssertEqual(anchor.anchorBefore, opening, opening)
        }
    }

    /// #2527: a Margin made at the very start of a wrapped line still reads that line's first letter.
    func testAMarginAtTheStartOfAContinuationLineKeepsItsShoulder() throws {
        let wrapped = "The dominant sequence transduction models are based on complex recurrent"
        for indent in ["", "   "] {
            let text = "Intro sentence ends here.\n\(wrapped)\n\(indent)neural networks that include an encoder. We went on."
            let start = (text as NSString).range(of: "\n\(indent)neural").location + 1 + indent.count
            let anchor = try writtenMargin(atOffset: start, in: text)
            XCTAssertEqual(anchor.anchorBefore, "Intro sentence ends here.\n\(wrapped)", "indent \(indent.count)")
        }
    }

    func testTheShoulderOfALongTextIsFourSentencesAndTheScanStopsAtTheirStart() throws {
        let sentences = (1...400).map { "Sentence number \($0) ends here." }
        let text = sentences.joined(separator: "\n")
        let start = (text as NSString).range(of: "Sentence number 399").location
        let anchor = try writtenMargin(atOffset: start, in: text)

        XCTAssertEqual(anchor.anchorBefore, sentences[394...397].joined(separator: "\n"))
    }
}
