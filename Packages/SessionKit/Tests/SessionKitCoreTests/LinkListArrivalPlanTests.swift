import XCTest
@testable import SessionKit

/// #4683 PR 3a, Design sections 2f, 5 and 6: one list gets one plan whichever of the four entries it came through, and
/// the rules of the arrival (key, links, follows, banner, Undo, retry, offline) hold on the host.
final class LinkListArrivalPlanTests: XCTestCase {
    private let briefJSON = """
    {
      "schemaVersion": "spoken-margins.link-list.v1",
      "title": "Morning brief, November 23",
      "entries": [
        { "url": "https://news.example.org/a", "title": "A" },
        { "url": "https://news.example.org/b" },
        { "url": "https://feeds.example.org/show.xml", "follow": true },
        { "url": "http://not-https.example.org/c" }
      ]
    }
    """

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("arrival-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func recognized(_ json: String) throws -> LinkListFile {
        guard case .linkList(let list) = LinkListFile.recognize(Data(json.utf8)) else {
            XCTFail("not a list")
            throw CocoaError(.fileReadCorruptFile)
        }
        return list
    }

    private func plan(_ list: LinkListFile, followed: Set<String> = [], offline: Bool = false) -> LinkListArrivalPlan {
        LinkListArrivalPlan.make(list: list, followedFeedKeys: followed, isOffline: offline)
    }

    // MARK: The four entries give one plan

    func testQuickFolderFilePastedReplyAndHandoffFileGiveTheSamePlan() throws {
        let direct = plan(try recognized(briefJSON))

        // Quick Folder, tapped or on its own: a file picked up by the same sort `+ > Files` uses.
        let file = directory.appendingPathComponent("brief-2026-11-23.json")
        try Data(briefJSON.utf8).write(to: file)
        let pick = LinkListPick.sort(files: [file])
        XCTAssertEqual(pick.lists.count, 1)
        let fromQuickFolder = plan(try XCTUnwrap(pick.lists.first).list)

        // Paste & go: the reply is prose around a fenced block.
        let reply = "Here is your brief:\n\n```json\n\(briefJSON)\n```\n\nEnjoy."
        guard case .linkList(let pasted) = LinkListText.find(in: reply) else { return XCTFail("reply not found") }
        let fromPaste = plan(pasted)

        // Handoff folder: the Shortcut saved the list re-encoded, and the drain reads it back.
        let folder = LinkListHandoffFolder(baseDirectory: directory)
        let entry = try folder.save(try recognized(briefJSON))
        guard case .linkList(let saved) = folder.read(entry) else { return XCTFail("handoff not read") }
        let fromHandoff = plan(saved)

        for other in [fromQuickFolder, fromPaste] {
            XCTAssertEqual(other, direct)
        }
        // The handoff file keeps usable entries only, so the skipped entry is the one difference.
        XCTAssertEqual(fromHandoff.key, direct.key)
        XCTAssertEqual(fromHandoff.title, direct.title)
        XCTAssertEqual(fromHandoff.links, direct.links)
        XCTAssertEqual(fromHandoff.followURLs, direct.followURLs)
        XCTAssertEqual(direct.links.map(\.url), ["https://news.example.org/a", "https://news.example.org/b"])
        XCTAssertEqual(direct.followURLs, ["https://feeds.example.org/show.xml"])
        XCTAssertEqual(direct.skipped.count, 1)
    }

    // MARK: The key

    func testKeyIsTheSameForTheSameListAndChangesWithTitleOrLinks() throws {
        let base = try recognized(briefJSON)
        XCTAssertEqual(plan(base).key, plan(base).key)
        XCTAssertTrue(plan(base).key.hasPrefix("linklist:"))
        // 64 lowercase hex digits after the prefix.
        let hex = plan(base).key.dropFirst("linklist:".count)
        XCTAssertEqual(hex.count, 64)
        XCTAssertTrue(hex.allSatisfy { "0123456789abcdef".contains($0) })

        var retitled = base
        retitled.title = "Evening brief"
        XCTAssertNotEqual(plan(retitled).key, plan(base).key)

        var extra = base
        extra.entries.append(.init(url: "https://news.example.org/new"))
        XCTAssertNotEqual(plan(extra).key, plan(base).key, "a file saved under one name each day, with new links, is a new collection")

        var untitled = base
        untitled.title = nil
        XCTAssertNotEqual(plan(untitled).key, plan(base).key)
    }

    func testKeyIgnoresSkippedEntriesAndEntryTitles() throws {
        let base = try recognized(briefJSON)
        var other = base
        other.skipped = []
        other.entries[0].title = "A different display title"
        XCTAssertEqual(plan(other).key, plan(base).key)
    }

