import Foundation
import SessionKit
import SessionKitPersistence
import ShippedPacketReader
import SQLite3
import XCTest

/// A paper saved with its citation (#206) must still open in Build 29, whose `Item` has no
/// `bibliography`: the database Build 29 opens must keep working (AGENTS.md).
final class PDFBibliographyBuild29Tests: XCTestCase {
    func testBuild29DecodesAPaperSavedWithItsBibliography() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PDFBibliographyBuild29-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("library.sqlite").path
        let store = try SQLiteSessionStore(path: path)
        let bibliography = PDFBibliography(
            doi: "10.1145/3613904.3642123", arxivId: "2607.28282",
            authors: ["Ada Lovelace", "Charles Babbage"], year: 2024, title: "Listening"
        )
        try store.saveItem(Item(
            id: "item-paper", title: "A Paper", mediaType: "pdf", text: "A Paper\nBody.",
            externalReference: "a-paper.pdf", status: "ready", externalReferenceType: "file",
            documentStructure: PDFDocumentStructure(
                extractionEngine: .pdfKit, analysisStatus: .partial, pageCount: 2, analyzedPageCount: 0,
                bibliography: bibliography
            )
        ))

        XCTAssertEqual(try store.loadItem(id: "item-paper").documentStructure?.bibliography, bibliography)
        let payload = try storedPayload(path, kind: "item", id: "item-paper")
        // JSONEncoder writes "/" as "\/", so look for the key and the DOI's slash-free part.
        let stored = String(decoding: payload, as: UTF8.self)
        XCTAssertTrue(stored.contains("\"bibliography\"") && stored.contains("3613904.3642123"), stored)
        XCTAssertEqual(try ShippedPacketReader.decodeStoredRecord(kind: "item", payload: payload), "item-paper")
    }

    private func storedPayload(_ path: String, kind: String, id: String) throws -> Data {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw SessionKitError.persistenceFailed("open") }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, payload FROM records WHERE kind = ?;", -1, &statement, nil) == SQLITE_OK else {
            throw SessionKitError.persistenceFailed("prepare")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, kind, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        while sqlite3_step(statement) == SQLITE_ROW {
            if String(cString: sqlite3_column_text(statement, 0)!).hasSuffix(id) {
                return Data(String(cString: sqlite3_column_text(statement, 1)!).utf8)
            }
        }
        throw SessionKitError.persistenceFailed("no \(kind) record \(id)")
    }
}
