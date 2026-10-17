import Foundation
import XCTest
@testable import SessionKit
import SessionKitTestInputs

final class ExportIsolationRegressionTests: XCTestCase {
    func testWrittenExportFixturePreservesCaptureKindAndExactTextInJSONAndMarkdown() throws {
        let fixture = try TestInputs.url(.contracts, "fixtures/exports/written-session-export.json")
        let data = try Data(contentsOf: fixture)
        let export = try JSONDecoder().decode(SessionExport.self, from: data)
        let written = try XCTUnwrap(export.interjections.first)

        XCTAssertEqual(written.captureKind, .written)
        XCTAssertEqual(written.transcript, "  Keep  this exact thought.  ")
        let markdown = SessionExportMarkdownRenderer.render(export)
        XCTAssertTrue(markdown.contains("Written Margin:\n  Keep  this exact thought."))
    }

    func testBuildExportCarriesWrittenKindWhileLegacyMissingAudioRemainsUnset() throws {
        let item = Item(id: "item-export-kind", title: "Export kind", mediaType: "text", text: "Source.", externalReference: nil, status: "ready")
        func session(_ id: String) -> Session {
            Session(id: id, itemId: item.id, status: "in_progress", phase: .itemPlayback,
                    currentTargetType: .itemTextTTS, currentTargetId: item.id,
                    position: Position(), completionPercent: 0, playbackRate: 1)
        }
        func margin(_ id: String, sessionId: String, text: String, kind: InterjectionCaptureKind?) -> Interjection {
            Interjection(
                id: id, itemId: item.id, sessionId: sessionId, targetType: .item, targetId: item.id,
                createdAt: Date(timeIntervalSince1970: 1), roughPercent: 0,
                anchor: Anchor(anchorType: .text, startChar: 0, endChar: 7, anchorBefore: "Source.", anchorAfter: ""),
                audioPath: nil, audioStatus: kind == .written ? "discarded" : "missing",
                transcriptionStatus: "transcribed", transcript: text, cleanedTranscript: nil,
                displayText: text, status: "active", captureKind: kind
            )
        }
        let writtenSession = session("session-export-written")
        let legacySession = session("session-export-legacy")
        var written = margin("written", sessionId: writtenSession.id, text: "  Exact written text.  ", kind: .written)
        written.cleanedTranscript = "Normalized text that must not replace the written Margin."
        let legacy = margin("legacy", sessionId: legacySession.id, text: "Legacy transcript.", kind: nil)
        let repository = InMemorySessionRepository(
            items: [item.id: item],
            sessions: [writtenSession.id: writtenSession, legacySession.id: legacySession],
            interjections: [written.id: written, legacy.id: legacy]
        )
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "export-kind", displayName: "Export kind", capabilities: ["sync": ["canonical_persistence"]]),
            repository: repository
        )

        let writtenExport = try engine.buildExport(options: ExportOptions(
            sessionId: writtenSession.id, includeFullText: false, includeReference: false,
            includeListeningMap: false, includeInterjections: true
        ))
        let legacyExport = try engine.buildExport(options: ExportOptions(
            sessionId: legacySession.id, includeFullText: false, includeReference: false,
            includeListeningMap: false, includeInterjections: true
        ))

        XCTAssertEqual(writtenExport.interjections.first?.captureKind, .written)
        XCTAssertEqual(writtenExport.interjections.first?.transcript, "  Exact written text.  ")
        XCTAssertNil(legacyExport.interjections.first?.captureKind)
        // The wire form says nothing either: no key a reader could take for "written" or "audio".
        let legacyWire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try XCTUnwrap(legacyExport.interjections.first)))
        XCTAssertNil((legacyWire as? [String: Any])?["captureKind"])
    }

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
