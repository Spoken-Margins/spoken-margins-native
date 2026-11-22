import Foundation
import XCTest
@testable import SessionKit

/// #5034: the Notes Folder and Readwise footers say which Margins are sent, from the same rule the writers use.
final class MarginNoteCoverageTests: XCTestCase {
    private struct Row { let name: String; let kind: InterjectionCaptureKind?; let text: String?; let notes: Bool; let readwise: Bool }

    private let table: [Row] = [
        .init(name: "written with words", kind: .written, text: "A thought.", notes: true, readwise: true),
        .init(name: "spoken with transcript", kind: .audio, text: "Heard it.", notes: true, readwise: true),
        .init(name: "spoken, words missing", kind: .audio, text: nil, notes: true, readwise: false),
        .init(name: "spoken, blank words", kind: .audio, text: " \n", notes: true, readwise: false),
        .init(name: "imported friend's Margin, kind unknown, with words", kind: nil, text: "Their view.", notes: true, readwise: true),
        .init(name: "imported friend's Margin, kind unknown, no words", kind: nil, text: nil, notes: true, readwise: false),
        .init(name: "written, empty", kind: .written, text: "", notes: false, readwise: false),
        .init(name: "written, whitespace only", kind: .written, text: "  ", notes: false, readwise: false),
    ]

    func testNotesFolderRuleTable() {
        for row in table {
            XCTAssertEqual(MarginNoteCoverage.writesNotesFolderNote(captureKind: row.kind, text: row.text), row.notes, row.name)
        }
    }

    func testReadwiseRuleTable() {
        for row in table {
            XCTAssertEqual(MarginNoteCoverage.sendsReadwiseHighlight(text: row.text), row.readwise, row.name)
        }
    }

    func testFootersSayWhatTheRuleDoes() {
        XCTAssertTrue(MarginNoteCoverage.writesNotesFolderNote(captureKind: .audio, text: nil))
        let notes = MarginNoteCoverage.notesFolderSentence
        XCTAssertTrue(notes.contains("spoken or written"), notes)
        XCTAssertTrue(notes.contains("once it\u{2019}s transcribed"), notes)
        XCTAssertFalse(notes.contains("text Margin"), notes)
        let readwise = MarginNoteCoverage.readwiseSentence
        XCTAssertTrue(readwise.contains("spoken or written"), readwise)
        XCTAssertTrue(readwise.contains("once it has words"), readwise)
    }

    /// The real writer, into a real folder: a spoken Margin with no transcript yet gets its note, then the words fill in.
    func testFirstSpokenMarginReachesARealFolderAndFillsInItsWords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("Test Vault")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func markdown(transcript: String?) throws -> String {
            let words = transcript.map { "\"\($0)\"" } ?? "null"
            let json = """
            {"schemaVersion": "spoken-margins.export.v1", "item": {"id": "item-a", "title": "Welcome", "externalReference": "https://example.com/1", "includedFullText": false},
             "session": {"id": "session-a", "status": "in_progress", "completionPercent": 10},
             "turns": [], "timeline": [],
             "interjections": [{"id": "m1", "sessionId": "session-a", "targetType": "item", "targetId": "item-a", "captureKind": "audio",
               "roughPercent": 10, "anchorBefore": "Before.", "anchorAfter": "After.", "mediaTimeMs": 5000,
               "transcriptionStatus": "\(transcript == nil ? "pending" : "transcribed")", "transcript": \(words), "audioPath": null}]}
            """
            let export = try JSONDecoder().decode(SessionExport.self, from: Data(json.utf8))
            XCTAssertTrue(MarginNoteCoverage.writesNotesFolderNote(captureKind: .audio, text: transcript))
            return SessionExportMarkdownRenderer.renderMargin(export, createdAt: Date(timeIntervalSince1970: 1_777_000_000))
        }
        let writer = AutomaticMarginWriter(journalURL: root.appendingPathComponent("journal.json"))
        _ = try await writer.deliver([.init(id: "session-a:m1", markdown: try markdown(transcript: nil))], to: folder, destinationID: "vault")
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        XCTAssertEqual(file.pathExtension, "md")
        let first = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(first.contains("Welcome") && first.contains("Transcript not available yet."), first)
        _ = try await writer.deliver([.init(id: "session-a:m1", markdown: try markdown(transcript: "Heard it."))], to: folder, destinationID: "vault")
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("Heard it."))
    }
}
