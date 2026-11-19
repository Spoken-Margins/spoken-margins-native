import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitFeeds

/// #4046 PR 5, the half that needs no screen: the lists a file holds, what importing them does to the listener's lists,
/// and what sharing one list or all follows writes.
final class OPMLImportPlannerListTests: XCTestCase {
    // MARK: Lists from the file

    func testListsComeFromFoldersAndFromCategoriesInFileOrder() throws {
        let document = try Self.parse("""
        <outline text="News"><outline type="rss" text="Daily" xmlUrl="https://a.example/daily"/><outline type="rss" text="Radiolab" xmlUrl="https://a.example/radiolab"/></outline>
        <outline text="Tech"><outline text="AI"><outline type="rss" text="Hard Fork" xmlUrl="https://a.example/hardfork"/></outline></outline>
        <outline type="rss" text="Darknet" xmlUrl="https://a.example/darknet" category="/Tech,/Night owls"/>
        <outline type="rss" text="Loose" xmlUrl="https://a.example/loose"/>
        """)
        let lists = OPMLImportPlanner.preview(document, existing: []).lists
        XCTAssertEqual(lists.map(\.name), ["News", "Tech", "AI", "Night owls"])
        XCTAssertEqual(lists.map(\.id), ["list:0", "list:1", "list:2", "list:3"])
        XCTAssertEqual(lists.map(\.showCount), [2, 2, 1, 1])
        XCTAssertEqual(lists[1].members.map(\.feedKey), ["https://a.example/hardfork", "https://a.example/darknet"])
        XCTAssertTrue(lists.allSatisfy { !$0.isMerge })
    }

