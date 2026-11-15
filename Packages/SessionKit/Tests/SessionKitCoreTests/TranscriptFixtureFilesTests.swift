import Foundation
import XCTest
import ZIPFoundation
@testable import SessionKit
@testable import SessionKitEPUB

/// #2997: writes the transcript fixtures as real files for the J15 journey. Skipped unless `WRITE_TRANSCRIPT_FIXTURES=1`.
/// The output goes to `artifacts/transcript-fixtures/` (git-ignored) under the package's repository root, or to
/// `TRANSCRIPT_FIXTURES_DIR` when set.
final class TranscriptFixtureFilesTests: XCTestCase {
    func testWriteTheFixtureFilesForTheJourney() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WRITE_TRANSCRIPT_FIXTURES"] == "1", "set WRITE_TRANSCRIPT_FIXTURES=1 to write the files")
        let out: URL
        if let dir = ProcessInfo.processInfo.environment["TRANSCRIPT_FIXTURES_DIR"] {
            out = URL(fileURLWithPath: dir, isDirectory: true)
        } else {
            // Tests/SessionKitCoreTests/<this file> up to the package, then up to the repository.
            let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            out = package.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("artifacts/transcript-fixtures", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for (name, text) in TranscriptFixtures.all {
            try Data(text.utf8).write(to: out.appendingPathComponent(name))
        }
        let essay = [
            "A short essay about nothing in particular.",
            "It has two paragraphs and no meeting in it, so Spoken Margins treats it as an ordinary document.",
        ]
        try Data(essay.joined(separator: "\n\n").utf8).write(to: out.appendingPathComponent("essay.txt"))
        try writeDocx(paragraphs: essay, to: out.appendingPathComponent("essay.docx"))
        // A Teams-style Word transcript: a title, then a speaker and time on one line and the words on the next.
        let teams = try XCTUnwrap(TranscriptFixtures.all["teams-docx.txt"])
        try writeDocx(paragraphs: teams.components(separatedBy: "\n").filter { !$0.isEmpty }, to: out.appendingPathComponent("teams-meeting.docx"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("teams-meeting.docx").path))
    }

    /// The Word files the journey writes are read the way the app reads them: the Teams-style one is a transcript, the essay is not.
    func testTheJourneysWordFilesRouteAsTheJourneyExpects() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-docx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let teams = try XCTUnwrap(TranscriptFixtures.all["teams-docx.txt"])
        let meeting = dir.appendingPathComponent("teams-meeting.docx")
        try writeDocx(paragraphs: teams.components(separatedBy: "\n").filter { !$0.isEmpty }, to: meeting)
        let essay = dir.appendingPathComponent("essay.docx")
        try writeDocx(paragraphs: ["A short essay about nothing in particular.", "It has two paragraphs and no meeting in it."], to: essay)
        let read: (Data) throws -> String = { try DocxPlainText.text(from: $0) }
        guard case .transcript(let transcript) = TranscriptFileRouter.route(
            fileName: "teams-meeting.docx", data: try Data(contentsOf: meeting), docxText: read) else {
            return XCTFail("the Teams-style Word file should be a transcript")
        }
        XCTAssertEqual(transcript.cues.count, 3)
        guard case .notTranscript = TranscriptFileRouter.route(fileName: "essay.docx", data: try Data(contentsOf: essay), docxText: read) else {
            return XCTFail("the essay should not be a transcript")
        }
    }

    private func writeDocx(paragraphs: [String], to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let body = paragraphs.map { paragraph -> String in
            let escaped = paragraph.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            let runs = escaped.components(separatedBy: "\t").map { "<w:r><w:t xml:space=\"preserve\">\($0)</w:t></w:r>" }
            return "<w:p>" + runs.joined(separator: "<w:r><w:tab/></w:r>") + "</w:p>"
        }.joined()
        let xml = Data("""
        <?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(body)</w:body></w:document>
        """.utf8)
        let archive = try Archive(url: url, accessMode: .create)
        try archive.addEntry(with: "word/document.xml", type: .file, uncompressedSize: Int64(xml.count)) { position, size in
            xml.subdata(in: Int(position)..<Int(position) + size)
        }
    }
}
