import Foundation
import XCTest
@testable import SessionKit

final class ExportIsolationRegressionTests: XCTestCase {
    func testEqualLengthNotesFromAnotherSessionCannotSubstituteForExportContent() throws {
        let item = Item(id: "article", title: "Article", mediaType: "text", text: "Source.", externalReference: nil, status: "ready")
        func session(_ id: String) -> Session {
            Session(id: id, itemId: item.id, status: "in_progress", phase: .itemPlayback,
                    currentTargetType: .itemTextTTS, currentTargetId: item.id,
                    position: Position(), completionPercent: 0, playbackRate: 1)
        }
        func note(_ id: String, sessionID: String, text: String) -> Interjection {
            Interjection(id: id, itemId: item.id, sessionId: sessionID, targetType: .item,
                         targetId: item.id, createdAt: Date(timeIntervalSince1970: 1), roughPercent: 0,
                         anchor: Anchor(anchorType: .text, startChar: 0, endChar: 7,
                                        anchorBefore: "Source.", anchorAfter: ""),
                         audioPath: nil, audioStatus: "none", transcriptionStatus: "transcribed",
                         transcript: text, cleanedTranscript: nil, displayText: nil, status: "active")
        }
        let first = session("session-A"), second = session("session-B")
        let firstNote = note("note-A", sessionID: first.id, text: "ALPHA private note")
        let secondNote = note("note-B", sessionID: second.id, text: "BRAVO private note")
        XCTAssertEqual(firstNote.transcript?.utf8.count, secondNote.transcript?.utf8.count)
        let repository = InMemorySessionRepository(
            items: [item.id: item], sessions: [first.id: first, second.id: second],
            interjections: [firstNote.id: firstNote, secondNote.id: secondNote])
        let engine = SessionEngine(profile: RuntimeCapabilityProfile(
            id: "export", displayName: "Export", capabilities: ["sync": ["canonical_persistence"]]),
            repository: repository)
        for (selected, included, excluded) in [(first, firstNote, secondNote), (second, secondNote, firstNote)] {
            let export = try engine.buildExport(options: ExportOptions(
                sessionId: selected.id, includeFullText: false, includeReference: true,
                includeListeningMap: false, includeInterjections: true))
            let markdown = SessionExportMarkdownRenderer.render(export)
            XCTAssertEqual(export.session.id, selected.id)
            XCTAssertEqual(export.interjections.map(\.id), [included.id])
            XCTAssertTrue(markdown.contains(try XCTUnwrap(included.transcript)))
            XCTAssertFalse(markdown.contains(try XCTUnwrap(excluded.transcript)))
        }
    }
}