    func testAFileWithNoFoldersOrCategoriesHasNoLists() throws {
        let document = try Self.parse(#"<outline type="rss" text="A" xmlUrl="https://a.example/a"/>"#)
        XCTAssertEqual(OPMLImportPlanner.preview(document, existing: []).lists, [])
    }

    func testOvercastsOwnFoldersAreNotLists() throws {
        let document = try Self.parse("""
        <outline text="feeds"><outline type="rss" text="A" xmlUrl="https://a.example/a"/><outline text="Tech"><outline type="rss" text="B" xmlUrl="https://a.example/b"/></outline></outline>
        <outline text="playlists"><outline type="rss" text="C" xmlUrl="https://a.example/c"/></outline>
        <outline type="rss" text="D" xmlUrl="https://a.example/d" category="/feeds"/>
        """)
        let lists = OPMLImportPlanner.preview(document, existing: []).lists
        XCTAssertEqual(lists.map(\.name), ["Tech", "feeds"], "a list the sender chose to call feeds is still a list")
        let nested = try Self.parse(#"<outline text="Work"><outline text="Feeds"><outline type="rss" text="E" xmlUrl="https://a.example/e"/></outline></outline>"#)
        XCTAssertEqual(OPMLImportPlanner.preview(nested, existing: []).lists.map(\.name), ["Work", "Feeds"], "only the outermost folder is Overcast's")
        XCTAssertEqual(lists[0].members.map(\.feedKey), ["https://a.example/b"])
        XCTAssertEqual(lists[1].members.map(\.feedKey), ["https://a.example/d"])
    }

    func testAListWithTheNameOfOneYouHaveSaysItAddsToIt() throws {
        let document = try Self.parse(#"<outline type="rss" text="A" xmlUrl="https://a.example/a" category="/news,/Café,/Other"/>"#)
        let mine = [FollowList(id: "mine-news", name: "  NEWS "), FollowList(id: "mine-cafe", name: "Cafe\u{0301}")]
        let lists = OPMLImportPlanner.preview(document, existing: [], existingLists: mine).lists
        XCTAssertEqual(lists.map(\.name), ["news", "Café", "Other"])
        XCTAssertEqual(lists.map(\.mergesIntoListId), ["mine-news", "mine-cafe", nil])
        XCTAssertEqual(lists.map(\.isMerge), [true, true, false])
    }

    func testNameNeighbourTable() throws {
        let long = String(repeating: "x", count: 41)
        let longer = String(repeating: "x", count: 60)
        let cases: [(attribute: String, names: [String])] = [
            ("/Tech/AI", ["Tech/AI"]),                                   // a slash inside a file's name stays
            ("/\(long)", [String(repeating: "x", count: 40)]),          // cut to 40 characters
            ("/\(long),/\(longer)", [String(repeating: "x", count: 40)]), // two that are the same once cut are one list
            ("/\(String(repeating: "é", count: 45))", [String(repeating: "é", count: 40)]),
            ("/\(String(repeating: "a", count: 39)) bcd", [String(repeating: "a", count: 39)]), // the cut leaves a space: trimmed
            ("/a   b", ["a b"]),                                          // a run of spaces is one
            ("/News,/news,/NEWS", ["News"]),
            ("/Caf\u{00E9},/Cafe\u{0301}", ["Caf\u{00E9}"]),
            ("/👩‍👩‍👧 family", ["👩‍👩‍👧 family"]),                                 // an emoji is one character
            (",,/,", []),
            ("", []),
            ("/\u{200B}", []),                                           // nothing visible
            ("/\u{FEFF}\u{200D}", []),
            ("/\u{200B}News\u{200B}", ["News"]),
            ("/a\u{200B}b", ["a b"]),                                 // Foundation counts a zero-width space as a break
            ("/\u{00AD}", []),
        ]
        for (attribute, names) in cases {
            let document = try Self.parse(#"<outline type="rss" text="A" xmlUrl="https://a.example/a" category="\#(attribute)"/>"#)
            let planned = OPMLImportPlanner.preview(document, existing: []).lists.map(\.name)
            XCTAssertEqual(planned, names, "category=\(attribute.debugDescription)")
            XCTAssertTrue(planned.allSatisfy { $0.count <= FollowListName.maxLength }, "category=\(attribute.debugDescription)")
        }
    }

    func testAFolderNameWithACommaBecomesTheNameTheExportWrites() throws {
        let document = try Self.parse(#"<outline text="Tech, AI"><outline type="rss" text="A" xmlUrl="https://a.example/a"/></outline>"#)
        let planned = try XCTUnwrap(OPMLImportPlanner.preview(document, existing: []).lists.first)
        XCTAssertEqual(planned.name, "Tech AI")
        XCTAssertFalse(planned.name.contains(","))
        // Shared and opened again it is the same list, not a second one.
        let sub = Self.subscription("s", "A", "https://a.example/a")
        let list = FollowList(id: "l", name: planned.name, members: planned.members)
        let back = try OPMLParser.parse(OPMLExporter.exportList(list, subscriptions: [sub]).data)
        let again = OPMLImportPlanner.preview(back, existing: [], existingLists: [list]).lists
        XCTAssertEqual(again.map(\.name), ["Tech AI"])
        XCTAssertEqual(again.map(\.mergesIntoListId), ["l"])
    }

    func testAShowRepeatedInTheFileJoinsEachOfItsListsOnce() throws {
        let document = try Self.parse("""
        <outline text="One"><outline type="rss" text="A" xmlUrl="http://A.example/a/" podcast:guid=" G-1 "/></outline>
        <outline text="Two"><outline type="rss" text="A again" xmlUrl="https://a.example/a"/></outline>
        <outline text="One"><outline type="rss" text="A third" xmlUrl="https://a.example/a"/></outline>
        <outline text="Bad"><outline type="rss" text="No link" xmlUrl="ftp://a.example/x"/></outline>
        """)
        let lists = OPMLImportPlanner.preview(document, existing: []).lists
        XCTAssertEqual(lists.map(\.name), ["One", "Two"], "a list holding only an unusable row is not offered")
        XCTAssertEqual(lists[0].members, [ListMember(feedKey: "https://a.example/a", podcastGUID: "G-1")])
        XCTAssertEqual(lists[1].members.map(\.feedKey), ["https://a.example/a"])
    }

    // MARK: What importing does to your lists

    private func apply(
        _ document: OPMLDocument, subscriptions: [FeedSubscription] = [], existing: [FollowList] = [],
        switchedOff: Set<String> = [], failing: Set<String> = [], notTried: Bool = false
    ) -> (preview: OPMLImportPreview, outcome: OPMLListImportResult) {
        let preview = OPMLImportPlanner.preview(document, existing: subscriptions, existingLists: existing)
        var result = OPMLImportResult()
        for candidate in preview.toFollow {
            let key = FeedURLKey.make(candidate.feed?.url ?? "") ?? ""
            if failing.contains(key) {
                result.failed.append(.init(candidate: candidate, reason: "nope"))
            } else if notTried {
                result.notTried.append(candidate)
            } else {
                result.followed.append(candidate)
            }
        }
        let keys = OPMLListImporter.followedFeedKeys(preview: preview, result: result)
        let on = Set(preview.lists.map(\.id)).subtracting(switchedOff)
        var next = 0
        let outcome = OPMLListImporter.apply(
            preview.lists, switchedOn: on, followedFeedKeys: keys, existing: existing,
            now: Date(timeIntervalSince1970: 5), makeId: { next += 1; return "new-\(next)" })
        return (preview, outcome)
    }

    private let twoLists = """
    <outline text="News"><outline type="rss" text="Daily" xmlUrl="https://a.example/daily"/><outline type="rss" text="Radiolab" xmlUrl="https://a.example/radiolab"/></outline>
    <outline text="Tech"><outline type="rss" text="Hard Fork" xmlUrl="https://a.example/hardfork"/></outline>
    """

    func testFollowingEverythingMakesEveryListSwitchedOn() throws {
        let (_, outcome) = apply(try Self.parse(twoLists))
        XCTAssertEqual(outcome.lists.map(\.name), ["News", "Tech"])
        XCTAssertEqual(outcome.lists.map(\.id), ["new-1", "new-2"])
        XCTAssertEqual(outcome.lists[0].members.map(\.feedKey), ["https://a.example/daily", "https://a.example/radiolab"])
        XCTAssertEqual(outcome.lists[0].createdAt, Date(timeIntervalSince1970: 5))
        XCTAssertEqual([outcome.createdCount, outcome.mergedCount, outcome.skippedEmptyCount], [2, 0, 0])
    }

    func testAListSwitchedOffIsNotMade() throws {
        let (preview, outcome) = apply(try Self.parse(twoLists), switchedOff: ["list:1"])
        XCTAssertEqual(preview.lists.map(\.id), ["list:0", "list:1"])
        XCTAssertEqual(outcome.lists.map(\.name), ["News"])
        XCTAssertEqual(outcome.skippedEmptyCount, 0, "switched off is not the same as empty")
    }

    func testEveryShowAlreadyFollowedStillImportsTheLists() throws {
        let followed = [Self.subscription("s1", "Daily", "https://a.example/daily"), Self.subscription("s2", "Radiolab", "https://a.example/radiolab"),
                        Self.subscription("s3", "Hard Fork", "http://A.example/hardfork/")]
        let (preview, outcome) = apply(try Self.parse(twoLists), subscriptions: followed)
        XCTAssertTrue(preview.toFollow.isEmpty, "the button reads Add lists: no show needs following")
        XCTAssertEqual(outcome.lists.map(\.name), ["News", "Tech"])
        XCTAssertEqual(outcome.lists[1].members.map(\.feedKey), ["https://a.example/hardfork"])
    }

    func testAFailedFollowLeavesThatShowOutOfTheListAndAnEmptyListIsNotMade() throws {
        let (_, partial) = apply(try Self.parse(twoLists), failing: ["https://a.example/radiolab"])
        XCTAssertEqual(partial.lists.first?.members.map(\.feedKey), ["https://a.example/daily"])
        let (_, none) = apply(try Self.parse(twoLists), failing: ["https://a.example/hardfork"])
        XCTAssertEqual(none.lists.map(\.name), ["News"])
        XCTAssertEqual(none.skippedEmptyCount, 1)
        let (_, stopped) = apply(try Self.parse(twoLists), notTried: true)
        XCTAssertEqual(stopped.lists, [], "stopped before any follow: nothing to put in a list")
        XCTAssertEqual(stopped.skippedEmptyCount, 2)
    }

    func testAListWithTheNameOfOneYouHaveAddsToItAndKeepsItsIdAndOrder() throws {
        let mine = FollowList(id: "mine", name: "news", createdAt: Date(timeIntervalSince1970: 1),
                              members: [ListMember(feedKey: "https://a.example/old"), ListMember(feedKey: "https://a.example/daily")])
        let (_, outcome) = apply(try Self.parse(twoLists), existing: [mine])
        XCTAssertEqual(outcome.lists.map(\.id), ["mine", "new-1"])
        XCTAssertEqual(outcome.lists[0].name, "news", "your name stays")
        XCTAssertEqual(outcome.lists[0].createdAt, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(outcome.lists[0].members.map(\.feedKey),
                       ["https://a.example/old", "https://a.example/daily", "https://a.example/radiolab"])
        XCTAssertEqual([outcome.createdCount, outcome.mergedCount], [1, 1])
    }

    func testAMergeThatChangesNothingIsNotReturned() throws {
        let mine = FollowList(id: "mine", name: "News",
                              members: [ListMember(feedKey: "https://a.example/daily"), ListMember(feedKey: "https://a.example/radiolab")])
        let (_, outcome) = apply(try Self.parse(twoLists), existing: [mine])
        XCTAssertEqual(outcome.lists.map(\.name), ["Tech"])
        XCTAssertEqual(outcome.mergedCount, 0)
    }

    func testAGUIDFromTheFileImprovesAMemberWithoutAddingARow() throws {
        let document = try Self.parse(#"<outline type="rss" text="A" xmlUrl="https://a.example/a" category="/News" podcast:guid="G-9"/>"#)
        let mine = FollowList(id: "mine", name: "News", members: [ListMember(feedKey: "https://a.example/a")])
        let (_, outcome) = apply(document, existing: [mine])
        XCTAssertEqual(outcome.lists.first?.members, [ListMember(feedKey: "https://a.example/a", podcastGUID: "G-9")])
        XCTAssertEqual(outcome.mergedCount, 1)
    }

    func testAListMadeWhileTheScreenWasOpenIsMergedNotDuplicated() throws {
        let document = try Self.parse(twoLists)
        let preview = OPMLImportPlanner.preview(document, existing: [], existingLists: [])
        XCTAssertFalse(preview.lists[0].isMerge)
        let madeMeanwhile = FollowList(id: "late", name: "NEWS")
        let outcome = OPMLListImporter.apply(
            preview.lists, switchedOn: ["list:0"], followedFeedKeys: ["https://a.example/daily"], existing: [madeMeanwhile])
        XCTAssertEqual(outcome.lists.map(\.id), ["late"])
        XCTAssertEqual(outcome.lists.first?.members.map(\.feedKey), ["https://a.example/daily"])
    }

    func testTheListsAreOnlyEverMadeFromFollowedShows() throws {
        // A show of a switched-on list that was not ticked, and so not followed, is not in the list.
        let document = try Self.parse(twoLists)
        let preview = OPMLImportPlanner.preview(document, existing: [])
        var result = OPMLImportResult()
        result.followed = [preview.toFollow[0]]
        let keys = OPMLListImporter.followedFeedKeys(preview: preview, result: result)
        XCTAssertEqual(keys, ["https://a.example/daily"])
        let outcome = OPMLListImporter.apply(preview.lists, switchedOn: ["list:0", "list:1"], followedFeedKeys: keys, existing: [])
        XCTAssertEqual(outcome.lists.map(\.name), ["News"])
        XCTAssertEqual(outcome.lists[0].members.map(\.feedKey), ["https://a.example/daily"])
    }

    // MARK: What sharing writes

    func testShareListWritesOnlyThatListsShowsWithTheListAsCategory() throws {
        let subs = [Self.subscription("s1", "Daily", "https://a.example/daily"), Self.subscription("s2", "Radiolab", "https://a.example/radiolab"),
                    Self.subscription("s3", "Moved", "https://new.example/moved"), Self.subscription("s4", "Other", "https://a.example/other")]
        let list = FollowList(id: "l", name: "Commute", members: [
            ListMember(feedKey: "https://a.example/daily"), ListMember(feedKey: "https://old.example/moved", podcastGUID: "G-moved")])
        let export = OPMLExporter.exportList(list, subscriptions: subs, podcastGUIDs: ["s3": "g-MOVED"])
        let parsed = try OPMLParser.parse(export.data)
        XCTAssertEqual(parsed.title, "Commute")
        XCTAssertEqual(parsed.feeds.map(\.title), ["Daily", "Moved"], "the show that moved hosts is found by its GUID")
        XCTAssertEqual(parsed.feeds.map(\.categories), [["Commute"], ["Commute"]], "no other list leaks out of the file")
        XCTAssertEqual(export.exportedCount, 2)
    }

    func testAShowWhoseGUIDIsALinkTheExportRefusesIsStillFoundByItsFeedLink() throws {
        // The export drops a link-shaped GUID it would not share. Membership uses the GUID the file would carry, so the show is
        // in the file with its category (found by its feed link) and the GUID stays out of it.
        let sub = Self.subscription("s", "Show", "https://a.example/show")
        let list = FollowList(id: "l", name: "Mine", members: [ListMember(feedKey: "https://a.example/show")])
        let export = OPMLExporter.exportList(list, subscriptions: [sub], podcastGUIDs: ["s": "https://www.patreon.com/rss/secretsecretsecret"])
        let text = String(decoding: export.data, as: UTF8.self)
        XCTAssertFalse(text.contains("secretsecret"))
        XCTAssertEqual(try OPMLParser.parse(export.data).feeds.map(\.categories), [["Mine"]])
        // A list that holds the show only by that GUID cannot find it, and the file is empty rather than leaking the GUID.
        let byGUID = FollowList(id: "g", name: "ByGUID", members: [ListMember(feedKey: "https://old.example/show", podcastGUID: "https://www.patreon.com/rss/secretsecretsecret")])
        let none = OPMLExporter.exportList(byGUID, subscriptions: [sub], podcastGUIDs: ["s": "https://www.patreon.com/rss/secretsecretsecret"])
        XCTAssertEqual(none.exportedCount, 0)
        XCTAssertFalse(String(decoding: none.data, as: UTF8.self).contains("secretsecret"))
    }

    func testShareListLeavesPrivateFeedsOut() throws {
        let secret = "https://example.com/feed?token=abc123secret"
        let subs = [Self.subscription("s1", "Members only", secret), Self.subscription("s2", "Open", "https://example.com/open.xml")]
        let list = FollowList(id: "l", name: "Mixed", members: [ListMember(feedKey: FeedURLKey.make(secret) ?? ""), ListMember(feedKey: "https://example.com/open.xml")])
        let export = OPMLExporter.exportList(list, subscriptions: subs)
        let text = String(decoding: export.data, as: UTF8.self)
        XCTAssertEqual(export.withheldPrivateCount, 1)
        XCTAssertFalse(text.contains("abc123secret"))
        XCTAssertFalse(text.contains("Members only"))
        XCTAssertEqual(try OPMLParser.parse(export.data).feeds.map(\.title), ["Open"])
    }

    func testExportAllFollowsKeepsEveryShowAndEveryList() throws {
        let subs = [Self.subscription("s1", "Daily", "https://a.example/daily"), Self.subscription("s2", "Loose", "https://a.example/loose"),
                    Self.subscription("s3", "Both", "https://a.example/both")]
        let lists = [
            FollowList(id: "a", name: "News", members: [ListMember(feedKey: "https://a.example/daily"), ListMember(feedKey: "https://a.example/both")]),
            FollowList(id: "b", name: "Commute", members: [ListMember(feedKey: "https://a.example/both")]),
        ]
        let export = OPMLExporter.exportAllFollows(subs, lists: lists)
        XCTAssertEqual(OPMLExporter.allFollowsFileName, "Following.opml")
        let parsed = try OPMLParser.parse(export.data)
        XCTAssertEqual(parsed.feeds.map(\.title), ["Both", "Daily", "Loose"])
        XCTAssertEqual(parsed.feeds.map(\.categories), [["Commute", "News"], ["News"], []])
    }

    func testAListSharedAndOpenedComesBackAsTheSameList() throws {
        let subs = [Self.subscription("s1", "Daily", "https://a.example/daily"), Self.subscription("s2", "Radiolab", "https://a.example/radiolab")]
        let list = FollowList(id: "l", name: "Commute", members: subs.map { ListMember(feedKey: FeedURLKey.make($0.source.canonicalURL) ?? "") })
        let parsed = try OPMLParser.parse(OPMLExporter.exportList(list, subscriptions: subs).data)
        let preview = OPMLImportPlanner.preview(parsed, existing: [])
        XCTAssertEqual(preview.lists.map(\.name), ["Commute"])
        XCTAssertEqual(Set(preview.lists[0].members.map(\.feedKey)), Set(list.members.map(\.feedKey)))
    }

    func testFileNameTable() {
        let cases: [(String, String)] = [
            ("Commute", "Commute.opml"),
            ("Tech/AI", "Tech AI.opml"),
            ("a:b*c?d", "a b c d.opml"),
            ("  .hidden  ", "hidden.opml"),
            ("...", "List.opml"),
            ("///", "List.opml"),
            ("", "List.opml"),
            ("Line\nbreak", "Line break.opml"),
            ("Café 👩‍👩‍👧", "Café 👩‍👩‍👧.opml"),
            ("a/\u{0301}b", "a b.opml"),                // a separator with a combining mark is still a separator
            ("a:\u{FE0F}b", "a b.opml"),
            ("\u{200B}", "List.opml"),
            ("x\\y", "x y.opml"),
        ]
        for (name, file) in cases {
            XCTAssertEqual(OPMLExporter.fileName(forList: FollowList(id: "x", name: name)), file, "name=\(name.debugDescription)")
        }
    }

    // MARK: Fixtures

    private static func parse(_ body: String) throws -> OPMLDocument {
        try OPMLParser.parse(Data(#"<?xml version="1.0"?><opml version="2.0" xmlns:podcast="https://podcastindex.org/namespace/1.0"><head><title>t</title></head><body>\#(body)</body></opml>"#.utf8))
    }

    private static func subscription(_ id: String, _ title: String, _ url: String) -> FeedSubscription {
        FeedSubscription(
            id: id,
            source: SourceIdentity(id: "source-\(id)", kind: .podcastFeed, canonicalURL: url, host: URL(string: url)?.host ?? "example.com", title: title),
            createdAt: Date(timeIntervalSince1970: 1))
    }
}
