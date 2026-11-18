import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
@testable import SessionKit
@testable import SessionKitEPUB
import SessionKitTestInputs
import XCTest
import ZIPFoundation

/// #4595: a copy of a Word document with the listener's own Margins as real Word comments. These run the writer over
/// real `.docx` files written by `Fixtures/DocxComments/make-fixtures.py` from public-domain text, one file per row of
/// the issue's table (see `cases.json`): a sentence inside one run; across runs with different formatting; across a
/// hyperlink; in a table cell; in a list item; the same sentence twice; tracked changes around it; a document that
/// already has comments; smart quotes and Unicode; and a sentence not found.
///
/// For every row: each part of the copy parses as XML, there is one comment per Margin with its words and author, the
/// text between each comment's range markers is the expected sentence, the copy's visible text is the source's, and the
/// source's bytes are unchanged. The text inside a comment's range is read back by a separate `XMLParser` pass, not by
/// the writer's own byte scanner, so the two can disagree.
final class DocxCommentWriterTests: XCTestCase {
    private struct Manifest: Decodable {
        struct Case: Decodable {
            var name: String
            var file: String
            var margins: [Margin]
        }

        struct Margin: Decodable {
            var marginId: String
            var sentenceText: String
            var precedingText: String
            var commentText: String
            var expectedCommentedText: String
            var expectedSpot: String
            var expectedParagraphContains: String?
        }

        var cases: [Case]
    }

    private static let folder = TestInputs.packageURL("Tests/SessionKitCoreTests/Fixtures/DocxComments")
    private static let author = "Ada Listener"
    private static let date = Date(timeIntervalSince1970: 1_795_000_000)

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appending(path: "docx-comments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func manifest() throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: Self.folder.appending(path: "cases.json")))
    }

    // MARK: The table

    func testEveryRowOfTheTablePutsEachCommentOnItsSentence() throws {
        let cases = try manifest().cases
        XCTAssertEqual(cases.count, 10, "one fixture per row of the issue's table")
        var total = 0
        var misplaced: [String] = []
        for testCase in cases {
            let source = Self.folder.appending(path: testCase.file)
            let before = try Data(contentsOf: source)
            let output = scratch.appending(path: testCase.file)
            let requests = testCase.margins.map {
                DocxCommentWriter.Request(marginId: $0.marginId, sentenceText: $0.sentenceText, precedingText: $0.precedingText, commentText: $0.commentText)
            }
            let placements = try DocxCommentWriter.write(source: source, requests: requests, author: Self.author, date: Self.date, to: output)

            XCTAssertEqual(try Data(contentsOf: source), before, "\(testCase.name): the source is unchanged")
            let copy = try Package(url: output)
            try copy.assertEveryPartParses(testCase.name)
            XCTAssertEqual(try DocxPlainText.text(from: output), try DocxPlainText.text(from: source), "\(testCase.name): no visible text gained or lost")

            let sourceLayout = try Package(url: source).layout()
            let copyLayout = try copy.layout()
            XCTAssertEqual(copyLayout.characters, sourceLayout.characters, "\(testCase.name): every character keeps its run's formatting")
            XCTAssertEqual(copyLayout.misplacedParagraphProperties, 0, "\(testCase.name): w:pPr stays its paragraph's first child")

            let comments = try copy.comments()
            let ranges = try copy.commentedText()
            let newComments = comments.filter { $0.author == Self.author }
            XCTAssertEqual(newComments.count, testCase.margins.count, "\(testCase.name): one comment per Margin")
            XCTAssertEqual(placements.map(\.marginId), testCase.margins.map(\.marginId))

            for (index, margin) in testCase.margins.enumerated() {
                total += 1
                guard index < newComments.count else { misplaced.append("\(testCase.name)/\(margin.marginId): no comment"); continue }
                let comment = newComments[index]
                XCTAssertEqual(comment.text, margin.commentText, "\(testCase.name)/\(margin.marginId): the comment's words")
                XCTAssertEqual(comment.initials, "AL")
                XCTAssertEqual(comment.date, "2026-11-18T11:06:40Z")
                let range = ranges[comment.id]
                XCTAssertNotNil(range?.hasReference == true ? range : nil, "\(testCase.name)/\(margin.marginId): a w:commentReference follows the range")
                let spot = Self.name(of: placements[index].spot)
                var wrong = range?.text != margin.expectedCommentedText || spot != margin.expectedSpot
                if let paragraph = margin.expectedParagraphContains, range?.paragraph.contains(paragraph) != true { wrong = true }
                if wrong {
                    misplaced.append("\(testCase.name)/\(margin.marginId): \(spot) covering \(range?.text.debugDescription ?? "nothing")")
                }
            }
        }
        // The issue's stop rule: more than 1 in 10 on the wrong sentence stops the visible step.
        print("DocxCommentWriter misplacements: \(misplaced.count) of \(total)")
        XCTAssertLessThanOrEqual(misplaced.count * 10, total, "stop rule: more than 1 in 10 misplaced")
        XCTAssertEqual(misplaced, [], "every row lands on its sentence")
        XCTAssertEqual(total, 14)
    }

