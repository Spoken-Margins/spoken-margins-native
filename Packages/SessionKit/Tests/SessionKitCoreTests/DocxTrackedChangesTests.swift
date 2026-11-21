import Foundation
import XCTest
import ZIPFoundation
@testable import SessionKit
@testable import SessionKitEPUB

/// #4594 audit: a Word document reads as Word shows it with every tracked change accepted. Each row is a real `.docx`
/// built here (a zip of `word/document.xml` and `word/styles.xml`), so the parser sees the bytes Word writes.
final class DocxTrackedChangesTests: XCTestCase {
    private static let w = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\""

    /// Heading 1 is a localized id, so a row that reads it by id alone would fail; Heading 2 keeps Word's English id.
    private static let styles = """
    <?xml version="1.0" encoding="UTF-8"?><w:styles \(w)>\
    <w:style w:type="paragraph" w:styleId="Normal"><w:name w:val="Normal"/></w:style>\
    <w:style w:type="paragraph" w:styleId="berschrift1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/>\
    <w:pPr><w:outlineLvl w:val="0"/></w:pPr></w:style>\
    <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/>\
    <w:pPr><w:outlineLvl w:val="1"/></w:pPr></w:style>\
    <w:style w:type="paragraph" w:styleId="Promoted"><w:name w:val="Promoted"/><w:basedOn w:val="Normal"/>\
    <w:pPr><w:outlineLvl w:val="0"/>\
    <w:pPrChange w:id="90" w:author="A"><w:pPr><w:outlineLvl w:val="2"/></w:pPr></w:pPrChange></w:pPr></w:style>\
    <w:style w:type="paragraph" w:styleId="Demoted"><w:name w:val="Demoted"/><w:basedOn w:val="Normal"/>\
    <w:pPr><w:pPrChange w:id="91" w:author="A"><w:pPr><w:outlineLvl w:val="0"/></w:pPr></w:pPrChange></w:pPr></w:style>\
    </w:styles>
    """

