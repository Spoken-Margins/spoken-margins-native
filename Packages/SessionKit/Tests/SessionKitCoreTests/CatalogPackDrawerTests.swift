import Foundation
import XCTest
@testable import SessionKit

/// The drawer's Packs chip, the pack button's plan and words, the hide reconcile and Done's pick order (#4285, PRs 7–9).
final class CatalogPackDrawerTests: XCTestCase {
    private func entry(_ id: String, _ kind: SourceContentKind = .podcast) -> SourceCatalogEntry {
        SourceCatalogEntry(
            id: id, kind: kind == .podcast ? .podcastFeed : .articleFeed, contentKind: kind, title: "Show \(id)",
            feedURL: "https://feeds.example.com/\(id).xml", subjects: ["science"], provenanceIds: ["p"]
        )
    }

    private func catalog(_ entries: [SourceCatalogEntry], packs: [SourceCatalogPack]?) -> SourceCatalog {
        SourceCatalog(
            schemaVersion: SourceCatalog.currentSchemaVersion, catalogId: "c", contentVersion: 1, title: "C",
            generatedAt: "2026-11-14T12:00:00Z", locale: nil, provenance: [], subjects: [], starterRows: nil, packs: packs, entries: entries
        )
    }

    private func subscription(_ id: String, feed: String) -> FeedSubscription {
        FeedSubscription(id: "sub-\(id)", source: SourceIdentity(id: "source-\(id)", kind: .podcastFeed, canonicalURL: feed, host: "feeds.example.com"))
    }

    // MARK: Chips

    func testEveryOpeningStartsOnPacksOnlyWhileAPackIsVisible() {
        let entries = ["a", "b"].map { entry($0) }
        let pack = SourceCatalogPack(id: "pack", title: "Pack", summary: "S", entryIds: ["a", "b"])
        let withPack = catalog(entries, packs: [pack])
        XCTAssertEqual(CatalogDrawerChip.start(in: withPack, notForMe: .empty), .packs)
        XCTAssertEqual(CatalogDrawerChip.start(in: withPack, notForMe: NotForMeSnapshot(hiddenEntryIds: ["a"])), .packs)
        XCTAssertEqual(CatalogDrawerChip.start(in: withPack, notForMe: NotForMeSnapshot(hiddenEntryIds: ["a", "b"])), .top,
                       "every source hidden: no visible pack, so Top")
        XCTAssertEqual(CatalogDrawerChip.start(in: catalog(entries, packs: nil), notForMe: .empty), .top, "a catalog from before packs")
        XCTAssertEqual(CatalogDrawerChip.start(in: catalog(entries, packs: []), notForMe: .empty), .top)
    }

    func testAChipNamesItsListAndItsIdentifier() {
        XCTAssertNil(CatalogDrawerChip.packs.listSubject)
        XCTAssertNil(CatalogDrawerChip.top.listSubject)
        XCTAssertEqual(CatalogDrawerChip.subject("news").listSubject, "news")
        XCTAssertEqual(CatalogDrawerChip.packs.identifierSuffix, "packs")
        XCTAssertEqual(CatalogDrawerChip.top.identifierSuffix, "top")
        XCTAssertEqual(CatalogDrawerChip.subject("writers").identifierSuffix, "writers")
    }

    // MARK: Follow all

    func testFollowAllFollowsTheUnfollowedInOrderRetryOnlyTheFailedAndASecondTapNothing() {
        let sources = ["p1", "p2", "p3", "n1"].map { entry($0) }
        func ids(_ states: [String: CatalogDrawerFollowState]) -> [String] {
            CatalogPackFollowPlan.targets(visibleSources: sources, states: states).map(\.id)
        }
        XCTAssertEqual(ids([:]), ["p1", "p2", "p3", "n1"])
        XCTAssertEqual(ids(["p2": .followed]), ["p1", "p3", "n1"], "only the other N−k")
        XCTAssertEqual(ids(["p1": .following]), [], "a second tap while anything is in flight does nothing")
        XCTAssertEqual(ids(["n1": .following, "p1": .failed("x")]), [], "in flight wins over a failure")
        XCTAssertEqual(ids(["p1": .followed, "p2": .failed("offline"), "n1": .failed("404")]), ["p2", "n1"], "Retry follows only those")
        XCTAssertEqual(ids(["p1": .followed, "p2": .followed, "p3": .followed, "n1": .followed]), [])
        XCTAssertEqual(CatalogPackFollowPlan.targets(visibleSources: [], states: [:]), [])
    }

