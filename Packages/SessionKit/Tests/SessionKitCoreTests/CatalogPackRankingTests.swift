import Foundation
import XCTest
@testable import SessionKit

/// Which packs show, in what order, and which sources lead each one (#4285, PR 2).
final class CatalogPackRankingTests: XCTestCase {
    // MARK: Fixtures

    private func entry(_ id: String, _ kind: SourceContentKind = .podcast, author: String? = nil, subjects: [String] = ["science"]) -> SourceCatalogEntry {
        SourceCatalogEntry(
            id: id, kind: kind == .podcast ? .podcastFeed : .articleFeed, contentKind: kind, title: "Show \(id)", author: author,
            feedURL: "https://feeds.example.com/\(id).xml", subjects: subjects, provenanceIds: ["p"]
        )
    }

    private func catalog(_ entries: [SourceCatalogEntry], packs: [SourceCatalogPack]) -> SourceCatalog {
        SourceCatalog(
            schemaVersion: SourceCatalog.currentSchemaVersion, catalogId: "c", contentVersion: 1, title: "C",
            generatedAt: "2026-11-14T12:00:00Z", locale: nil, provenance: [], subjects: [], starterRows: nil, packs: packs, entries: entries
        )
    }

    private func key(_ id: String) -> String { SourceCatalog.feedKey("https://feeds.example.com/\(id).xml")! }

    private func marks(_ counts: [String: Int]) -> NotForMeSnapshot {
        NotForMeSnapshot(marksByFeedKey: Dictionary(uniqueKeysWithValues: counts.map { (key($0.key), $0.value) }))
    }

    private func ids(_ entries: [SourceCatalogEntry]) -> [String] { entries.map(\.id) }

    /// Six podcasts and two newsletters, all in one pack, all on "science".
    private func standardCatalog() -> (SourceCatalog, SourceCatalogPack) {
        let entries = ["p1", "p2", "p3", "p4", "p5", "p6"].map { entry($0) } + ["n1", "n2"].map { entry($0, .newsletter) }
        let pack = SourceCatalogPack(id: "pack", title: "Pack", summary: "S", entryIds: entries.map(\.id))
        return (catalog(entries, packs: [pack]), pack)
    }

    // MARK: Hide and marks lookups

    func testAHideMatchesByEntryIdOrByFeedKeyAndNeverByTitle() {
        let a = entry("a")
        XCTAssertFalse(NotForMeSnapshot.empty.isHidden(a))
        XCTAssertTrue(NotForMeSnapshot(hiddenEntryIds: ["a"]).isHidden(a))
        XCTAssertTrue(NotForMeSnapshot(hiddenFeedKeys: [key("a")]).isHidden(a), "the id may have changed in a later catalog")
        XCTAssertFalse(NotForMeSnapshot(hiddenEntryIds: ["ab", "A"]).isHidden(a))
        // The feed key folds scheme, host and a trailing slash, not the path's case.
        var upper = a
        upper.feedURL = "HTTP://Feeds.Example.com/a.xml/"
        XCTAssertTrue(NotForMeSnapshot(hiddenFeedKeys: [key("a")]).isHidden(upper))
        upper.feedURL = "https://feeds.example.com/A.xml"
        XCTAssertFalse(NotForMeSnapshot(hiddenFeedKeys: [key("a")]).isHidden(upper))
        XCTAssertEqual(marks(["a": 2]).marks(for: a), 2)
        XCTAssertEqual(marks(["a": -4]).marks(for: a), 0)
    }

    // MARK: Source weight