    private func paragraphs(_ body: String) throws -> [DocumentParagraph] {
        let document = Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:document \(Self.w)><w:body>\(body)</w:body></w:document>".utf8)
        let archive = try Archive(data: Data(), accessMode: .create)
        for (path, data) in [("word/document.xml", document), ("word/styles.xml", Data(Self.styles.utf8))] {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        return try DocxPlainText.paragraphs(from: try XCTUnwrap(archive.data)).paragraphs
    }

    private func change(_ inner: String) -> String {
        "<w:pPrChange w:id=\"5\" w:author=\"A\" w:date=\"2026-11-20T00:00:00Z\"><w:pPr>\(inner)</w:pPr></w:pPrChange>"
    }

    /// One row per neighbouring input: the paragraph's XML, then the text and heading level Word shows once the change
    /// is accepted.
    func testEachTrackedChangeReadsAsAccepted() throws {
        let rows: [(name: String, xml: String, text: String, level: Int?)] = [
            ("heading 1 changed to Normal (Word drops pStyle for Normal)",
             "<w:p><w:pPr>\(change("<w:pStyle w:val=\"berschrift1\"/>"))</w:pPr><w:r><w:t>Old Section</w:t></w:r></w:p>",
             "Old Section", nil),
            ("heading 2 changed to heading 1: the old style comes after the new",
             "<w:p><w:pPr><w:pStyle w:val=\"berschrift1\"/>\(change("<w:pStyle w:val=\"Heading2\"/>"))</w:pPr><w:r><w:t>Promoted</w:t></w:r></w:p>",
             "Promoted", 2),
            ("normal changed to heading 2",
             "<w:p><w:pPr><w:pStyle w:val=\"Heading2\"/>\(change(""))</w:pPr><w:r><w:t>New Section</w:t></w:r></w:p>",
             "New Section", 3),
            ("paragraph outline level removed under tracking",
             "<w:p><w:pPr>\(change("<w:outlineLvl w:val=\"0\"/>"))</w:pPr><w:r><w:t>Was an outline</w:t></w:r></w:p>",
             "Was an outline", nil),
            ("paragraph outline level changed from 0 to 1",
             "<w:p><w:pPr><w:outlineLvl w:val=\"1\"/>\(change("<w:outlineLvl w:val=\"0\"/>"))</w:pPr><w:r><w:t>Now level one</w:t></w:r></w:p>",
             "Now level one", 3),
            ("old properties hold a tab stop, which is not a tab in the text",
             "<w:p><w:pPr>\(change("<w:tabs><w:tab w:val=\"left\" w:pos=\"720\"/></w:tabs>"))</w:pPr><w:r><w:t>No tab</w:t></w:r></w:p>",
             "No tab", nil),
            ("run formatting changed (rPrChange)",
             "<w:p><w:r><w:rPr><w:b/><w:rPrChange w:id=\"6\" w:author=\"A\"><w:rPr/></w:rPrChange></w:rPr><w:t>Bold now</w:t></w:r></w:p>",
             "Bold now", nil),
            ("paragraph mark formatting changed (pPr/rPr/rPrChange)",
             "<w:p><w:pPr><w:pStyle w:val=\"Heading2\"/><w:rPr><w:i/><w:rPrChange w:id=\"7\" w:author=\"A\"><w:rPr/></w:rPrChange></w:rPr></w:pPr><w:r><w:t>Mark</w:t></w:r></w:p>",
             "Mark", 3),
            ("inserted text",
             "<w:p><w:r><w:t xml:space=\"preserve\">our </w:t></w:r><w:ins w:id=\"8\" w:author=\"A\"><w:r><w:t>fathers</w:t></w:r></w:ins></w:p>",
             "our fathers", nil),
            ("deleted text",
             "<w:p><w:r><w:t xml:space=\"preserve\">our </w:t></w:r><w:del w:id=\"9\" w:author=\"A\"><w:r><w:delText>grand</w:delText></w:r></w:del><w:r><w:t>fathers</w:t></w:r></w:p>",
             "our fathers", nil),
            ("moved text is read where it went",
             "<w:p><w:moveFrom w:id=\"10\" w:author=\"A\"><w:r><w:t>Moved.</w:t></w:r></w:moveFrom><w:r><w:t>Stays.</w:t></w:r><w:moveTo w:id=\"11\" w:author=\"A\"><w:r><w:t>Moved.</w:t></w:r></w:moveTo></w:p>",
             "Stays.Moved.", nil),
            ("runs nested in a hyperlink and a smart tag",
             "<w:p><w:hyperlink><w:r><w:t xml:space=\"preserve\">link </w:t></w:r></w:hyperlink><w:smartTag><w:r><w:t>tag</w:t></w:r></w:smartTag></w:p>",
             "link tag", nil),
            ("inserted paragraph mark (pPr/rPr/ins)",
             "<w:p><w:pPr><w:rPr><w:ins w:id=\"12\" w:author=\"A\"/></w:rPr></w:pPr><w:r><w:t>Inserted mark</w:t></w:r></w:p>",
             "Inserted mark", nil),
            ("empty paragraph", "<w:p/>", "", nil),
            ("heading 2 by Word's English id", "<w:p><w:pPr><w:pStyle w:val=\"Heading2\"/></w:pPr><w:r><w:t>By id</w:t></w:r></w:p>", "By id", 3),
            ("heading 1 by a localized id, found by its style's name and level",
             "<w:p><w:pPr><w:pStyle w:val=\"berschrift1\"/></w:pPr><w:r><w:t>By name</w:t></w:r></w:p>", "By name", 2),
            ("a style whose outline level changed under tracking keeps the new level",
             "<w:p><w:pPr><w:pStyle w:val=\"Promoted\"/></w:pPr><w:r><w:t>Style promoted</w:t></w:r></w:p>", "Style promoted", 2),
            ("a style whose outline level was removed under tracking is body text",
             "<w:p><w:pPr><w:pStyle w:val=\"Demoted\"/></w:pPr><w:r><w:t>Style demoted</w:t></w:r></w:p>", "Style demoted", nil),
        ]
        for row in rows {
            let read = try paragraphs(row.xml)
            XCTAssertEqual(read, [DocumentParagraph(text: row.text, headingLevel: row.level)], row.name)
        }
    }

    /// The rows together in one body: a skipped block must not leak into the paragraphs around it.
    func testSkippedOldPropertiesDontLeakIntoNeighbouringParagraphs() throws {
        let read = try paragraphs(
            "<w:p><w:pPr>\(change("<w:pStyle w:val=\"berschrift1\"/>"))</w:pPr><w:r><w:t>Body</w:t></w:r></w:p>"
            + "<w:p><w:pPr><w:pStyle w:val=\"Heading2\"/></w:pPr><w:r><w:t>Chapter</w:t></w:r></w:p>"
            + "<w:p><w:r><w:t>After</w:t></w:r></w:p>")
        XCTAssertEqual(read, [
            DocumentParagraph(text: "Body"), DocumentParagraph(text: "Chapter", headingLevel: 3), DocumentParagraph(text: "After"),
        ])
    }
}
