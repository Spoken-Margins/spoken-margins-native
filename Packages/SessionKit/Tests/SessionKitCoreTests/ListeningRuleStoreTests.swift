import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #4046 PR 9: rules and Show less marks are their own record kinds over a real temporary SQLite file.
final class ListeningRuleStoreTests: XCTestCase {
    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    func testRulesAndMarksSurviveAReopen() throws {
        let path = NSTemporaryDirectory() + "listening-rules-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let first = ListeningRule(id: "r1", action: .skip, words: ["crypto*", "nft"], scope: .list("L"), origin: .listener, isOn: true, createdAt: date(1), updatedAt: date(5))
        let second = ListeningRule(id: "r2", action: .more, words: ["new york"], scope: .show(ListMember(feedKey: "https://a.example/feed", podcastGUID: "g")), origin: .list("News"), isOn: false, createdAt: date(2))
        let third = ListeningRule(id: "r3", action: .skip, words: ["x"], scope: .any, origin: .ai(date(9)), createdAt: date(3))
        let fourth = ListeningRule(id: "r4", action: .skip, words: ["y"], scope: .any, origin: .suggested, createdAt: date(4))
        let mark = ShowLessMark(feedKey: "https://a.example/feed", entryId: "e1", title: "Crash", markedAt: date(7))
        let itemMark = ShowLessMark(feedKey: "https://a.example/feed", itemId: "item-1", title: "Other", markedAt: date(6))
        do {
            let store = try SQLiteSessionStore(path: path)
            for rule in [fourth, second, third, first] { try store.saveListeningRule(rule) }
            try store.saveShowLessMark(mark)
            try store.saveShowLessMark(itemMark)
        }
        let store = try SQLiteSessionStore(path: path)
        XCTAssertEqual(try store.loadListeningRules(), [first, second, third, fourth], "oldest first")
        XCTAssertEqual(try store.loadListeningRule(id: "r2"), second)
        XCTAssertNil(try store.loadListeningRule(id: "missing"))
        XCTAssertEqual(try store.loadShowLessMarks(), [itemMark, mark], "oldest mark first")

        var edited = first
        edited.isOn = false
        edited.words = ["crypto*"]
        try store.saveListeningRule(edited)
        XCTAssertEqual(try store.loadListeningRules().first, edited, "saving again with the same id is one rule")
        try store.deleteListeningRule(id: "r2")
        XCTAssertEqual(try store.loadListeningRules().map(\.id), ["r1", "r3", "r4"])
    }

    func testMarkingTwiceKeepsOneMarkAndUndoRemovesIt() throws {
        let store = try SQLiteSessionStore(path: NSTemporaryDirectory() + "show-less-\(UUID().uuidString).sqlite")
        try store.saveShowLessMark(ShowLessMark(feedKey: "k", entryId: "e1", itemId: nil, title: "From the Show screen", markedAt: date(1)))
        try store.saveShowLessMark(ShowLessMark(feedKey: "k", entryId: "e1", itemId: "item-1", title: "From the Item screen", markedAt: date(2)))
        XCTAssertEqual(try store.loadShowLessMarks().map(\.title), ["From the Item screen"])
        try store.deleteShowLessMark(entryId: "e1", itemId: "item-1")
        XCTAssertTrue(try store.loadShowLessMarks().isEmpty, "Undo Show less from either screen removes the one mark")
    }

    func testRulesAndMarksSitBesideListsWithoutTouchingThem() throws {
        let store = try SQLiteSessionStore(path: NSTemporaryDirectory() + "rules-and-lists-\(UUID().uuidString).sqlite")
        let list = FollowList(id: "L", name: "News", createdAt: date(1), members: [ListMember(feedKey: "https://a.example/feed")])
        try store.saveFollowList(list)
        try store.saveListeningRule(ListeningRule(id: "r", action: .skip, words: ["x"], scope: .list("L"), createdAt: date(1)))
        try store.deleteFollowList(id: "L")
        XCTAssertEqual(try store.loadListeningRules().count, 1, "deleting a list leaves its rule; the rule then applies to nothing")
    }
}
