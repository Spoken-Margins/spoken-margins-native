import XCTest
@testable import SessionKit

/// What a voice is handed for math in a PDF. Phonon has no tokens for math letters and makes noise for them.
final class PDFMathSpeechTests: XCTestCase {
    private func line(_ text: String, _ role: StructuredDocument.Role = .body, page: Int = 1) -> StructuredDocumentLine {
        StructuredDocumentLine(text: text, role: role, pageIndex: page)
    }

    private func spoken(_ lines: [StructuredDocumentLine]) -> String {
        let doc = StructuredDocumentBuilder.build(lines: lines, engine: "pdfkit_baseline", version: 2, pageCount: 3)
        return SpeechTextNormalizer.normalize(StructuredDocumentSpeech.listenableText(doc).text)
    }

    private func inline(_ text: String) -> String {
        let characters = Array(text)
        let result = PDFMathSpeech.speakingInlineMath(characters, offsets: Array(characters.indices))
        return String(result.characters)
    }

    func testInlineMathIsSaidInWordsWithNoMathLettersLeft() {
        let cases: [(String, String)] = [
            ("where 𝑠and 𝑑are rates", "where S and D are rates"),
            ("that 𝐴and 𝐵grow", "that A and B grow"),
            ("share 𝛼falls", "share alpha falls"),
            ("with 𝜌≤0 here", "with rho less than or equal to 0 here"),
            ("if 𝑠𝐴−𝑑≫0 holds", "if S A minus D much greater than 0 holds"),
            ("for ℓ only", "for L only"),
            ("the ratio 𝜆/𝛽 is", "the ratio lambda over beta is"),
            ("plain words stay plain", "plain words stay plain"),
            ("café, naïve, 3.5 percent (2013)", "café, naïve, 3.5 percent (2013)"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(inline(input), expected, input)
        }
    }

    func testLongInlineMathIsSaidAsFormula() {
        XCTAssertEqual(inline("so 𝐴𝐵𝐶𝐷𝐸𝐹𝐺𝐻𝐽𝐾 holds"), "so formula holds")
    }

    func testPrivateUseGlyphsAndStrayMarksAreNeverSpoken() {
        XCTAssertFalse(inline("x \u{E230} y").unicodeScalars.contains { (0xE000...0xF8FF).contains($0.value) })
        XCTAssertFalse(inline("labor at\u{0304} rest").unicodeScalars.contains { $0.value == 0x0304 })
    }

    func testSpeakingIsIdempotentAndKeepsOffsetsInStep() {
        let characters = Array("if 𝐴and 𝛼≤0 then")
        let once = PDFMathSpeech.speakingInlineMath(characters, offsets: Array(characters.indices))
        XCTAssertEqual(once.characters.count, once.offsets.count)
        XCTAssertEqual(once.offsets, once.offsets.sorted())
        let twice = PDFMathSpeech.speakingInlineMath(once.characters, offsets: once.offsets)
        XCTAssertEqual(twice.characters, once.characters)
    }

    func testDisplayLineStoredAsBodyBecomesOneNotice() {
        let text = spoken([
            line("The production function is"),
            line("𝑌= 𝐴(𝑧𝐾)𝛼𝐿1−𝛼, 𝜃>0, (3)"),
            line("𝐾"),
            line("𝐿"),
            line("and it has constant returns."),
        ])
        XCTAssertEqual(text.components(separatedBy: "Equation not read.").count - 1, 1, text)
        XCTAssertTrue(text.contains("constant returns"), text)
        XCTAssertFalse(text.contains("theta"), text)
    }

    func testProseWithInlineMathIsNotAnEquation() {
        let lines = [
            "Let 𝐾 denote the stock of capital used in production by all firms",
            "where 𝑠 and 𝑑 are the saving and depreciation rates (3)",
            "Table 3 shows that 𝛼 rises over the sample period",
        ]
        for text in lines {
            XCTAssertFalse(spoken([line(text)]).contains("Equation not read"), text)
        }
    }

    func testAsciiEquationLineIsSkipped() {
        XCTAssertTrue(spoken([line("Y = A K + B L")]).contains("Equation not read"))
        XCTAssertFalse(spoken([line("We set a = 1 in the model below")]).contains("Equation not read"))
    }

    func testGluedFootnoteAtPageEndIsSilentAndAWordRejoinsAcrossThePage() {
        let text = spoken([
            line("The elasticity of inter-", page: 1),
            line("1Sandberg (2013) presented an overview of models.", page: 1),
            line("5", .pageFooter, page: 1),
            line("temporal substitution falls.", page: 2),
        ])
        XCTAssertFalse(text.contains("Sandberg"), text)
        XCTAssertTrue(text.contains("intertemporal"), text)
    }

    func testGluedNumberMidPageIsNotAFootnote() {
        let text = spoken([line("Results follow here.", page: 1), line("2Sandberg style line in running text.", page: 1), line("More text.", page: 1)])
        XCTAssertTrue(text.contains("Sandberg"), text)
    }

    func testPastedMathInAnyTextIsSaidInWords() {
        let text = SpeechTextNormalizer.normalize("the share 𝛼 falls")
        XCTAssertTrue(text.contains("alpha"), text)
        XCTAssertFalse(text.unicodeScalars.contains { (0x1D400...0x1D7FF).contains($0.value) }, text)
    }
}
