import XCTest
import PDFKit
import SessionKit
@testable import SpokenMarginsApp

/// TEMPORARY diagnostic for #4588 (removed before the PR is armed): dumps what the extractor sees on arXiv
/// 2608.09666v1 page 4, the Test Desk's real input.
final class Diag4588Tests: XCTestCase {
    func testDumpArxivPage4() async throws {
        let url = URL(string: "https://arxiv.org/pdf/2608.09666v1")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("diag4588.pdf")
        try data.write(to: file)
        let document = try XCTUnwrap(PDFDocument(url: file))
        let page = try XCTUnwrap(document.page(at: 3))
        var out = ["DIAG4588 BEGIN pdfkit lines"]
        if let selection = page.selection(for: page.bounds(for: .cropBox)) {
            for piece in selection.selectionsByLine() {
                let b = piece.bounds(for: page)
                let text = (piece.string ?? "").replacingOccurrences(of: "\n", with: " ")
                out.append(String(format: "PK y%.0f-%.0f x%.0f-%.0f ", b.minY, b.maxY, b.minX, b.maxX) + String(text.prefix(50)))
            }
        }
        out.append("DIAG4588 structured lines")
        let lines = try PDFStructuredTextExtractor.structuredLines(from: document)
        for line in lines where line.pageIndex == 3 {
            let b = line.bounds.map { String(format: " y%.3f-%.3f", $0.y, $0.y + $0.height) } ?? ""
            out.append("SL \(line.role.rawValue)\(b) " + String(line.text.prefix(50)))
        }
        let doc = try PDFStructuredTextExtractor.structuredDocument(from: file)
        for float in doc.floats where float.pageIndex == 3 {
            out.append("FLOAT \(float.id) \(float.kind.rawValue) text=\(float.textSegmentId ?? "-")")
        }
        if let source = PDFClipSource(document: doc, text: doc.text) {
            for anchor in PDFClipAnchors.make(text: doc.text, source: source) where anchor.pageNumber == 4 {
                let at = doc.text.index(doc.text.startIndex, offsetBy: anchor.anchor)
                out.append("ANCHOR \(anchor.floatId) \(PDFClipLabel.accessibilityLabel(anchor)) caption=\(anchor.hasCaption) at: " + String(doc.text[at...].prefix(40)))
            }
        }
        out.append("DIAG4588 END")
        let dump = out.joined(separator: "\n")
        print(dump)
        let attachment = XCTAttachment(string: dump)
        attachment.lifetime = .keepAlways
        add(attachment)
        let roles = lines.filter { $0.pageIndex == 3 }.map(\.role.rawValue)
        let anchors = out.filter { $0.hasPrefix("ANCHOR") || $0.hasPrefix("FLOAT") }.joined(separator: " | ")
        XCTFail("DIAG4588 roles: " + Dictionary(grouping: roles, by: { $0 }).map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: ",") + " " + String(anchors.prefix(220)))
    }
}
