import Foundation
import XCTest
import SessionKit
import SessionKitPersistence

/// #4046 PR 10a: the evaluator's inputs come from the real store, and a store with none gives an inert evaluation.
final class FollowingRuleInputsStoreTests: XCTestCase {
    private func makeStore() throws -> (SQLiteSessionStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rule-inputs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (try SQLiteSessionStore(path: directory.appendingPathComponent("library.sqlite").path), directory)
    }

    private let subscription = FeedSubscription(
        id: "a", source: SourceIdentity(id: "s", kind: .podcastFeed, canonicalURL: "https://example.com/a.xml", host: "example.com", title: "A"))

    private func entry(_ id: String, _ title: String) -> FeedEntry {
        FeedEntry(id: id, subscriptionId: "a", canonicalURL: "https://example.com/\(id)", title: title, publishedAt: Date(), state: .unseen)
    }

    func testAnEmptyStoreGivesAnInertEvaluation() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputs = FollowingRuleInputs.load(from: store)
        XCTAssertTrue(inputs.isInert)
        let setAside = FollowingRuleInputs.setAside(store: store)
        XCTAssertEqual(setAside([entry("e1", "Crypto weekly")], subscription), [])
    }

    func testStoredRulesAndMarksSetEpisodesAsideAndASwitchedOffRuleDoesNot() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rule = ListeningRule(id: "r", action: .skip, words: ["crypto"], isOn: true)
        try store.saveListeningRule(rule)
        let setAside = FollowingRuleInputs.setAside(store: store)
        let entries = [entry("e1", "Crypto weekly"), entry("e2", "Gardening")]
        XCTAssertEqual(setAside(entries, subscription), ["e1"])

        var off = rule
        off.isOn = false
        try store.saveListeningRule(off)
        XCTAssertEqual(setAside(entries, subscription), [], "read each time, so switching it off counts at once")

        try store.saveShowLessMark(ShowLessMark(feedKey: "example.com/a.xml", entryId: "e2", title: "Gardening"))
        XCTAssertEqual(setAside(entries, subscription), ["e2"])
        XCTAssertFalse(FollowingRuleInputs.load(from: store).isInert)
    }
}