    func testTheWeightTermsOneAtATime() {
        let target = entry("t", author: "Ann", subjects: ["science", "history"])
        let sameAuthor = entry("sa", author: "  ANN ", subjects: ["news"])
        let sameKind = entry("sk", author: "Bo", subjects: ["news"])
        let otherKind = entry("ok", .newsletter, author: "Bo", subjects: ["news"])
        let oneSubject = entry("s1", .newsletter, author: "Bo", subjects: ["science", "news"])
        let twoSubjects = entry("s2", .newsletter, author: "Bo", subjects: ["history", "science"])
        let nobodyAuthor = entry("na", .newsletter, author: nil, subjects: ["news"])
        let blankAuthors = entry("ba", .newsletter, author: "  ", subjects: ["news"])
        let members = [target, sameAuthor, sameKind, otherKind, oneSubject, twoSubjects, nobodyAuthor, blankAuthors]

        func weight(hiding other: String) -> Int {
            CatalogPackRanking.weight(of: target, among: members, notForMe: NotForMeSnapshot(hiddenEntryIds: [other]))
        }
        XCTAssertEqual(weight(hiding: "sa"), 2 + 1, "the same author counts 2, and the same content kind 1; no shared subject")
        XCTAssertEqual(weight(hiding: "sk"), 1, "the same content kind alone")
        XCTAssertEqual(weight(hiding: "ok"), 0, "nothing shared")
        XCTAssertEqual(weight(hiding: "s1"), 1, "one shared subject")
        XCTAssertEqual(weight(hiding: "s2"), 2, "two shared subjects")
        XCTAssertEqual(weight(hiding: "na"), 0)
        XCTAssertEqual(weight(hiding: "ba"), 0)
        XCTAssertEqual(CatalogPackRanking.weight(of: target, among: members, notForMe: .empty), 0, "nothing hidden or marked")
    }

    func testAnUnrelatedPairWithNoAuthorsDoesNotCountAsTheSameAuthor() {
        let a = entry("a", author: nil)
        let b = entry("b", author: nil)
        XCTAssertEqual(CatalogPackRanking.similarity(a, b), 1 + 1, "same kind and the one shared subject, no author match")
    }

    func testMarksOnOneSourceAreCappedAtThree() {
        let a = entry("a"), b = entry("b")
        for (count, expected) in [(0, 0), (1, 1), (2, 2), (3, 3), (4, 3), (50, 3)] {
            XCTAssertEqual(CatalogPackRanking.weight(of: a, among: [a, b], notForMe: marks(["a": count])), expected, "\(count) marks on the source itself")
        }
    }

    func testAnotherSourcesMarksCountItsCappedMarksTimesHowAlikeTheTwoAre() {
        let a = entry("a"), b = entry("b") // alike by 1 (kind) + 1 (subject) = 2
        for (count, expected) in [(1, 2), (2, 4), (3, 6), (4, 6), (10, 6)] {
            XCTAssertEqual(CatalogPackRanking.weight(of: a, among: [a, b], notForMe: marks(["b": count])), expected, "\(count) marks on the other")
        }
        XCTAssertEqual(CatalogPackRanking.weight(of: a, among: [a, b], notForMe: NotForMeSnapshot(hiddenEntryIds: ["b"])), 2, "a hidden source counts once")
        XCTAssertEqual(
            CatalogPackRanking.weight(of: a, among: [a, b], notForMe: NotForMeSnapshot(hiddenEntryIds: ["b"], marksByFeedKey: [key("b"): 3])), 2,
            "hidden wins over marks: 1, not 3"
        )
    }

    // MARK: Source order

    func testSourcesKeepTheOrderThePackNamesThemWhenNothingIsHiddenOrMarked() {
        let (catalog, pack) = standardCatalog()
        XCTAssertEqual(ids(CatalogPackRanking.visibleSources(of: pack, in: catalog, notForMe: .empty)), ["p1", "p2", "p3", "p4", "p5", "p6", "n1", "n2"])
    }