    func testButtonTitlesForEveryState() {
        XCTAssertEqual(CatalogPackWords.buttonTitle(.following), "Following…")
        XCTAssertEqual(CatalogPackWords.buttonTitle(.retry(failed: 2)), "Retry 2")
        XCTAssertEqual(CatalogPackWords.buttonTitle(.followedAll(8)), "Following all 8")
        XCTAssertEqual(CatalogPackWords.buttonTitle(.followRest(remaining: 3)), "Follow the other 3")
        XCTAssertEqual(CatalogPackWords.buttonTitle(.followAll(8)), "Follow all 8")
        XCTAssertEqual(CatalogPackWords.retryFootnote(failed: 1), "1 couldn't be reached. Check your connection.")
    }

    func testCardWords() {
        XCTAssertEqual(CatalogPackWords.cardAccessibilityLabel(title: "Tech, skeptically", summary: "What tech does.", footnote: "About 2 new a day · 4 shows"),
                       "Tech, skeptically. What tech does.. About 2 new a day · 4 shows")
        XCTAssertNil(CatalogPackWords.artworkOverflow(sourceCount: 6))
        XCTAssertNil(CatalogPackWords.artworkOverflow(sourceCount: 0))
        XCTAssertEqual(CatalogPackWords.artworkOverflow(sourceCount: 8), "+2")
        XCTAssertEqual(CatalogPackWords.notForMeRowTitle(hidden: 3), "Not for me (3)")
        XCTAssertEqual(CatalogPackWords.hiddenMessage(title: "Hard Fork"), "Hard Fork won't be suggested again.")
        XCTAssertEqual(CatalogPackWords.hiddenMessage(title: "  "), "It won't be suggested again.")
        XCTAssertEqual(CatalogPackWords.unfollowedToast(title: "Hard Fork"), "Unfollowed Hard Fork.")
        XCTAssertEqual(CatalogPackWords.showUndoAccessibilityLabel(showTitle: "Hard   Fork"), "Undo Not for me, Hard Fork")
    }

