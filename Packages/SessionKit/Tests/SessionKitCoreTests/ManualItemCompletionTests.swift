import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #273: once the 10-second undo banner was gone, nothing could mark an item unfinished again.
final class ManualItemCompletionTests: XCTestCase {
    func testAnItemMarkedCompleteCanBeMarkedUnfinishedLaterAndKeepsItsProgress() throws {
        let path = temporaryDatabasePath()
        let session = Session(id: "session", itemId: "article", status: "in_progress", phase: .itemPlayback,
                              currentTargetType: .itemTextTTS, currentTargetId: "article",
                              position: Position(charOffset: 40), completionPercent: 38, playbackRate: 1)
        do {
            let store = try SQLiteSessionStore(path: path)
            try store.saveItem(Item(id: "article", title: "Article", mediaType: "text", text: String(repeating: "Words. ", count: 20),
                                    externalReference: nil, status: "ready"))
            try store.saveSession(session)
            let marked = try XCTUnwrap(ManualItemCompletion.markComplete(itemId: "article", at: Date(timeIntervalSince1970: 1_800_000_000), in: store))
            XCTAssertNotNil(marked.sourceCompletedAt)
            XCTAssertNil(try ManualItemCompletion.markComplete(itemId: "article", in: store), "already marked")
        }
        // Long after any undo window, in a later launch.
        do {
            let store = try SQLiteSessionStore(path: path)
            XCTAssertNotNil(try ManualItemCompletion.markUnfinished(itemId: "article", in: store))
        }
        let store = try SQLiteSessionStore(path: path)
        XCTAssertNil(try store.loadItem(id: "article").sourceCompletedAt)
        XCTAssertEqual(try store.loadSessions(itemId: "article"), [session], "the listening position is unchanged")
        XCTAssertNil(try ManualItemCompletion.markUnfinished(itemId: "article", in: store), "nothing left to clear")
    }

    func testAnUndoClearsOnlyTheCompletionItWasFor() throws {
        let store = try SQLiteSessionStore(path: temporaryDatabasePath())
        try store.saveItem(Item(id: "article", title: "Article", mediaType: "text", text: "Words.", externalReference: nil, status: "ready"))
        let first = try XCTUnwrap(ManualItemCompletion.markComplete(itemId: "article", at: Date(timeIntervalSince1970: 1), in: store)?.sourceCompletedAt)
        try ManualItemCompletion.markUnfinished(itemId: "article", in: store)
        try ManualItemCompletion.markComplete(itemId: "article", at: Date(timeIntervalSince1970: 2), in: store)

        XCTAssertNil(try ManualItemCompletion.markUnfinished(itemId: "article", markedAt: first, in: store))
        XCTAssertNotNil(try store.loadItem(id: "article").sourceCompletedAt, "the later completion stays")
    }

    private func temporaryDatabasePath() -> String {
        FileManager.default.temporaryDirectory.appending(path: "manual-completion-\(UUID().uuidString).sqlite").path
    }
}