    func testPodcastsComeBeforeNewslettersEvenWhenWeightWouldPutANewsletterFirst() {
        var (catalog, pack) = standardCatalog()
        // Name the newsletters first in the pack; give each of four podcasts 3 marks, so podcasts weigh far more than the newsletters.
        pack.entryIds = ["n1", "n2", "p1", "p2", "p3", "p4"]
        catalog.packs = [pack]
        let snapshot = marks(["p1": 3, "p2": 3, "p3": 3, "p4": 3])
        let order = ids(CatalogPackRanking.visibleSources(of: pack, in: catalog, notForMe: snapshot))
        XCTAssertEqual(Array(order.prefix(4).sorted()), ["p1", "p2", "p3", "p4"])
        XCTAssertEqual(Array(order.suffix(2)), ["n1", "n2"])
    }

    func testHeavierSourcesMoveDownWithinTheirGroupAndTiesKeepThePacksOrder() {
        let (catalog, pack) = standardCatalog()
        // The Design's formula, followed as written: p2 marked 3 times weighs its own 3; every podcast alike to it
        // (same kind, one shared subject) weighs 3 * 2 = 6, and each newsletter (one shared subject) 3 * 1 = 3.
        // So the alike sources sink below the marked one. That is the Design's rule; see the note on #4285.
        let order = ids(CatalogPackRanking.visibleSources(of: pack, in: catalog, notForMe: marks(["p2": 3])))
        XCTAssertEqual(order, ["p2", "p1", "p3", "p4", "p5", "p6", "n1", "n2"], "ties keep the pack's order within each group")
        XCTAssertEqual(CatalogPackRanking.weight(of: entry("p1"), among: CatalogPackRanking.members(of: pack, in: catalog), notForMe: marks(["p2": 3])), 6)
        XCTAssertEqual(CatalogPackRanking.weight(of: entry("p2"), among: CatalogPackRanking.members(of: pack, in: catalog), notForMe: marks(["p2": 3])), 3)
        XCTAssertEqual(CatalogPackRanking.weight(of: entry("n1", .newsletter), among: CatalogPackRanking.members(of: pack, in: catalog), notForMe: marks(["p2": 3])), 3)
    }

    func testAHiddenSourceLeavesTheListAndPushesAlikeSourcesDown() {
        let a = entry("a", author: "Ann"), b = entry("b", author: "Ann"), c = entry("c", author: "Cy"), d = entry("d", author: "Di")
        let pack = SourceCatalogPack(id: "p", title: "P", summary: "S", entryIds: ["a", "b", "c", "d"])
        let cat = catalog([a, b, c, d], packs: [pack])
        // Hiding d (author Di) pushes a, b and c down equally by 1 + 1 each: ties, so the pack's order stays.
        XCTAssertEqual(ids(CatalogPackRanking.visibleSources(of: pack, in: cat, notForMe: NotForMeSnapshot(hiddenEntryIds: ["d"]))), ["a", "b", "c"])
        // Hiding a (author Ann) pushes b (same author, 2 + 1 + 1 = 4) below c (1 + 1 = 2).
        XCTAssertEqual(ids(CatalogPackRanking.visibleSources(of: pack, in: cat, notForMe: NotForMeSnapshot(hiddenEntryIds: ["a"]))), ["c", "d", "b"])
    }

    func testTiesKeepThePacksOwnOrderNotTheOrderOfTheCatalogsEntries() {
        let a = entry("a"), b = entry("b"), c = entry("c")
        let pack = SourceCatalogPack(id: "p", title: "P", summary: "S", entryIds: ["c", "a", "b"])
        let cat = catalog([a, b, c], packs: [pack]) // the catalog lists a, b, c
        XCTAssertEqual(ids(CatalogPackRanking.visibleSources(of: pack, in: cat, notForMe: .empty)), ["c", "a", "b"])
    }

    func testAPackNamingAnIdTheCatalogLacksSkipsIt() {
        let a = entry("a")
        let pack = SourceCatalogPack(id: "p", title: "P", summary: "S", entryIds: ["ghost", "a"])
        XCTAssertEqual(ids(CatalogPackRanking.members(of: pack, in: catalog([a], packs: [pack]))), ["a"])
    }

