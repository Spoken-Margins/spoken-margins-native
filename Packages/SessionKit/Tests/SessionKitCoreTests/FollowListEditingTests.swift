import XCTest
@testable import SessionKit

/// #4046 PR 2: the edits behind the "Lists for <show>" sheet and the chip menu, and the words they use.
final class FollowListEditingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let news = FollowList(id: "news", name: "News", members: [ListMember(feedKey: "https://a.example/feed")])
    private let tech = FollowList(id: "tech", name: "Tech")

    func testCreatingTicksTheShowItWasMadeFor() {
        let member = ListMember(feedKey: "https://b.example/feed")
        guard case .created(let list) = FollowListEditing.creating(name: "  Commute  ", adding: member, existing: [news], id: "new", now: now) else {
            return XCTFail("expected a new list")
        }
        XCTAssertEqual(list.id, "new")
        XCTAssertEqual(list.name, "Commute", "the name is trimmed")
        XCTAssertEqual(list.members, [member])
        XCTAssertEqual(list.createdAt, now)
    }

    func testCreatingWithNoShowMakesAnEmptyList() {
        guard case .created(let list) = FollowListEditing.creating(name: "Tech", existing: [news], id: "t", now: now) else {
            return XCTFail("expected a new list")
        }
        XCTAssertEqual(list.members, [])
    }

    func testCreatingRefusesTheNamesFollowListNameRefuses() {
        // A table of neighbouring names: each row is the problem the sheet shows.
        let table: [(String, FollowListName.Problem)] = [
            ("", .empty), ("   \n\t ", .empty),
            ("News, Tech", .containsCommaOrSlash), ("Tech/AI", .containsCommaOrSlash),
            (String(repeating: "x", count: 41), .tooLong),
            ("news", .duplicate(existingName: "News")), ("  NEWS ", .duplicate(existingName: "News")),
        ]
        for (name, problem) in table {
            XCTAssertEqual(FollowListEditing.creating(name: name, existing: [news]), .invalid(problem), "\(name.debugDescription)")
        }
        XCTAssertEqual(FollowListEditing.creating(name: String(repeating: "x", count: 40), existing: [news]).isCreated, true)
    }

    func testRenamingKeepsTheIdAndTheMembers() {
        guard case .renamed(let list) = FollowListEditing.renaming(id: "news", to: " Daily news ", in: [news, tech]) else {
            return XCTFail("expected a rename")
        }
        XCTAssertEqual(list.id, "news")
        XCTAssertEqual(list.name, "Daily news")
        XCTAssertEqual(list.members, news.members)
        XCTAssertEqual(list.createdAt, news.createdAt)
    }

    func testARenameMayChangeOnlyTheCaseButNotTakeAnotherListsName() {
        XCTAssertEqual(FollowListEditing.renaming(id: "news", to: "NEWS", in: [news, tech]), .renamed(FollowList(id: "news", name: "NEWS", createdAt: news.createdAt, members: news.members)))
        XCTAssertEqual(FollowListEditing.renaming(id: "news", to: "tech", in: [news, tech]), .invalid(.duplicate(existingName: "Tech")))
        XCTAssertEqual(FollowListEditing.renaming(id: "news", to: "", in: [news, tech]), .invalid(.empty))
        XCTAssertEqual(FollowListEditing.renaming(id: "gone", to: "Anything", in: [news, tech]), .missing)
    }

    func testAShowsMemberIsFoundByTheFilterThatReadsTheSameFeedLink() {
        let spellings = ["https://a.example/feed", "http://A.example/feed/", "https://a.example/feed#top", " https://a.example/feed "]
        for link in spellings {
            let subscription = FeedSubscription(
                id: "a", source: SourceIdentity(id: "s", kind: .podcastFeed, canonicalURL: link, host: "a.example", title: "A"),
                state: .active, createdAt: now
            )
            let member = FollowListEditing.member(for: subscription)
            XCTAssertEqual(member.feedKey, "https://a.example/feed", link)
            let list = FollowList(id: "l", name: "L", members: [member])
            let shows = FollowingShowRows.build(subscriptions: [subscription], entries: [])
            XCTAssertEqual(
                FollowListFilter.apply(rows: shows.rows, quietRows: [], list: list, subscriptions: [subscription]).rows.map(\.id), ["a"], link
            )
        }
        let hostless = FeedSubscription(
            id: "h", source: SourceIdentity(id: "h", kind: .podcastFeed, canonicalURL: "not a link", host: "", title: nil), state: .active, createdAt: now
        )
        XCTAssertEqual(FollowListEditing.member(for: hostless).feedKey, "not a link")
    }

    func testTheShowScreensListsRowValue() {
        XCTAssertEqual(FollowListWords.rowValue([]), "None")
        XCTAssertEqual(FollowListWords.rowValue([FollowList(id: "2", name: "news"), FollowList(id: "1", name: "Commute")]), "Commute, news", "chip order, not stored order")
    }

    func testTheSheetTitleNamesTheShow() {
        XCTAssertEqual(FollowListWords.sheetTitle(showTitle: "Hard  Fork"), "Lists for Hard Fork")
        XCTAssertEqual(FollowListWords.sheetTitle(showTitle: nil), "Lists")
        XCTAssertEqual(FollowListWords.sheetTitle(showTitle: "  \n"), "Lists")
    }

    func testTheUnfollowWordsSayTheShowLeavesItsLists() {
        XCTAssertEqual(FollowListWords.unfollowMessage(inAList: false), "Everything already in your Library will be kept.")
        XCTAssertEqual(FollowListWords.unfollowMessage(inAList: true), "Everything already in your Library will be kept. It also leaves your lists.")
        XCTAssertEqual(FollowListWords.unfollowedBanner(showTitle: "Hard Fork", wasInAList: false), "Unfollowed Hard Fork.")
        XCTAssertEqual(FollowListWords.unfollowedBanner(showTitle: "Hard Fork", wasInAList: true), "Unfollowed Hard Fork. It also left your lists.")
        XCTAssertEqual(FollowListWords.unfollowedBanner(showTitle: nil, wasInAList: true), "Unfollowed. It also left your lists.")
    }

    func testTheListWordsUseTheTypographicApostrophe() {
        XCTAssertEqual(FollowListWords.emptyListText(listName: "News"), "No shows in News yet")
        XCTAssertEqual(FollowListWords.allQuietNote(listName: "News"), "Every show in News is Quiet.")
        XCTAssertEqual(FollowListWords.deleteQuestion(listName: "News"), "Delete News?")
    }
}

private extension FollowListEditing.CreateOutcome {
    var isCreated: Bool { if case .created = self { true } else { false } }
}