    // MARK: Links, follows and titles

    func testFollowEntriesAreNeverLinksToAdd() throws {
        let result = plan(try recognized(briefJSON))
        XCTAssertFalse(result.links.contains { $0.follow })
        XCTAssertEqual(result.itemList.entries, result.links)
        XCTAssertEqual(result.itemList.title, "Morning brief, November 23")
    }

    func testFollowedShowsAreDropped() throws {
        let list = try recognized(briefJSON)
        let followed = Set([FeedURLKey.make("https://feeds.example.org/show.xml")].compactMap { $0 })
        XCTAssertTrue(plan(list, followed: followed).followURLs.isEmpty)
        // Matching is by `FeedURLKey`: scheme, host case and a trailing slash don't hide a followed show.
        var other = list
        other.entries[2].url = "https://FEEDS.example.org/show.xml#top"
        XCTAssertTrue(plan(other, followed: followed).followURLs.isEmpty)
    }

    func testTitleCases() {
        let entries = [LinkListFile.Entry(url: "https://example.org/a")]
        XCTAssertNil(plan(LinkListFile(title: nil, entries: entries)).title)
        XCTAssertNil(plan(LinkListFile(title: "   ", entries: entries)).title)
        XCTAssertEqual(plan(LinkListFile(title: "  Brief  ", entries: entries)).title, "Brief")
        XCTAssertTrue(plan(LinkListFile(title: "Brief", entries: entries)).isTitled)
        XCTAssertFalse(plan(LinkListFile(title: nil, entries: entries)).isTitled)
    }

    func testFollowOnlyListHasNoLinks() {
        let list = LinkListFile(title: "Shows", entries: [.init(url: "https://feeds.example.org/a.xml", follow: true)])
        let result = plan(list)
        XCTAssertFalse(result.hasLinks)
        XCTAssertEqual(result.followURLs, ["https://feeds.example.org/a.xml"])
    }

    // MARK: Offline (network)

    func testOfflineWaitsAndOnlineAttempts() throws {
        let list = try recognized(briefJSON)
        XCTAssertEqual(plan(list, offline: true).attempt, .waitOffline)
        XCTAssertEqual(plan(list, offline: false).attempt, .attempt)
        // Going back online gives the same key, so the retry adds into the same collection.
        XCTAssertEqual(plan(list, offline: true).key, plan(list, offline: false).key)
    }

    // MARK: Pasted text

    func testPastedTextClassification() {
        XCTAssertEqual(LinkListArrivalPlan.classifyPaste(""), .notALinkList)
        XCTAssertEqual(LinkListArrivalPlan.classifyPaste("https://example.com/a"), .notALinkList)
        XCTAssertEqual(LinkListArrivalPlan.classifyPaste("a link list is a nice idea"), .notALinkList)
        XCTAssertEqual(LinkListArrivalPlan.classifyPaste("```json\n\(briefJSON)\n```"), .mightBeLinkList)
        XCTAssertEqual(LinkListArrivalPlan.classifyPaste("Sure!\n\(briefJSON)"), .mightBeLinkList)
    }