    // MARK: Pack order and visibility

    func testPacksKeepCatalogOrderUntilTheListenerPushesOneAway() {
        let entries = (1...12).map { entry("e\($0)", subjects: ["s\($0)"]) }
        let packs = (0..<3).map { index in
            SourceCatalogPack(id: "pack\(index)", title: "P\(index)", summary: "S", entryIds: entries[(index * 4)..<(index * 4 + 4)].map(\.id))
        }
        let cat = catalog(entries, packs: packs)
        XCTAssertEqual(CatalogPackRanking.visiblePacks(in: cat, notForMe: .empty).map(\.id), ["pack0", "pack1", "pack2"])
        // One hidden source in pack0 and a mark on pack1: pack2 (nothing) first, then pack1 (1) and pack0 (1) in catalog order.
        let snapshot = NotForMeSnapshot(hiddenEntryIds: ["e1"], marksByFeedKey: [key("e5"): 1])
        XCTAssertEqual(CatalogPackRanking.visiblePacks(in: cat, notForMe: snapshot).map(\.id), ["pack2", "pack0", "pack1"])
        // Marks cap at 3 per source: pack0 has 4 pushed away (3 hidden + 1 more mark) and pack1 one source with 9 marks.
        // Capped, pack1 counts 3 and sorts before pack0 (4); uncapped it would count 9 and sort after it.
        let capped = NotForMeSnapshot(hiddenEntryIds: ["e1", "e2", "e3"], marksByFeedKey: [key("e4"): 1, key("e5"): 9])
        XCTAssertEqual(CatalogPackRanking.visiblePacks(in: cat, notForMe: capped).map(\.id), ["pack2", "pack1", "pack0"])
        // A source both hidden and marked counts 1 + its capped marks against its pack.
        let both = NotForMeSnapshot(hiddenEntryIds: ["e5"], marksByFeedKey: [key("e5"): 2, key("e1"): 2])
        XCTAssertEqual(CatalogPackRanking.visiblePacks(in: cat, notForMe: both).map(\.id), ["pack2", "pack0", "pack1"], "pack0 has 2, pack1 has 3")
    }

    func testAPackWithEveryMemberHiddenLeavesTheList() {
        let (cat, pack) = standardCatalog()
        let everyone = NotForMeSnapshot(hiddenEntryIds: Set(pack.entryIds))
        XCTAssertEqual(CatalogPackRanking.visiblePacks(in: cat, notForMe: everyone), [])
        XCTAssertEqual(CatalogPackRanking.startChip(in: cat, notForMe: everyone), .top)
        let allButOne = NotForMeSnapshot(hiddenEntryIds: Set(pack.entryIds.dropLast()))
        XCTAssertEqual(CatalogPackRanking.visiblePacks(in: cat, notForMe: allButOne).map(\.id), ["pack"])
        XCTAssertEqual(ids(CatalogPackRanking.visibleSources(of: pack, in: cat, notForMe: allButOne)), ["n2"])
    }

    func testAHiddenSourceStillCountsAgainstItsPack() {
        let (cat, pack) = standardCatalog()
        let snapshot = NotForMeSnapshot(hiddenEntryIds: ["p1"])
        XCTAssertEqual(CatalogPackRanking.members(of: pack, in: cat).count, 8, "membership is the pack's full list, hidden or not")
        XCTAssertEqual(CatalogPackRanking.visibleSources(of: pack, in: cat, notForMe: snapshot).count, 7)
    }

    func testTheStartChipIsPacksOnlyWhenThereIsAVisiblePack() {
        let (cat, _) = standardCatalog()
        XCTAssertEqual(CatalogPackRanking.startChip(in: cat, notForMe: .empty), .packs)
        var none = cat
        none.packs = nil
        XCTAssertEqual(CatalogPackRanking.startChip(in: none, notForMe: .empty), .top)
        none.packs = []
        XCTAssertEqual(CatalogPackRanking.startChip(in: none, notForMe: .empty), .top)
    }