    func testExistingCommentsAreKeptAndNewOnesGetNewIds() throws {
        let output = scratch.appending(path: "out.docx")
        try DocxCommentWriter.write(
            source: Self.folder.appending(path: "existing-comments.docx"),
            requests: [.init(marginId: "m1", sentenceText: "It is a way I have of driving off the spleen and regulating the circulation.", commentText: "New.")],
            author: Self.author, date: Self.date, to: output
        )
        let copy = try Package(url: output)
        let comments = try copy.comments()
        XCTAssertEqual(comments.map(\.id), [0, 1])
        XCTAssertEqual(comments[0].author, "Professor")
        XCTAssertEqual(comments[0].text, "Strong opening.")
        XCTAssertEqual(try copy.commentedText()[0]?.text, "Call me Ishmael.", "the existing range is untouched")
        let rels = try copy.string("word/_rels/document.xml.rels")
        XCTAssertEqual(rels.components(separatedBy: "relationships/comments\"").count - 1, 1, "no second comments relationship")
        let types = try copy.string("[Content_Types].xml")
        XCTAssertEqual(types.components(separatedBy: "/word/comments.xml").count - 1, 1, "no second content type")
    }

    func testANewCommentsPartIsRelatedAndTyped() throws {
        let output = scratch.appending(path: "out.docx")
        try DocxCommentWriter.write(
            source: Self.folder.appending(path: "one-run.docx"),
            requests: [.init(marginId: "m1", sentenceText: "Mr. Bennet replied that he had not.", commentText: "Short.")],
            author: Self.author, date: Self.date, to: output
        )
        let copy = try Package(url: output)
        XCTAssertTrue(try copy.string("word/_rels/document.xml.rels").contains("Target=\"comments.xml\""))
        XCTAssertTrue(try copy.string("[Content_Types].xml").contains("PartName=\"/word/comments.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.comments+xml\""))
        XCTAssertEqual(try copy.comments().map(\.id), [0])
        // Every source entry is still there, in the source's order, before the new part.
        let sourceNames = try Package(url: Self.folder.appending(path: "one-run.docx")).names
        XCTAssertEqual(Array(copy.names.prefix(sourceNames.count)), sourceNames)
        XCTAssertEqual(copy.names.last, "word/comments.xml")
    }

    func testOnlyMarginsWithWordsAreWrittenFromAPlan() throws {
        let sentence = "Mr. Bennet replied that he had not."
        let plan = MarginCommentPlan(entries: [
            .init(marginId: "spoken", sentence: 0 ..< 1, sentenceText: sentence, commentText: "Said aloud.", status: .included),
            .init(marginId: "pending", sentence: 0 ..< 1, sentenceText: sentence, commentText: "", status: .transcriptPending)
        ])
        let output = scratch.appending(path: "out.docx")
        let placements = try DocxCommentWriter.write(source: Self.folder.appending(path: "one-run.docx"), plan: plan, author: Self.author, to: output)
        XCTAssertEqual(placements, [DocxMarginPlacement(marginId: "spoken", spot: .sentence(wholeSentence: true))])
        XCTAssertEqual(try Package(url: output).comments().map(\.text), ["Said aloud."])
    }

