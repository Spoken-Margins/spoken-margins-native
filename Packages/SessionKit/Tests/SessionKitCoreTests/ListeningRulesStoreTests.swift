import Foundation
import SQLite3
import XCTest
import SessionKit
import SessionKitPersistence

/// #4046 PR 10b: the Rules screens' writes, on a real temporary SQLite file, and "Add everything new" when the rules
/// can't be read.
final class ListeningRulesStoreTests: XCTestCase {
    private var directory: URL!
    private var path: String { directory.appendingPathComponent("library.sqlite").path }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rules-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let subscription = FeedSubscription(
        id: "a", source: SourceIdentity(id: "s", kind: .podcastFeed, canonicalURL: "https://example.com/a.xml", host: "example.com", title: "Alpha"))

    private func entry(_ id: String, _ title: String, day: Int = 0) -> FeedEntry {
        FeedEntry(id: id, subscriptionId: "a", canonicalURL: "https://example.com/\(id)", title: title,
                  publishedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(day) * 86_400), state: .unseen)
    }

    /// Alpha, followed, with five crypto episodes and one about gardens.
    private func storeWithAlpha() throws -> SQLiteSessionStore {
        let store = try SQLiteSessionStore(path: path)
        try store.saveFeedSubscription(subscription)
        for n in 0..<5 { try store.saveFeedEntry(entry("c\(n)", "Crypto \(n)", day: n)) }
        try store.saveFeedEntry(entry("g", "Gardens", day: 9))
        return store
    }

    func testANewRuleIsSavedOnAndSurvivesARelaunch() async throws {
        let rules = ListeningRulesStore(store: try storeWithAlpha())
        let change = try await rules.create(action: .skip, wordsField: " gardens , ", scope: .any, id: "r")
        XCTAssertNil(change.problem)
        XCTAssertNil(change.refusal)
        XCTAssertEqual(change.changedRuleID, "r")
        XCTAssertEqual(change.rules.map(\.words), [["gardens"]])
        XCTAssertEqual(change.rules.first?.isOn, true)
        XCTAssertEqual(change.rules.first?.origin, .listener)

        let reopened = try SQLiteSessionStore(path: path).loadListeningRules()
        XCTAssertEqual(reopened.map(\.id), ["r"])
        XCTAssertEqual(reopened.first?.isOn, true)
    }

    func testATooBroadNewRuleIsSavedOffWithTheRefusal() async throws {
        let rules = ListeningRulesStore(store: try storeWithAlpha())
        let change = try await rules.create(action: .skip, wordsField: "crypto, gardens", scope: .any, id: "r")
        XCTAssertEqual(change.refusal?.message,
                       "It matches 6 of the last 6 episodes from Alpha. To hear less of a whole show, set it to Quiet on its page.")
        XCTAssertEqual(change.rules.map(\.isOn), [false])
        let pick = try await rules.create(action: .more, wordsField: "crypto, gardens", scope: .any, id: "p")
        XCTAssertNil(pick.refusal, "a pick rule is never too broad")
        XCTAssertEqual(pick.rules.first { $0.id == "p" }?.isOn, true)
    }

    func testRefusedWordsSaveNothingAndADoubleSaveMakesOneRule() async throws {
        let rules = ListeningRulesStore(store: try storeWithAlpha())
        let empty = try await rules.create(action: .skip, wordsField: " , ", scope: .any, id: "r")
        XCTAssertEqual(empty.problem, .noWords)
        XCTAssertEqual(empty.rules, [])
        async let first = rules.create(action: .skip, wordsField: "gardens", scope: .any, id: "same")
        async let second = rules.create(action: .skip, wordsField: "gardens", scope: .any, id: "same")
        let (one, two) = try await (first, second)
        XCTAssertEqual(one.rules.count, 1)
        XCTAssertEqual(two.rules.count, 1)
    }

    func testTheTwoHundredthRuleIsTheLast() async throws {
        let store = try storeWithAlpha()
        for n in 0..<ListeningRuleWords.maxRules {
            try store.saveListeningRule(ListeningRule(id: "r\(n)", action: .more, words: ["w\(n)"]))
        }
        let change = try await ListeningRulesStore(store: store).create(action: .more, wordsField: "more", scope: .any, id: "x")
        XCTAssertTrue(change.isFull)
        XCTAssertEqual(change.rules.count, ListeningRuleWords.maxRules)
        XCTAssertEqual(ListeningRuleScreens.fullRefusal.title, "Can’t add another rule")
        XCTAssertEqual(ListeningRuleScreens.fullRefusal.message, "You can keep at most 200 rules. Delete one to add another.")
    }

    func testTurningOnIsRefusedWhileTooBroadAndTurningOffAlwaysWorks() async throws {
        let store = try storeWithAlpha()
        try store.saveListeningRule(ListeningRule(id: "broad", action: .skip, words: ["crypto", "gardens"], isOn: false))
        try store.saveListeningRule(ListeningRule(id: "fine", action: .skip, words: ["gardens"], isOn: false))
        let rules = ListeningRulesStore(store: store)

        let refused = try await rules.setOn(id: "broad", isOn: true)
        XCTAssertEqual(refused.refusal?.title, "This rule would skip almost everything")
        XCTAssertEqual(refused.rules.first { $0.id == "broad" }?.isOn, false)

        let on = try await rules.setOn(id: "fine", isOn: true)
        XCTAssertNil(on.refusal)
        XCTAssertEqual(on.rules.first { $0.id == "fine" }?.isOn, true)
        let off = try await rules.setOn(id: "fine", isOn: false)
        XCTAssertEqual(off.rules.first { $0.id == "fine" }?.isOn, false)

        // A rule already on that became too broad can still be switched off.
        try store.saveListeningRule(ListeningRule(id: "broad", action: .skip, words: ["crypto", "gardens"], isOn: true))
        let broadOff = try await rules.setOn(id: "broad", isOn: false)
        XCTAssertEqual(broadOff.rules.first { $0.id == "broad" }?.isOn, false)
        let missing = try await rules.setOn(id: "gone", isOn: true)
        XCTAssertNil(missing.changedRuleID)
    }

    func testEditingWordsValidatesAndDeletingRemoves() async throws {
        let store = try storeWithAlpha()
        try store.saveListeningRule(ListeningRule(id: "r", action: .skip, words: ["gardens"], isOn: true))
        let rules = ListeningRulesStore(store: store)
        let refused = try await rules.setWords(id: "r", wordsField: ", ,")
        XCTAssertEqual(refused.problem, .noWords)
        XCTAssertEqual(refused.rules.first?.words, ["gardens"])
        let changed = try await rules.setWords(id: "r", wordsField: "soil, Soil, compost")
        XCTAssertEqual(changed.rules.first?.words, ["soil", "compost"])
        XCTAssertEqual(changed.rules.first?.isOn, true)
        let left = try await rules.delete(id: "r")
        XCTAssertEqual(left, [])
        XCTAssertEqual(try SQLiteSessionStore(path: path).loadListeningRules(), [])
    }

    /// The PR 10a audit: a rules read that fails must not let "Add everything new" add an episode a rule would set aside,
    /// because that add is permanent. The screens still draw every episode.
    func testAnUnreadableRuleSetsEveryNewEpisodeAsideForAddEverythingNew() throws {
        let store = try storeWithAlpha()
        try store.saveListeningRule(ListeningRule(id: "r", action: .skip, words: ["crypto"], isOn: true))
        // A read that fails outright (a payload that won't decode is skipped by the store, so it is not one).
        try execute("DROP TABLE records;")
        let entries = [entry("c0", "Crypto 0"), entry("g", "Gardens")]

        XCTAssertNil(FollowingRuleInputs.loadIfReadable(from: store))
        XCTAssertEqual(FollowingRuleInputs.setAside(store: store)(entries, subscription), ["c0", "g"])
        XCTAssertTrue(FollowingRuleInputs.load(from: store).rules.isEmpty, "the screens read no rules, so they hide nothing")
    }

    private func execute(_ sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK else { throw SessionKitError.persistenceFailed("open") }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw SessionKitError.persistenceFailed(String(cString: sqlite3_errmsg(database)))
        }
    }
}
