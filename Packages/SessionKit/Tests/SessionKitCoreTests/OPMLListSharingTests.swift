import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitFeeds

/// #4046 PR 5, 8 and 13: a shared list round-trips its includes and, when switched on, its rules; the import screen offers
/// them; imported rules arrive switched off from "<list>".
final class OPMLListSharingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func subscription(_ n: Int) -> FeedSubscription {
        let url = ListLinkFixture.feedURL(n)
        return FeedSubscription(
            id: "sub\(n)", source: SourceIdentity(id: "s\(n)", kind: .podcastFeed, canonicalURL: url, host: "shows.example", title: "Show \(n)"),
            state: .active, createdAt: now)
    }

    private func member(_ n: Int) -> ListMember { ListLinkFixture.member(n) }

    private func rule(_ id: String, _ action: ListeningRuleAction, _ words: [String], _ scope: ListeningRuleScope, on: Bool = true) -> ListeningRule {
        ListeningRule(id: id, action: action, words: words, scope: scope, origin: .listener, isOn: on, createdAt: now)
    }

    private func reparse(_ export: OPMLExport) throws -> OPMLDocument { try OPMLParser.parse(export.data) }

    // MARK: Includes

    func testAListWithAnIncludeRoundTripsTheIncludeAndItsShows() throws {
        let list = FollowList(id: "l", name: "Commute", members: [member(1), member(2)])
        let include = ListLink(id: "i", listId: "l", url: "https://friend.example/tech.opml", title: "Tech picks", role: .include,
                               acceptedMembers: [member(2)])
        let export = OPMLExporter.exportList(list, subscriptions: [subscription(1), subscription(2), subscription(3)], links: [include])
        let document = try reparse(export)
        XCTAssertEqual(document.title, "Commute")
        XCTAssertEqual(document.includes, [OPMLInclude(url: "https://friend.example/tech.opml", title: "Tech picks")])
        XCTAssertEqual(document.feeds.map(\.title), ["Show 1", "Show 2"], "only the list's shows")
        XCTAssertEqual(document.feeds.map(\.sm.via), [nil, "Tech picks"])

        let preview = OPMLImportPlanner.preview(document, existing: [])
        XCTAssertEqual(preview.includes.count, 1)
        XCTAssertEqual(preview.includes[0].rowText, "Tech picks updates from its web address")
        XCTAssertEqual(preview.includes[0].members, [member(2)])
        let target = try XCTUnwrap(OPMLIncludeImporter.targetList(preview: preview, listsOn: Set(preview.lists.map(\.id))))
        XCTAssertEqual(target.name, "Commute")

        var ids = ["new"].makeIterator()
        let links = OPMLIncludeImporter.links(
            preview.includes, switchedOn: ["include:0"], listID: "mine", followedFeedKeys: [member(2).feedKey], existing: [],
            makeId: { ids.next()! })
        XCTAssertEqual(links.map(\.id), ["new"])
        XCTAssertEqual(links[0].role, .include)
        XCTAssertEqual(links[0].acceptedMembers, [member(2)])
        XCTAssertTrue(OPMLIncludeImporter.links(
            preview.includes, switchedOn: [], listID: "mine", followedFeedKeys: [], existing: []).isEmpty, "switched off: nothing")
        XCTAssertTrue(OPMLIncludeImporter.links(
            preview.includes, switchedOn: ["include:0"], listID: "mine", followedFeedKeys: [], existing: links).isEmpty,
            "the same address again: nothing new")
    }

    func testAListThatUpdatesFromItsOwnAddressIsSharedAsThatAddress() throws {
        let list = FollowList(id: "l", name: "Friend picks", members: [member(1)])
        let own = ListLink(id: "o", listId: "l", url: "https://friend.example/l.opml", title: "Friend picks", acceptedMembers: [member(1)])
        let document = try reparse(OPMLExporter.exportList(list, subscriptions: [subscription(1)], links: [own]))
        XCTAssertEqual(document.includes.map(\.url), ["https://friend.example/l.opml"])
        XCTAssertEqual(document.feeds.map(\.sm.via), ["Friend picks"])
    }

    // MARK: Rules

    func testRulesTravelOnlyWhenSwitchedOnAndArriveSwitchedOff() throws {
        let list = FollowList(id: "l", name: "Commute", members: [member(1), member(2)])
        let rules = [
            rule("a", .skip, ["crypto", "Crypto"], .show(member(1))),
            rule("b", .more, ["interview"], .list("l")),
            rule("c", .skip, ["sport"], .show(member(2)), on: false),
            rule("d", .skip, ["anything"], .any),
            rule("e", .skip, ["other"], .show(member(3))),
        ]
        let subscriptions = [subscription(1), subscription(2)]
        XCTAssertEqual(OPMLExporter.shareableRuleCount(list, subscriptions: subscriptions, rules: rules), 2)

        let without = try reparse(OPMLExporter.exportList(list, subscriptions: subscriptions, links: []))
        XCTAssertTrue(without.feeds.allSatisfy { $0.sm.skip.isEmpty && $0.sm.more.isEmpty }, "off by default")

        let with = try reparse(OPMLExporter.exportList(list, subscriptions: subscriptions, links: [], rules: rules))
        XCTAssertEqual(with.feeds.map(\.sm.skip), [["crypto"], []], "case-blind repeats merged; a switched-off rule stays home")
        XCTAssertEqual(with.feeds.map(\.sm.more), [["interview"], ["interview"]], "a list rule goes on every show")

        let preview = OPMLImportPlanner.preview(with, existing: [])
        XCTAssertEqual(preview.rules.count, 3)
        XCTAssertEqual(preview.rulesLine, "This file has 3 rules. They arrive switched off. Turn them on in Rules.")
        var n = 0
        let imported = OPMLRulesImporter.rules(
            preview.rules, followedFeedKeys: [member(1).feedKey], existing: [rule("x", .more, ["INTERVIEW"], .show(member(1)))],
            now: now, makeId: { n += 1; return "r\(n)" })
        XCTAssertEqual(imported.map(\.words), [["crypto"]], "only followed shows, and a rule you have isn't added twice")
        XCTAssertEqual(imported[0].scope, .show(member(1)))
        XCTAssertEqual(imported[0].origin, .list("Commute"))
        XCTAssertFalse(imported[0].isOn)
    }

    func testAFileWithNoRulesHasNoRulesLine() throws {
        let document = try OPMLParser.parse(Data(ListLinkFixture.opml(rows: ListLinkFixture.rows(1...1)).utf8))
        XCTAssertNil(OPMLImportPlanner.preview(document, existing: []).rulesLine)
    }

    // MARK: Import screen words

    func testThePrimaryButtonCanAddAListOfShowsYouAlreadyFollow() throws {
        let body = #"<outline text="Commute"><outline type="rss" text="Show 1" xmlUrl="\#(ListLinkFixture.feedURL(1))"/></outline>"#
        let document = try OPMLParser.parse(Data(#"<?xml version="1.0"?><opml version="2.0"><head><title>t</title></head><body>\#(body)</body></opml>"#.utf8))
        let preview = OPMLImportPlanner.preview(document, existing: [subscription(1)])
        XCTAssertEqual(preview.lists.count, 1)
        XCTAssertTrue(OPMLImportListWords.primaryButton(ticked: 0, preview: preview, listsOn: ["list:0"]) == ("Add lists", true))
        XCTAssertTrue(OPMLImportListWords.primaryButton(ticked: 0, preview: preview, listsOn: []) == ("Follow", false))
        XCTAssertTrue(OPMLImportListWords.primaryButton(ticked: 2, preview: preview, listsOn: []) == ("Follow 2", true))
    }

    func testResultLines() {
        func result(_ created: Int, _ merged: Int) -> OPMLListImportResult {
            OPMLListImportResult(lists: [], createdCount: created, mergedCount: merged, skippedEmptyCount: 0)
        }
        XCTAssertNil(OPMLImportListWords.resultLine(result(0, 0)))
        XCTAssertEqual(OPMLImportListWords.resultLine(result(1, 0)), "Added 1 list.")
        XCTAssertEqual(OPMLImportListWords.resultLine(result(0, 2)), "Added shows to 2 lists you had.")
        XCTAssertEqual(OPMLImportListWords.resultLine(result(2, 1)), "Added 2 lists, and shows to 1 list you had.")
    }
}