    func testAnExistingDestinationIsReplaced() throws {
        let output = scratch.appending(path: "out.docx")
        try Data("old".utf8).write(to: output)
        try DocxCommentWriter.write(source: Self.folder.appending(path: "one-run.docx"), requests: [], author: Self.author, to: output)
        XCTAssertEqual(try Package(url: output).comments().count, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), ["out.docx"], "no temporary file left behind")
    }

    func testAFileThatIsNotAWordDocumentIsRefused() throws {
        let notDocx = scratch.appending(path: "notes.docx")
        try Data("plain text".utf8).write(to: notDocx)
        XCTAssertThrowsError(try DocxCommentWriter.write(source: notDocx, requests: [], author: Self.author, to: scratch.appending(path: "out.docx"))) {
            XCTAssertEqual($0 as? DocxCommentWriter.Failure, .notADocx)
        }
    }

    func testCommentTextIsEscapedAndKeepsItsLines() {
        let element = DocxCommentWriter.commentElement(id: 3, author: "A & B", date: Self.date, text: "one <two>\nthree\u{0001}")
        XCTAssertTrue(element.contains("w:author=\"A &amp; B\""))
        XCTAssertTrue(element.contains(">one &lt;two&gt;</w:t>"))
        XCTAssertTrue(element.contains(">three</w:t>"), "a control character XML cannot carry is dropped")
        XCTAssertEqual(element.components(separatedBy: "<w:p>").count - 1, 2)
    }

    private static func name(of spot: DocxMarginPlacement.Spot) -> String {
        switch spot {
        case .sentence(let whole): return whole ? "sentence" : "sentenceStart"
        case .paragraph: return "paragraph"
        case .firstParagraph: return "firstParagraph"
        }
    }
}

// MARK: - Reading the copy back, independently of the writer

private struct Package {
    let archive: Archive
    let names: [String]

    init(url: URL) throws {
        archive = try Archive(url: url, accessMode: .read)
        names = archive.map(\.path)
    }

    func data(_ path: String) throws -> Data {
        let entry = try XCTUnwrap(archive[path], "\(path) is in the package")
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return data
    }

    func string(_ path: String) throws -> String {
        String(decoding: try data(path), as: UTF8.self)
    }

    func assertEveryPartParses(_ label: String) throws {
        for name in names where name.hasSuffix(".xml") || name.hasSuffix(".rels") {
            let parser = XMLParser(data: try data(name))
            XCTAssertTrue(parser.parse(), "\(label): \(name) parses: \(parser.parserError.map(String.init(describing:)) ?? "")")
        }
    }

    struct Comment {
        var id: Int
        var author: String
        var initials: String
        var date: String
        var text: String
    }

    func comments() throws -> [Comment] {
        guard archive["word/comments.xml"] != nil else { return [] }
        let reader = CommentsReader()
        let parser = XMLParser(data: try data("word/comments.xml"))
        parser.delegate = reader
        XCTAssertTrue(parser.parse())
        return reader.comments
    }

    struct Range {
        var text = ""
        /// The text of the paragraph the range starts in.
        var paragraph = ""
        var hasReference = false
    }

    func layout() throws -> LayoutReader {
        let reader = LayoutReader()
        let parser = XMLParser(data: try data("word/document.xml"))
        parser.delegate = reader
        XCTAssertTrue(parser.parse())
        return reader
    }

    func commentedText() throws -> [Int: Range] {
        let reader = RangeReader()
        let parser = XMLParser(data: try data("word/document.xml"))
        parser.delegate = reader
        XCTAssertTrue(parser.parse())
        return reader.finished()
    }
}

