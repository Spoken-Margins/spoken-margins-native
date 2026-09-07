import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

final class PriorBuildPersistenceTests: XCTestCase {
    func testExternalBuild19LibraryOpensAndPreservesBothSessionsAfterReconstruction() throws {
        try checkPriorLibrary(build: 19, schema: 4)
    }

    func testInternalBuild25LibraryOpensAndPreservesBothSessionsAfterReconstruction() throws {
        try checkPriorLibrary(build: 25, schema: 5)
    }

    private func checkPriorLibrary(build: Int, schema: Int) throws {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: root.appending(path: "Contracts").path) {
            let parent = root.deletingLastPathComponent()
            guard parent != root else { throw NSError(domain: "PriorBuildFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Repository root unavailable"]) }
            root = parent
        }
        let fixture = root.appending(path: "Contracts/fixtures/persistence/build\(build).sqlite")
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let database = temporary.appending(path: "library.sqlite")
        try FileManager.default.copyItem(at: fixture, to: database)
        XCTAssertEqual(SQLiteSessionStore.schemaVersion(atPath: database.path), schema)
        do {
            let store = try SQLiteSessionStore(path: database.path)
            XCTAssertEqual(try store.loadItem(id: "prior-article").text, "The source must survive an upgrade.")
            XCTAssertEqual(Set(try store.loadSessions(itemId: "prior-article").map(\.id)), ["prior-A", "prior-B"])
            XCTAssertEqual(try store.loadSession(id: "prior-A")?.position.charOffset, 7)
            XCTAssertEqual(try store.loadSession(id: "prior-B")?.position.charOffset, 19)
            for (id, words) in [("prior-A", "ALPHA prior note"), ("prior-B", "BRAVO prior note")] {
                let notes = try store.loadInterjections(sessionId: id)
                XCTAssertEqual(notes.map(\.id), ["shared-note-id"])
                XCTAssertEqual(notes.first?.transcript, words)
            }
            var item = try store.loadItem(id: "prior-article")
            XCTAssertNil(item.sourceCompletedAt)
            item.sourceCompletedAt = Date(timeIntervalSince1970: 1234)
            try store.saveItem(item)
            var resumed = try XCTUnwrap(store.loadSession(id: "prior-A"))
            resumed.position.charOffset = 12
            try store.saveSession(resumed)
            XCTAssertEqual(try store.quarantinedRecordCount(), 0)
        }
        let reopened = try SQLiteSessionStore(path: database.path)
        XCTAssertEqual(try reopened.loadItem(id: "prior-article").sourceCompletedAt, Date(timeIntervalSince1970: 1234))
        XCTAssertEqual(try reopened.loadSession(id: "prior-A")?.position.charOffset, 12)
        XCTAssertEqual(try reopened.loadSession(id: "prior-B")?.position.charOffset, 19)
        XCTAssertEqual(try reopened.loadSession(id: "prior-A")?.playbackRate, 1.5)
        XCTAssertEqual(try reopened.loadInterjections(sessionId: "prior-A").first?.transcript, "ALPHA prior note")
        XCTAssertEqual(try reopened.loadInterjections(sessionId: "prior-B").first?.transcript, "BRAVO prior note")
        XCTAssertEqual(try reopened.quarantinedRecordCount(), 0)
    }
}