    func testHiddenOnReadsTheAbbreviatedDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_795_000_000) // 2026-11-18 UTC
        let words = CatalogPackWords.hiddenOn(date, calendar: calendar, locale: Locale(identifier: "en_US"))
        XCTAssertTrue(words.hasPrefix("Hidden Nov 18"), words)
    }

    // MARK: Hide reconcile

    func testAFollowedSourceIsCoveredByItsFeedKeyAndItsCatalogEntry() {
        let entries = [entry("a"), entry("b")]
        let catalog = catalog(entries, packs: nil)
        let subscriptions = [subscription("a", feed: "HTTP://Feeds.Example.com/a.xml/"), subscription("x", feed: "https://other.example.com/x")]
        let followed = NotForMeHideReconcile.followed(subscriptions: subscriptions, catalog: catalog, recordedSourceIds: ["b": "source-x"])
        XCTAssertEqual(followed.entryIds, ["a", "b"], "a by its feed key, b by the recorded follow")
        XCTAssertTrue(followed.feedKeys.contains(SourceCatalog.feedKey("https://feeds.example.com/a.xml")!))
        XCTAssertTrue(followed.feedKeys.contains(SourceCatalog.feedKey("https://other.example.com/x")!))
        let noCatalog = NotForMeHideReconcile.followed(subscriptions: subscriptions, catalog: nil, recordedSourceIds: [:])
        XCTAssertEqual(noCatalog.entryIds, [])
        XCTAssertEqual(noCatalog.feedKeys.count, 2)
        let recordedOnly = NotForMeHideReconcile.followed(subscriptions: subscriptions, catalog: nil,
                                                          recordedSourceIds: ["b": "source-x", "c": "source-gone"])
        XCTAssertEqual(recordedOnly.entryIds, ["b"], "with no catalog, a recorded follow still names its entry")
    }

    func testAHideRecordsTheRecordedEntryFirstThenTheFeedMatch() {
        let catalog = catalog([entry("a"), entry("b")], packs: nil)
        XCTAssertEqual(NotForMeHideReconcile.catalogEntryId(forFeedURL: "https://elsewhere.example.com/moved", sourceId: "s1",
                                                            catalog: catalog, recordedSourceIds: ["b": "s1"]), "b")
        XCTAssertEqual(NotForMeHideReconcile.catalogEntryId(forFeedURL: "https://feeds.example.com/a.xml/", sourceId: "s9",
                                                            catalog: catalog, recordedSourceIds: ["b": "s1"]), "a")
        XCTAssertNil(NotForMeHideReconcile.catalogEntryId(forFeedURL: "https://nowhere.example.com/x", sourceId: nil,
                                                          catalog: catalog, recordedSourceIds: [:]))
        XCTAssertNil(NotForMeHideReconcile.catalogEntryId(forFeedURL: "https://feeds.example.com/a.xml", sourceId: nil,
                                                          catalog: nil, recordedSourceIds: [:]))
    }

    /// The full store path: hide a source, follow it again, and the reconcile drops the hide; Undo can hide it again.
    func testFollowingAHiddenSourceAgainClearsTheHide() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pack-drawer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = NotForMeStore(fileURL: folder.appending(path: NotForMeStore.fileName))
        let catalog = catalog([entry("a"), entry("b")], packs: nil)
        try await store.hideSource(catalogEntryId: "a", feedURL: "https://feeds.example.com/a.xml", title: "Show a", artworkURL: nil)
        try await store.hideSource(catalogEntryId: nil, feedURL: "https://feeds.example.com/b.xml", title: "Show b", artworkURL: nil)

        // Not followed yet: nothing changes.
        var followed = NotForMeHideReconcile.followed(subscriptions: [], catalog: catalog, recordedSourceIds: [:])
        var dropped = try await store.removeHides(followedFeedKeys: followed.feedKeys, followedEntryIds: followed.entryIds)
        XCTAssertEqual(dropped, [])

        followed = NotForMeHideReconcile.followed(
            subscriptions: [subscription("a", feed: "https://feeds.example.com/a.xml/")], catalog: catalog, recordedSourceIds: [:])
        dropped = try await store.removeHides(followedFeedKeys: followed.feedKeys, followedEntryIds: followed.entryIds)
        XCTAssertEqual(dropped.map(\.title), ["Show a"])
        let snapshot = await store.snapshot()
        XCTAssertFalse(snapshot.isHidden(entry("a")))
        XCTAssertTrue(snapshot.isHidden(entry("b")))
    }

    // MARK: Done's pick order

    func testDoneLeadsWithTheFirstPickThatLandedAndKeepsTheRestInTapOrder() {
        XCTAssertEqual(FirstListenPickOrder.sourceIds(leading: "s2", settledInTapOrder: ["s2", "s3"]), ["s2", "s3"])
        XCTAssertEqual(FirstListenPickOrder.sourceIds(leading: "s3", settledInTapOrder: ["s1", "s3"]), ["s3", "s1"])
        XCTAssertEqual(FirstListenPickOrder.sourceIds(leading: nil, settledInTapOrder: []), [], "every pick failed: the Welcome sample")
        XCTAssertEqual(FirstListenPickOrder.sourceIds(leading: "s1", settledInTapOrder: []), ["s1"])
    }
}