    // MARK: Follow all

    func testFollowAllFollowsVisibleUnfollowedSourcesPodcastFirstEvenWhenAWeightWouldPutANewsletterFirst() {
        var (cat, pack) = standardCatalog()
        // The pack names a newsletter first, and a mark on a podcast would weigh the other podcasts down.
        pack.entryIds = ["n1", "p1", "p2", "n2", "p3", "p4", "p5", "p6"]
        cat.packs = [pack]
        let order = CatalogPackRanking.followAllOrder(of: pack, in: cat, notForMe: marks(["p1": 3]), followedEntryIds: [])
        XCTAssertEqual(order.first?.contentKind, .podcast, "Done's first listen is a podcast when the pack has one")
        XCTAssertEqual(ids(order).suffix(2).sorted(), ["n1", "n2"])
        let plain = CatalogPackRanking.followAllOrder(of: pack, in: cat, notForMe: .empty, followedEntryIds: [])
        XCTAssertEqual(ids(plain), ["p1", "p2", "p3", "p4", "p5", "p6", "n1", "n2"], "podcasts in the pack's order, then newsletters in it")
        let someDone = CatalogPackRanking.followAllOrder(
            of: pack, in: cat, notForMe: NotForMeSnapshot(hiddenEntryIds: ["p2"]), followedEntryIds: ["p1", "n1"]
        )
        XCTAssertEqual(ids(someDone), ["p3", "p4", "p5", "p6", "n2"], "hidden and already-followed sources are left out")
        XCTAssertEqual(CatalogPackRanking.followAllOrder(of: pack, in: cat, notForMe: .empty, followedEntryIds: Set(pack.entryIds)), [])
    }

    // MARK: Button

    func testTheButtonStatesAndTheirPrecedence() {
        let all = ["a", "b", "c", "d"]
        func state(_ states: [String: CatalogDrawerFollowState], _ visible: [String] = all) -> CatalogPackButtonState {
            CatalogPackRanking.buttonState(visibleSourceIds: visible, states: states)
        }
        XCTAssertEqual(state([:]), .followAll(4))
        XCTAssertEqual(state(["a": .followed]), .followRest(remaining: 3))
        XCTAssertEqual(state(["a": .followed, "b": .followed, "c": .followed]), .followRest(remaining: 1))
        XCTAssertEqual(state(["a": .followed, "b": .followed, "c": .followed, "d": .followed]), .followedAll(4))
        XCTAssertEqual(state(["a": .following]), .following)
        XCTAssertEqual(state(["a": .failed("offline")]), .retry(failed: 1))
        XCTAssertEqual(state(["a": .failed("x"), "b": .failed("y"), "c": .followed]), .retry(failed: 2))
        // Precedence: in flight beats failed beats followed.
        XCTAssertEqual(state(["a": .following, "b": .failed("x"), "c": .followed]), .following)
        XCTAssertEqual(state(["a": .failed("x"), "b": .followed, "c": .followed, "d": .followed]), .retry(failed: 1))
        // A state for an entry not in this pack's visible list is ignored.
        XCTAssertEqual(state(["z": .following, "y": .failed("x"), "a": .followed]), .followRest(remaining: 3))
        // Fewer visible sources: "all" means all of those.
        XCTAssertEqual(state(["a": .followed, "b": .followed], ["a", "b"]), .followedAll(2))
        XCTAssertEqual(state([:], []), .followAll(0), "an empty pack is not shown, so this is never drawn")
    }

    // MARK: Pace