    func testTheAssistantPromptItselfIsNeverAList() {
        // The prompt holds the marker and a valid example list with two example.com links. Pasting it must not add them.
        let prompt = AssistantSetupPrompt.make(date: Date(timeIntervalSince1970: 1_800_000_000), locale: Locale(identifier: "en_US"),
                                               timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(LinkListText.mightContain(prompt), "the example is a real list, so the guard is what stops it")
        XCTAssertEqual(LinkListArrivalPlan.classifyPaste(prompt), .assistantPrompt)
        // Neighbouring copies of the prompt: leading and trailing lines, notes and a folder filled in, Windows line endings.
        XCTAssertEqual(LinkListArrivalPlan.classifyPaste("Copied from Spoken Margins:\n\n" + prompt + "\n"), .assistantPrompt)
        let filled = AssistantSetupPrompt.make(date: Date(timeIntervalSince1970: 1_800_000_000), locale: Locale(identifier: "en_GB"),
                                               timeZone: TimeZone(identifier: "Europe/London")!,
                                               notes: "This month: soil health.", quickFolderName: "Briefs")
        XCTAssertEqual(LinkListArrivalPlan.classifyPaste(filled), .assistantPrompt)
        XCTAssertEqual(LinkListArrivalPlan.classifyPaste(prompt.replacingOccurrences(of: "\n", with: "\r\n")), .assistantPrompt)
        // A reply from the AI is not the prompt.
        XCTAssertEqual(LinkListArrivalPlan.classifyPaste("```json\n\(briefJSON)\n```"), .mightBeLinkList)
        XCTAssertFalse(AssistantSetupPrompt.isPrompt("I use Spoken Margins."))
        XCTAssertFalse(AssistantSetupPrompt.isPrompt(""))
    }

    // MARK: Banner

    private let madeBrief = LibraryCollectionImport.Summary(message: "Made “Morning brief” with 2 items.", kind: .success)

    func testBannerForATitledListWithItemsAndUndo() {
        let banner = LinkListArrivalPlan.banner(
            base: madeBrief, suggested: 0, madeItems: true, isTitled: true, collectionIsNew: true, mentionsFollowing: false)
        XCTAssertEqual(banner.message, "Made “Morning brief” with 2 items.")
        XCTAssertEqual(banner.kind, .success)
        XCTAssertTrue(banner.offersUndo)
    }

    func testBannerLeavesOffTheFollowingSentenceUntilFollowingCanShowIt() {
        let before = LinkListArrivalPlan.banner(
            base: madeBrief, suggested: 2, madeItems: true, isTitled: true, collectionIsNew: true, mentionsFollowing: false)
        XCTAssertEqual(before.message, "Made “Morning brief” with 2 items.")
        let after = LinkListArrivalPlan.banner(
            base: madeBrief, suggested: 2, madeItems: true, isTitled: true, collectionIsNew: true, mentionsFollowing: true)
        XCTAssertEqual(after.message, "Made “Morning brief” with 2 items. 2 shows to review in Following.")
        let one = LinkListArrivalPlan.banner(
            base: madeBrief, suggested: 1, madeItems: true, isTitled: true, collectionIsNew: true, mentionsFollowing: true)
        XCTAssertEqual(one.message, "Made “Morning brief” with 2 items. 1 show to review in Following.")
    }

    func testUndoIsOfferedOnlyWhenItemsWereMadeAndATitledCollectionIsNew() {
        func offers(titled: Bool, isNew: Bool, made: Bool) -> Bool {
            LinkListArrivalPlan.banner(
                base: madeBrief, suggested: 0, madeItems: made, isTitled: titled, collectionIsNew: isNew, mentionsFollowing: false).offersUndo
        }
        XCTAssertTrue(offers(titled: true, isNew: true, made: true))
        XCTAssertFalse(offers(titled: true, isNew: false, made: true), "a re-pick into an existing collection is not undone with the banner")
        XCTAssertFalse(offers(titled: true, isNew: true, made: false))
        XCTAssertTrue(offers(titled: false, isNew: false, made: true), "an untitled list has no collection; new items are enough")
        XCTAssertFalse(offers(titled: false, isNew: false, made: false))
    }

    func testBannerKeepsTheImportsWarningKind() {
        let warning = LibraryCollectionImport.Summary(message: "Made “X” with 1 item. 1 couldn't be added.", kind: .warning)
        let banner = LinkListArrivalPlan.banner(
            base: warning, suggested: 0, madeItems: true, isTitled: true, collectionIsNew: true, mentionsFollowing: false)
        XCTAssertEqual(banner.kind, .warning)
    }

    func testFollowOnlyBanner() {
        let some = LinkListArrivalPlan.banner(
            base: nil, suggested: 2, madeItems: false, isTitled: true, collectionIsNew: false, mentionsFollowing: false)
        XCTAssertEqual(some.message, "Your AI suggested 2 shows.")
        XCTAssertFalse(some.offersUndo)
        let withRow = LinkListArrivalPlan.banner(
            base: nil, suggested: 1, madeItems: false, isTitled: false, collectionIsNew: false, mentionsFollowing: true)
        XCTAssertEqual(withRow.message, "Your AI suggested 1 show. They're at the top of Following.")
        let none = LinkListArrivalPlan.banner(
            base: nil, suggested: 0, madeItems: false, isTitled: false, collectionIsNew: false, mentionsFollowing: true)
        XCTAssertEqual(none.message, "Those shows are already in Following.")
        XCTAssertFalse(none.offersUndo)
    }

    // MARK: Undo (returning, finished, other-item-playing)

    func testUndoMovesOnlyTheNewItems() {
        // returning: one new item and one already in the Library; only the new one is moved.
        let ids = LinkListArrivalPlan.undoItemIDs(
            added: ["item-existing", "item-new"], libraryBefore: ["item-existing", "item-other"], playing: nil)
        XCTAssertEqual(ids, ["item-new"])
    }

    func testUndoSkipsTheItemNowPlayingAndRepeats() {
        let ids = LinkListArrivalPlan.undoItemIDs(
            added: ["a", "b", "a", "c"], libraryBefore: [], playing: "b")
        XCTAssertEqual(ids, ["a", "c"])
    }

    func testUndoWithNothingNewMovesNothing() {
        XCTAssertEqual(LinkListArrivalPlan.undoItemIDs(added: ["a"], libraryBefore: ["a"], playing: nil), [])
        XCTAssertEqual(LinkListArrivalPlan.undoItemIDs(added: [], libraryBefore: [], playing: nil), [])
        // A finished item that was already in the Library stays, whatever its progress.
        XCTAssertEqual(LinkListArrivalPlan.undoItemIDs(added: ["finished-99-percent"], libraryBefore: ["finished-99-percent"], playing: nil), [])
    }

    // MARK: Retry (network, relaunch)

    func testSettlement() {
        XCTAssertEqual(LinkListArrivalPlan.settlement(allLanded: true, triesAfterThisAttempt: 0), .done)
        XCTAssertEqual(LinkListArrivalPlan.settlement(allLanded: false, triesAfterThisAttempt: 1), .retryLater)
        XCTAssertEqual(LinkListArrivalPlan.settlement(allLanded: false, triesAfterThisAttempt: 2), .retryLater)
        XCTAssertEqual(LinkListArrivalPlan.settlement(allLanded: false, triesAfterThisAttempt: 3), .stayForTap)
        XCTAssertEqual(LinkListArrivalPlan.settlement(allLanded: false, triesAfterThisAttempt: 4), .stayForTap)
        // A list that landed in full on a later try is done, whatever the ledger says.
        XCTAssertEqual(LinkListArrivalPlan.settlement(allLanded: true, triesAfterThisAttempt: 3), .done)
    }

    func testQuickFolderRetryRecordSurvivesANewLedgerOverTheSameDefaults() throws {
        let suite = "arrival-retry-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = "Briefs/brief-2026-11-23.json"

        let first = LinkListRetryLedger(defaults: defaults, key: LinkListRetryLedger.quickFolderKey)
        XCTAssertEqual(LinkListArrivalPlan.settlement(allLanded: false, triesAfterThisAttempt: first.recordFailedTry(for: file)), .retryLater)
        XCTAssertEqual(LinkListArrivalPlan.settlement(allLanded: false, triesAfterThisAttempt: first.recordFailedTry(for: file)), .retryLater)

        // relaunch: a new ledger over the same defaults continues the count and gives up on the third failed try.
        let second = LinkListRetryLedger(defaults: defaults, key: LinkListRetryLedger.quickFolderKey)
        XCTAssertEqual(second.tries(for: file), 2)
        XCTAssertEqual(LinkListArrivalPlan.settlement(allLanded: false, triesAfterThisAttempt: second.recordFailedTry(for: file)), .stayForTap)
        XCTAssertTrue(second.isExhausted(file))
    }

    // MARK: The record of the last arrival (relaunch)

    func testLastArrivalRecordSurvivesANewReadOverTheSameDefaults() throws {
        let suite = "arrival-record-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(LinkListArrivalRecord.load(from: defaults))

        let date = Date(timeIntervalSince1970: 1_800_000_000)
        LinkListArrivalRecord(title: "Morning brief", date: date).save(to: defaults)
        XCTAssertEqual(LinkListArrivalRecord.load(from: defaults), LinkListArrivalRecord(title: "Morning brief", date: date))

        LinkListArrivalRecord(title: nil, date: date).save(to: defaults)
        XCTAssertEqual(LinkListArrivalRecord.load(from: defaults)?.title, nil)
        XCTAssertEqual(LinkListArrivalRecord.load(from: defaults)?.date, date)

        defaults.set(Data("not json".utf8), forKey: LinkListArrivalRecord.defaultsKey)
        XCTAssertNil(LinkListArrivalRecord.load(from: defaults), "unreadable data counts as no record")
        XCTAssertEqual(LinkListArrivalRecord.defaultsKey, "lastLinkListArrivalV1")
    }

    // MARK: Burst: the same list by two routes is one collection

    func testTheSameListFromPasteAndFromAFileSharesOneKey() throws {
        let file = directory.appendingPathComponent("any-name.json")
        try Data(briefJSON.utf8).write(to: file)
        let fromFile = plan(try XCTUnwrap(LinkListPick.sort(files: [file]).lists.first).list)
        guard case .linkList(let pasted) = LinkListText.find(in: "```\n\(briefJSON)\n```") else { return XCTFail("not found") }
        XCTAssertEqual(plan(pasted).key, fromFile.key)
    }

    func testEveryRouteIsListed() {
        XCTAssertEqual(Set(LinkListArrivalPlan.Route.allCases.map(\.rawValue)),
                       ["quickFolderAutomatic", "quickFolderTapped", "pasteAndGo", "handoffFolder"])
    }
}
