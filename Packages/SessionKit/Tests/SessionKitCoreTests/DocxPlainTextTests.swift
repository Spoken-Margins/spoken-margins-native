import Foundation
import XCTest
import ZIPFoundation
@testable import SessionKit
@testable import SessionKitEPUB

/// #2481: a Teams-style .docx transcript reads as text that `TranscriptImport` understands.
final class DocxPlainTextTests: XCTestCase {
    private func documentXML(_ paragraphs: [String]) -> Data {
        let body = paragraphs.map { paragraph in
            let runs = paragraph.components(separatedBy: "\t").map { "<w:r><w:t xml:space=\"preserve\">\($0)</w:t></w:r>" }
            return "<w:p>" + runs.joined(separator: "<w:r><w:tab/></w:r>") + "</w:p>"
        }.joined()
        return Data("""
        <?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(body)</w:body></w:document>
        """.utf8)
    }

    func testTeamsDocxReadsIntoCues() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "docx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "transcript.docx")
        let archive = try Archive(url: url, accessMode: .create)
        let xml = documentXML([
            "Budget sync-20260304_100000-Meeting Recording",
            "March 4, 2026, 10:00AM",
            "",
            "Alice Example\t0 minutes 3 seconds",
            "Welcome everyone, let's start with the budget.",
            "Ben Sample\t0 minutes 6 seconds",
            "Thanks. I have the draft numbers ready."
        ])
        try archive.addEntry(with: "word/document.xml", type: .file, uncompressedSize: Int64(xml.count)) { position, size in
            xml.subdata(in: Int(position)..<Int(position) + size)
        }
        let text = try DocxPlainText.text(from: url)
        let transcript = try TranscriptImport.parse(text: text, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(transcript.cues.map(\.speaker), ["Alice Example", "Ben Sample"])
        XCTAssertEqual(transcript.cues.map(\.startMs), [3_000, 6_000])
        XCTAssertEqual(transcript.absoluteStart, ISO8601DateFormatter().date(from: "2026-03-04T10:00:00Z"))
    }

    func testNonDocxFails() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "not-\(UUID().uuidString).docx")
        try Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try DocxPlainText.text(from: url))
    }
}
