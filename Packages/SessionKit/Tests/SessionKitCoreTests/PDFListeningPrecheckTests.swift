import XCTest
@testable import SessionKit

/// Pins the Swift pre-check to its reference, research/C1/tools/precheck.py.
/// Every expected value below was produced by the Python reference
/// (`text_features` plus the fitted rule); research/C1/tools/test_precheck.py
/// checks the same cases on that side. Change both together.
final class PDFListeningPrecheckTests: XCTestCase {
    private struct Case {
        var name: String
        var text: String?
        var pages: Int
        var wordsPerPage: Double
        var singleLetterShare: Double
        var reasons: [PDFListeningPrecheck.Reason]
    }

    private let cases: [Case] = [
        Case(name: "prose", text: String(repeating: "Listening is slower than reading but it fits. ", count: 20), pages: 2,
             wordsPerPage: 80.0, singleLetterShare: 0.0, reasons: []),
        Case(name: "math", text: String(repeating: "Let x be in X and let f map x to y where y is in Y. ", count: 10), pages: 1,
             wordsPerPage: 170.0, singleLetterShare: 0.4118, reasons: [.mathHeavy]),
        Case(name: "empty", text: "", pages: 3,
             wordsPerPage: 0.0, singleLetterShare: 0.0, reasons: [.noTextLayer]),
        Case(name: "no extracted text", text: nil, pages: 3,
             wordsPerPage: 0.0, singleLetterShare: 0.0, reasons: [.noTextLayer]),
        Case(name: "articles are words, not variables", text: String(repeating: "I have a cat and A dog. ", count: 10), pages: 1,
             wordsPerPage: 70.0, singleLetterShare: 0.0, reasons: []),
        Case(name: "greek letters count, digits and symbols don't", text: String(repeating: "Die Größe α ist 3 × β. ", count: 10), pages: 1,
             wordsPerPage: 60.0, singleLetterShare: 0.3333, reasons: [.mathHeavy]),
        Case(name: "combining accent ends a token", text: String(repeating: "cafe\u{301} au lait ", count: 10), pages: 1,
             wordsPerPage: 30.0, singleLetterShare: 0.0, reasons: []),
        Case(name: "at the math threshold", text: String(repeating: "x ", count: 131) + String(repeating: "word ", count: 1869), pages: 1,
             wordsPerPage: 2000.0, singleLetterShare: 0.0655, reasons: [.mathHeavy]),
        Case(name: "just below the math threshold", text: String(repeating: "x ", count: 130) + String(repeating: "word ", count: 1870), pages: 1,
             wordsPerPage: 2000.0, singleLetterShare: 0.065, reasons: []),
        Case(name: "twenty words a page is no text layer", text: String(repeating: "word ", count: 20), pages: 1,
             wordsPerPage: 20.0, singleLetterShare: 0.0, reasons: [.noTextLayer]),
        Case(name: "twenty-one words a page is text", text: String(repeating: "word ", count: 21), pages: 1,
             wordsPerPage: 21.0, singleLetterShare: 0.0, reasons: []),
    ]

    func testMatchesTheCorpusReference() {
        for testCase in cases {
            let result = PDFListeningPrecheck.evaluate(extractedText: testCase.text, pageCount: testCase.pages)
            XCTAssertEqual(result.wordsPerPage, testCase.wordsPerPage, testCase.name)
            XCTAssertEqual(result.singleLetterShare, testCase.singleLetterShare, testCase.name)
            XCTAssertEqual(result.reasons, testCase.reasons, testCase.name)
            XCTAssertEqual(result.isHard, !testCase.reasons.isEmpty, testCase.name)
        }
    }

    func testZeroPagesDoesNotDivideByZero() {
        let result = PDFListeningPrecheck.evaluate(extractedText: String(repeating: "word ", count: 50), pageCount: 0)
        XCTAssertEqual(result.wordsPerPage, 50.0)
        XCTAssertFalse(result.isHard)
    }

    func testReasonsUseTheI13QualityVocabulary() {
        // structured-document.v1 `quality.reasons` (research/C1/I13) uses these strings.
        XCTAssertEqual(PDFListeningPrecheck.Reason.noTextLayer.rawValue, "no_text_layer")
        XCTAssertEqual(PDFListeningPrecheck.Reason.mathHeavy.rawValue, "math_heavy")
    }
}