private final class CommentsReader: NSObject, XMLParserDelegate {
    var comments: [Package.Comment] = []
    private var current: Package.Comment?
    private var lines: [String] = []
    private var inText = false

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "w:comment":
            current = Package.Comment(id: Int(attributes["w:id"] ?? "") ?? -1, author: attributes["w:author"] ?? "", initials: attributes["w:initials"] ?? "", date: attributes["w:date"] ?? "", text: "")
            lines = []
        case "w:p": lines.append("")
        case "w:t": inText = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "w:t" { inText = false }
        if name == "w:comment", var comment = current {
            comment.text = lines.joined(separator: "\n")
            comments.append(comment)
            current = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText, !lines.isEmpty { lines[lines.count - 1] += string }
    }
}

/// The `w:t` text between each comment's range markers. Deleted text is `w:delText`, so it is never read.
private final class RangeReader: NSObject, XMLParserDelegate {
    private var ranges: [Int: Package.Range] = [:]
    private var open: Set<Int> = []
    private var startedIn: [Int: Int] = [:]
    private var paragraphs: [String] = []
    private var paragraphStack: [Int] = []
    private var inText = false

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        let id = Int(attributes["w:id"] ?? "")
        switch name {
        case "w:p":
            paragraphStack.append(paragraphs.count)
            paragraphs.append("")
        case "w:t": inText = true
        case "w:tab": append("\t")
        case "w:commentRangeStart":
            guard let id else { return }
            open.insert(id)
            ranges[id] = Package.Range()
            startedIn[id] = paragraphStack.last
        case "w:commentRangeEnd":
            if let id { open.remove(id) }
        case "w:commentReference":
            if let id { ranges[id]?.hasReference = true }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "w:t" { inText = false }
        if name == "w:p" {
            _ = paragraphStack.popLast()
            // A range that runs on past a paragraph's end reads the break as a space.
            if !open.isEmpty { append(" ") }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { append(string) }
    }

    private func append(_ text: String) {
        if let paragraph = paragraphStack.last { paragraphs[paragraph] += text }
        for id in open { ranges[id]?.text += text }
    }

    func finished() -> [Int: Package.Range] {
        var result = ranges
        for (id, paragraph) in startedIn {
            guard var range = result[id] else { continue }
            range.paragraph = paragraphs[paragraph]
            range.text = range.text.trimmingCharacters(in: .whitespaces)
            result[id] = range
        }
        return result
    }
}

/// Each visible character with its run's properties (as element names and attributes) and its paragraph's, so a split
/// run that dropped its formatting shows; and how many paragraphs have something before their `w:pPr`.
private final class LayoutReader: NSObject, XMLParserDelegate {
    struct Character: Equatable, CustomStringConvertible {
        var character: Swift.Character
        var run: String
        var paragraph: String
        var description: String { "\(character)[\(run)|\(paragraph)]" }
    }

    private(set) var characters: [Character] = []
    private(set) var misplacedParagraphProperties = 0
    private var stack: [String] = []
    private var runProperties = ""
    private var paragraphProperties = ""
    private var inRunProperties = false
    private var inParagraphProperties = false
    private var paragraphChildren = 0
    private var inText = false

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        let parent = stack.last
        stack.append(name)
        let described = name + attributes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        if inRunProperties { runProperties += described + ";" }
        if inParagraphProperties { paragraphProperties += described + ";" }
        if parent == "w:p" {
            paragraphChildren += 1
            if name == "w:pPr", paragraphChildren > 1 { misplacedParagraphProperties += 1 }
        }
        switch name {
        case "w:p": paragraphProperties = ""; paragraphChildren = 0
        case "w:pPr" where parent == "w:p": inParagraphProperties = true
        case "w:r": runProperties = ""
        case "w:rPr" where parent == "w:r": inRunProperties = true
        case "w:t": inText = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        stack.removeLast()
        switch name {
        case "w:pPr" where stack.last == "w:p": inParagraphProperties = false
        case "w:rPr" where stack.last == "w:r": inRunProperties = false
        case "w:t": inText = false
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inText else { return }
        for character in string { characters.append(Character(character: character, run: runProperties, paragraph: paragraphProperties)) }
    }
}
