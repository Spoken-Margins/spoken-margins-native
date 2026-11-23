import XCTest
@testable import SessionKit

/// #4683, Design section 2g: a saved link list is tried at most three times while online.
final class LinkListRetryLedgerTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "LinkListRetryLedgerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testConstants() {
        XCTAssertEqual(LinkListRetryLedger.maxTries, 3)
        XCTAssertEqual(LinkListRetryLedger.handoffKey, "linkListHandoffTriesV1")
        XCTAssertEqual(LinkListRetryLedger.quickFolderKey, "quickFolderLinkListRetryV1")
    }

    func testThirdFailedTryExhaustsAFile() {
        let ledger = LinkListRetryLedger(defaults: makeDefaults(), key: LinkListRetryLedger.handoffKey)
        XCTAssertEqual(ledger.tries(for: "a.json"), 0)
        XCTAssertFalse(ledger.isExhausted("a.json"))
        XCTAssertEqual(ledger.recordFailedTry(for: "a.json"), 1)
        XCTAssertEqual(ledger.recordFailedTry(for: "a.json"), 2)
        XCTAssertFalse(ledger.isExhausted("a.json"), "two failed tries leave one more")
        XCTAssertEqual(ledger.recordFailedTry(for: "a.json"), 3)
        XCTAssertTrue(ledger.isExhausted("a.json"), "the 3rd failed try ends it")
        XCTAssertFalse(ledger.isExhausted("b.json"), "another file is untouched")
    }

    func testCountsSurviveANewInstanceOverTheSameDefaults() {
        let defaults = makeDefaults()
        LinkListRetryLedger(defaults: defaults, key: LinkListRetryLedger.handoffKey).recordFailedTry(for: "a.json")
        let again = LinkListRetryLedger(defaults: defaults, key: LinkListRetryLedger.handoffKey)
        XCTAssertEqual(again.tries(for: "a.json"), 1)
    }

    func testTheTwoKindsOfListKeepSeparateCounts() {
        let defaults = makeDefaults()
        let handoff = LinkListRetryLedger(defaults: defaults, key: LinkListRetryLedger.handoffKey)
        let quick = LinkListRetryLedger(defaults: defaults, key: LinkListRetryLedger.quickFolderKey)
        handoff.recordFailedTry(for: "same-id")
        XCTAssertEqual(quick.tries(for: "same-id"), 0)
        quick.recordFailedTry(for: "same-id")
        quick.recordFailedTry(for: "same-id")
        XCTAssertEqual(handoff.tries(for: "same-id"), 1)
        XCTAssertEqual(quick.tries(for: "same-id"), 2)
    }

    func testClearAndPrune() {
        let defaults = makeDefaults()
        let ledger = LinkListRetryLedger(defaults: defaults, key: LinkListRetryLedger.quickFolderKey)
        ledger.recordFailedTry(for: "a")
        ledger.recordFailedTry(for: "b")
        ledger.recordFailedTry(for: "c")
        ledger.clear("a")
        ledger.clear("never-seen")
        XCTAssertEqual(ledger.tries(for: "a"), 0)
        ledger.prune(keeping: ["b"])
        XCTAssertEqual(ledger.tries(for: "b"), 1)
        XCTAssertEqual(ledger.tries(for: "c"), 0, "a list that is gone no longer counts")
        ledger.prune(keeping: [])
        XCTAssertNil(defaults.object(forKey: LinkListRetryLedger.quickFolderKey), "an empty ledger leaves no key behind")
    }

    func testValuesThisCodeDidNotWriteCountAsNoTries() {
        let defaults = makeDefaults()
        defaults.set(["good": 2, "text": "many", "negative": -4, "zero": 0], forKey: LinkListRetryLedger.handoffKey)
        let ledger = LinkListRetryLedger(defaults: defaults, key: LinkListRetryLedger.handoffKey)
        XCTAssertEqual(ledger.tries(for: "good"), 2)
        for id in ["text", "negative", "zero"] { XCTAssertEqual(ledger.tries(for: id), 0, id) }
        defaults.set("not a dictionary", forKey: LinkListRetryLedger.handoffKey)
        XCTAssertEqual(ledger.tries(for: "good"), 0)
        XCTAssertEqual(ledger.recordFailedTry(for: "good"), 1, "a garbage value is replaced, not fatal")
    }

    func testAHandoffFileNameWorksAsTheKey() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = LinkListHandoffFolder(baseDirectory: base)
        let entry = try folder.save(LinkListFile(title: nil, entries: [.init(url: "https://example.com/a")]))
        let ledger = LinkListRetryLedger(defaults: makeDefaults(), key: LinkListRetryLedger.handoffKey)
        for _ in 0..<3 { ledger.recordFailedTry(for: entry.id) }
        XCTAssertTrue(ledger.isExhausted(entry.id))
        ledger.prune(keeping: Set(folder.pending().map(\.id)))
        XCTAssertTrue(ledger.isExhausted(entry.id), "the file still waits, so its count stays")
        folder.remove(entry)
        ledger.prune(keeping: Set(folder.pending().map(\.id)))
        XCTAssertEqual(ledger.tries(for: entry.id), 0)
    }
}
