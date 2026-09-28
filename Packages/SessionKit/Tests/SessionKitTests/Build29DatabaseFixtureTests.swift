import CryptoKit
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// Writes a database with the current code for scripts/check-build29-database.sh,
/// which opens it with Build 29's own persistence code (the owner's condition for
/// storing I13 documents, #191). Run alone it writes to a temporary file and checks
/// that the current code reads it back.
final class Build29DatabaseFixtureTests: XCTestCase {
    func testWritesV1AndV2PDFItemsWithMarginsForTheBuild29Reader() throws {
        let environment = ProcessInfo.processInfo.environment
        let path = environment["SM_BUILD29_DB"]
            ?? FileManager.default.temporaryDirectory.appending(path: "build29-\(UUID().uuidString).sqlite").path
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        let store = try SQLiteSessionStore(path: path)
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "pdf", displayName: "PDF", capabilities: ["sync": ["canonical_persistence"]]),
            repository: store
        )
        let v1 = try engine.importBrowserTextInBackground(BrowserTextHandoff(
            captureMode: .markdownFile,
            source: BrowserTextSource(url: "shared-file://share-sheet/Old.pdf", title: "Old"),
            text: "# Old paper\n\n## Methods\n\nImported before extraction v2.",
            contentFormat: .markdown
        ))
        let document = StructuredDocumentBuilder.build(lines: [
            StructuredDocumentLine(text: "Methods", role: .heading, pageIndex: 0, level: 2),
            StructuredDocumentLine(text: "Imported with extraction v2 [3].", role: .body, pageIndex: 0),
            StructuredDocumentLine(text: "References", role: .heading, pageIndex: 1, level: 2),
            StructuredDocumentLine(text: "[3] A. Author. Title. 2020.", role: .reference, pageIndex: 1),
        ], engine: "pdfkit_baseline", version: 2, pageCount: 2)
        let v2 = try engine.importBrowserTextInBackground(BrowserTextHandoff(
            captureMode: .markdownFile,
            source: BrowserTextSource(url: "shared-file://share-sheet/New.pdf", title: "New"),
            text: "unused",
            contentFormat: .markdown
        ), structuredDocument: document)

        var expected: [[String: Any]] = []
        for item in [v1, v2] {
            let text = try XCTUnwrap(item.text)
            let session = Session(id: "session-\(item.id)", itemId: item.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(charOffset: 3), completionPercent: 10, playbackRate: 1)
            try store.saveSession(session)
            let margin = Interjection(
                id: "margin-\(item.id)", itemId: item.id, sessionId: session.id, targetType: .item, targetId: item.id,
                createdAt: Date(timeIntervalSince1970: 1), roughPercent: 10,
                anchor: Anchor(anchorType: .text, startChar: 0, endChar: min(8, text.count), anchorBefore: "", anchorAfter: ""),
                audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: nil, cleanedTranscript: nil,
                displayText: "A written Margin", status: "active"
            )
            try store.saveInterjection(margin)
            expected.append([
                "itemId": item.id,
                "textSHA256": SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined(),
                "sessionId": session.id,
                "marginId": margin.id,
                "hasListeningMap": try store.loadListeningMap(itemId: item.id) != nil,
            ])
        }
        XCTAssertNil(try store.loadStructuredDocument(itemId: v1.id))
        XCTAssertEqual(try store.loadStructuredDocument(itemId: v2.id), document)
        XCTAssertEqual(SQLiteSessionStore.schemaVersion(atPath: path), 5)
        let data = try JSONSerialization.data(withJSONObject: ["items": expected], options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: path + ".expected.json"))
        if environment["SM_BUILD29_DB"] == nil {
            for suffix in ["", "-wal", "-shm", ".expected.json"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
    }
}