    func testAPacksPaceSumsItsVisibleSourcesAndLeavesHiddenOnesOut() throws {
        var entries = ["p1", "p2", "p3", "p4"].map { entry($0) }
        // Generated at 2026-11-14T12:00Z; each source: 8 dates a week apart or a day apart.
        entries[0].recentPublishedAt = (0...7).map { String(format: "2026-11-%02dT08:00:00Z", 14 - $0) } // 8 over 7.17 days
        entries[1].recentPublishedAt = ["2026-11-14T08:00:00Z", "2026-11-07T08:00:00Z"]                 // 2 over 7.17 days
        entries[2].recentPublishedAt = nil
        entries[3].recentPublishedAt = (0...7).map { String(format: "2026-11-%02dT08:00:00Z", 14 - $0) }
        let pack = SourceCatalogPack(id: "p", title: "P", summary: "S", entryIds: entries.map(\.id))
        let cat = catalog(entries, packs: [pack])
        let all = try XCTUnwrap(CatalogPackRanking.packPace(of: pack, in: cat, notForMe: .empty))
        let eight = 8 * 7 / (7 + 4.0 / 24), two = 2 * 7 / (7 + 4.0 / 24)
        XCTAssertEqual(all.itemsPerWeek, eight + two + eight, accuracy: 1e-9, "the source with no dates adds nothing; 3 of 4 known is enough")
        let hidden = try XCTUnwrap(CatalogPackRanking.packPace(of: pack, in: cat, notForMe: NotForMeSnapshot(hiddenEntryIds: ["p4"])))
        XCTAssertEqual(hidden.itemsPerWeek, eight + two, accuracy: 1e-9, "a hidden source's rate leaves the pack's pace")
        // Hide p1 and p4: p2 (known) and p3 (no dates) are left, so exactly half are known and the pace is two.
        let half = try XCTUnwrap(CatalogPackRanking.packPace(of: pack, in: cat, notForMe: NotForMeSnapshot(hiddenEntryIds: ["p1", "p4"])))
        XCTAssertEqual(half.itemsPerWeek, two, accuracy: 1e-9)
        // Hide p1, p2 and p4: only p3, with no dates, is left, so nothing is known.
        XCTAssertNil(CatalogPackRanking.packPace(of: pack, in: cat, notForMe: NotForMeSnapshot(hiddenEntryIds: ["p1", "p2", "p4"])))
    }

    func testANonFiniteRateReadsAsUnknownRatherThanCrashing() {
        for rate in [Double.nan, .infinity, -.infinity] {
            let measure = CatalogPackPace.Measure(itemsPerWeek: rate, newestIsStale: false)
            XCTAssertEqual(CatalogPackPace.packWords(measure), "Pace not known yet")
            XCTAssertNil(CatalogPackPace.rowWords(measure))
        }
    }

    // MARK: Words

    func testTheFootnoteNamesOnlyThePartsThatExist() {
        let (cat, pack) = standardCatalog()
        let sources = CatalogPackRanking.visibleSources(of: pack, in: cat, notForMe: .empty)
        let pace = CatalogPackPace.Measure(itemsPerWeek: 14, newestIsStale: false)
        XCTAssertEqual(CatalogPackRanking.footnote(pace: pace, visibleSources: sources), "About 2 new a day · 6 shows, 2 newsletters")
        XCTAssertEqual(CatalogPackRanking.footnote(pace: nil, visibleSources: sources), "Pace not known yet · 6 shows, 2 newsletters")
        XCTAssertEqual(CatalogPackRanking.footnote(pace: pace, visibleSources: Array(sources.prefix(1))), "About 2 new a day · 1 show")
        XCTAssertEqual(CatalogPackRanking.footnote(pace: pace, visibleSources: Array(sources.suffix(1))), "About 2 new a day · 1 newsletter")
        XCTAssertEqual(CatalogPackRanking.footnote(pace: pace, visibleSources: []), "About 2 new a day")
        XCTAssertEqual(CatalogPackRanking.footnote(pace: pace, visibleSources: [sources[0], sources[6]]), "About 2 new a day · 1 show, 1 newsletter")
    }
}
