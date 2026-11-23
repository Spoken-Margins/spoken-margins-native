import Foundation
import XCTest
import SessionKit
@testable import SessionKitFeeds

/// #4341 PR 2: what the "Follow papers" field makes of a pasted link. Nothing is fetched.
final class PaperFeedLinkTests: XCTestCase {
    private let collection = PaperFeedLink.source(.zoteroGroup(groupID: 2205533, collectionKey: "DMKBHP6P"))

    func testZoteroCollectionLinkTable() {
        let cases: [(String, String)] = [
            ("https://www.zotero.org/groups/2205533/test_items_library/collections/DMKBHP6P", "web address with the group's name"),
            ("https://www.zotero.org/groups/2205533/test_items_library/collections/DMKBHP6P/items/T52IAELZ/library", "an item open inside it"),
            ("https://www.zotero.org/groups/2205533/collections/DMKBHP6P", "no group name"),
            ("https://zotero.org/groups/2205533/test_items_library/collections/DMKBHP6P", "without www"),
            ("https://www.zotero.org/groups/2205533/test_items_library/collections/DMKBHP6P/", "trailing slash"),
            ("HTTPS://WWW.ZOTERO.ORG/groups/2205533/test_items_library/collections/DMKBHP6P", "upper-case scheme and host"),
            ("http://www.zotero.org/groups/2205533/x/collections/DMKBHP6P", "http"),
            ("www.zotero.org/groups/2205533/x/collections/DMKBHP6P", "no scheme"),
            ("  https://www.zotero.org/groups/2205533/x/collections/DMKBHP6P\n", "spaces and a newline around it"),
            ("https://www.zotero.org:443/groups/2205533/x/collections/DMKBHP6P", "the default port"),
            ("https://www.zotero.org/groups/2205533/x/collections/DMKBHP6P?utm_source=mail&foo=bar", "extra query parameters"),
            ("https://www.zotero.org/groups/2205533/x/collections/DMKBHP6P#anchor", "a fragment"),
            ("www.zotero.org/groups/2205533/x/collections/DMKBHP6P?u=https://a.example", "no scheme, with :// inside the query"),
            ("www.zotero.org/groups/2205533/x/collections/DMKBHP6P#https://a.example", "no scheme, with :// inside the fragment"),
            ("https://api.zotero.org/groups/2205533/collections/DMKBHP6P/items/top?format=json&limit=5&start=10&sort=title", "paging and sort parameters"),
            ("https://www.zotero.org/groups/2205533/Caf\u{00E9}%20readings/collections/DMKBHP6P", "a Unicode group name, part encoded"),
            ("https://www.zotero.org/groups/2205533/\u{4E2D}\u{6587}\u{5C0F}\u{7EC4}/collections/DMKBHP6P", "a Unicode group name, raw"),
            ("https://api.zotero.org/groups/2205533/collections/DMKBHP6P/items/top?format=json&limit=25", "the API address"),
            ("https://api.zotero.org/groups/2205533/collections/DMKBHP6P/items", "the API address of all items"),
            ("https://www.zotero.org/groups/2205533/test_items_library/Collections/DMKBHP6P", "section name in capitals")
        ]
        for (pasted, why) in cases {
            XCTAssertEqual(PaperFeedLink.recognize(pasted), collection, why)
        }
    }

    func testAWholePublicGroupLibraryIsASourceWithNoCollection() {
        let whole = PaperFeedLink.source(.zoteroGroup(groupID: 2205533, collectionKey: nil))
        for pasted in [
            "https://www.zotero.org/groups/2205533",
            "https://www.zotero.org/groups/2205533/",
            "https://www.zotero.org/groups/2205533/test_items_library",
            "https://www.zotero.org/groups/2205533/test_items_library/library",
            "https://www.zotero.org/groups/2205533/test_items_library/items/T52IAELZ",
            "https://api.zotero.org/groups/2205533/items/top?format=json"
        ] {
            XCTAssertEqual(PaperFeedLink.recognize(pasted), whole, pasted)
        }
    }

    func testAUserLibraryIsPrivate() {
        for pasted in [
            "https://www.zotero.org/users/123456/items",
            "https://api.zotero.org/users/123456/collections/DMKBHP6P/items/top",
            "https://www.zotero.org/someone/library",
            "https://www.zotero.org/someone/collections/DMKBHP6P",
            "https://www.zotero.org/someone/items/T52IAELZ"
        ] {
            XCTAssertEqual(PaperFeedLink.recognize(pasted), .rejected(.zoteroPrivateLibrary), pasted)
        }
        XCTAssertTrue(PaperFeedLinkProblem.zoteroPrivateLibrary.message.contains("private"))
    }

    func testZoteroSitePagesFallThroughToTheExistingFollow() {
        for pasted in [
            "https://www.zotero.org/",
            "https://www.zotero.org/support/kb",
            "https://www.zotero.org/blog/feed/",
            "https://www.zotero.org/download"
        ] {
            XCTAssertEqual(PaperFeedLink.recognize(pasted), .notAPaperLink, pasted)
        }
    }

    func testGroupAddressesThatAreNotAListSayZoteroCouldntFindIt() {
        for pasted in [
            "https://www.zotero.org/groups/",
            "https://www.zotero.org/groups/test_items_library",
            "https://www.zotero.org/groups/2205533/test_items_library/collections",
            "https://www.zotero.org/groups/2205533/test_items_library/collections/short",
            "https://www.zotero.org/groups/2205533/test_items_library/collections/dmkbhp6p",
            "https://www.zotero.org/groups/2205533/test_items_library/collections/DMKBHP6PX",
            "https://www.zotero.org/groups/2205533/test_items_library/tags/biology",
            "https://www.zotero.org/groups/0/test_items_library",
            "https://www.zotero.org/groups/-5/test_items_library",
            "https://www.zotero.org/groups/\u{0662}\u{0662}/x",
            "https://www.zotero.org/groups/+123/x",
            "https://www.zotero.org/groups/%2B123/x",
            "https://api.zotero.org/groups/2205533/items?q=foo&tag=bar",
            "https://api.zotero.org/groups/2205533/collections/DMKBHP6P/items/top?tag=biology",
            "https://api.zotero.org/groups/2205533/items?itemType=book",
            "https://api.zotero.org/groups/2205533/items?itemKey=T52IAELZ"
        ] {
            XCTAssertEqual(PaperFeedLink.recognize(pasted), .rejected(.zoteroNotUnderstood), pasted)
        }
    }

    func testPubMedRSSLinkTable() {
        let token = "1abcDEF-gh_ijk23"
        let base = "https://pubmed.ncbi.nlm.nih.gov/rss/search/\(token)/"
        let plain = PaperFeedLink.source(.pubMedRSS(token: token, limit: nil))
        XCTAssertEqual(PaperFeedLink.recognize(base), plain)
        XCTAssertEqual(PaperFeedLink.recognize("https://pubmed.ncbi.nlm.nih.gov/rss/search/\(token)"), plain, "no trailing slash")
        XCTAssertEqual(PaperFeedLink.recognize("PUBMED.NCBI.NLM.NIH.GOV/rss/search/\(token)/"), plain, "upper-case host, no scheme")
        XCTAssertEqual(PaperFeedLink.recognize(base + "?limit=15&utm_campaign=pubmed-2&fc=20260101000000"),
                       .source(.pubMedRSS(token: token, limit: 15)), "the limit is kept, tracking parameters are not")
        for limit in ["0", "101", "-3", "abc", "", "15.5"] {
            XCTAssertEqual(PaperFeedLink.recognize(base + "?limit=\(limit)"), plain, "limit \(limit) asks for nothing sensible")
        }
        XCTAssertEqual(PaperFeedLink.recognize(base + "?limit=15&limit=99"), .source(.pubMedRSS(token: token, limit: 15)), "the first limit wins")
    }

    func testAPubMedSearchPageIsNotItsRSSLink() {
        for pasted in [
            "https://pubmed.ncbi.nlm.nih.gov/?term=circadian+rhythm+sleep+deprivation",
            "https://pubmed.ncbi.nlm.nih.gov/?term=circadian&filter=simsearch1.fha&sort=date",
            "https://pubmed.ncbi.nlm.nih.gov/?term=%22sleep%22",
            "https://www.ncbi.nlm.nih.gov/pubmed/?term=sleep"
        ] {
            XCTAssertEqual(PaperFeedLink.recognize(pasted), .rejected(.pubMedSearchPage), pasted)
        }
        XCTAssertEqual(PaperFeedLinkProblem.pubMedSearchPage.message, "That's a PubMed search page. Use its Create RSS link instead.")
    }

    func testOtherPubMedAndNCBIAddressesFallThroughToTheExistingFollow() {
        for pasted in [
            "https://pubmed.ncbi.nlm.nih.gov/",
            "https://pubmed.ncbi.nlm.nih.gov/16756431/",
            "https://pubmed.ncbi.nlm.nih.gov/rss/search/",
            "https://pubmed.ncbi.nlm.nih.gov/rss/search/abc/extra",
            "https://pubmed.ncbi.nlm.nih.gov/rss/search/ab%20c/",
            "https://www.ncbi.nlm.nih.gov/pmc/articles/PMC123/",
            "https://www.ncbi.nlm.nih.gov/pubmed/16756431"
        ] {
            XCTAssertEqual(PaperFeedLink.recognize(pasted), .notAPaperLink, pasted)
        }
    }

    func testLookalikesAndUnrelatedLinksAreNotPaperLinks() {
        for pasted in [
            "",
            "   ",
            "hello",
            "https://example.com/feed.xml",
            "https://feeds.simplecast.com/abc",
            "https://zotero.org.evil.example/groups/2205533/collections/DMKBHP6P",
            "https://notzotero.org/groups/2205533/collections/DMKBHP6P",
            "https://www.zotero.org@evil.example/groups/2205533/collections/DMKBHP6P",
            "https://someone:secret@www.zotero.org/groups/2205533/collections/DMKBHP6P",
            "https://www.zotero.org:8443/groups/2205533/collections/DMKBHP6P",
            "https://www.zotero.org.:8443/groups/2205533/collections/DMKBHP6P",
            "zotero://select/groups/2205533/collections/DMKBHP6P",
            "ftp://www.zotero.org/groups/2205533/collections/DMKBHP6P",
            "mailto:me@zotero.org",
            "https://pubmed.ncbi.nlm.nih.gov.evil.example/rss/search/abc/",
            "https://evil.example/https://www.zotero.org/groups/2205533/collections/DMKBHP6P",
            "https://www.zotero.org/groups/2205533/a b/collections/DMKBHP6P",
            "https://www.zotero.org/groups/2205533/x/collections/DMKBHP6P/" + String(repeating: "a", count: 3_000)
        ] {
            XCTAssertEqual(PaperFeedLink.recognize(pasted), .notAPaperLink, pasted)
        }
    }

    func testASourceNamesTheSameListWhichWayItWasPasted() {
        let a = PaperFeedLink.recognize("https://www.zotero.org/groups/2205533/one/collections/DMKBHP6P")
        let b = PaperFeedLink.recognize("https://api.zotero.org/groups/2205533/collections/DMKBHP6P/items/top")
        guard case .source(let first) = a, case .source(let second) = b else { return XCTFail("both are lists") }
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.identifier, "zotero:group:2205533:collection:DMKBHP6P")
        XCTAssertEqual(first.provider, .zotero)
        XCTAssertEqual(PaperSource.zoteroGroup(groupID: 7, collectionKey: nil).identifier, "zotero:group:7")
        XCTAssertEqual(PaperSource.pubMedRSS(token: "abc", limit: 5).identifier, PaperSource.pubMedRSS(token: "abc", limit: nil).identifier,
                       "the item count is not part of which search it is")
        XCTAssertEqual(PaperSource.pubMedRSS(token: "abc", limit: 5).provider, .pubmed)
    }

    func testRequestAddressesAskForOneHundredAtATimeAndSendTheVersionHeader() {
        let source = PaperSource.zoteroGroup(groupID: 2205533, collectionKey: "DMKBHP6P")
        XCTAssertEqual(source.pageURL().absoluteString,
                       "https://api.zotero.org/groups/2205533/collections/DMKBHP6P/items/top?sort=dateAdded&direction=desc&format=json&limit=100&start=0")
        XCTAssertEqual(source.pageURL(start: 200).absoluteString,
                       "https://api.zotero.org/groups/2205533/collections/DMKBHP6P/items/top?sort=dateAdded&direction=desc&format=json&limit=100&start=200")
        XCTAssertEqual(source.pageURL(start: -5).absoluteString, source.pageURL().absoluteString, "a negative start is zero")
        XCTAssertEqual(ZoteroPaperAPI.attachmentsURL(groupID: 2205533, collectionKey: "DMKBHP6P").absoluteString,
                       "https://api.zotero.org/groups/2205533/collections/DMKBHP6P/items?itemType=attachment&format=json&limit=100&start=0")
        XCTAssertEqual(ZoteroPaperAPI.itemsURL(groupID: 2205533, collectionKey: nil).absoluteString,
                       "https://api.zotero.org/groups/2205533/items/top?sort=dateAdded&direction=desc&format=json&limit=100&start=0")
        XCTAssertEqual(ZoteroPaperAPI.requestHeaders, ["Zotero-API-Version": "3"])
        XCTAssertEqual(PaperSource.pubMedRSS(token: "abc", limit: 15).pageURL().absoluteString,
                       "https://pubmed.ncbi.nlm.nih.gov/rss/search/abc/?limit=15")
        XCTAssertEqual(PaperSource.pubMedRSS(token: "abc", limit: nil).pageURL().absoluteString,
                       "https://pubmed.ncbi.nlm.nih.gov/rss/search/abc/")
    }

    func testEveryRecognizedAddressIsHTTPSOnTheProvidersOwnHost() {
        let sources: [PaperSource] = [
            .zoteroGroup(groupID: 1, collectionKey: nil), .zoteroGroup(groupID: 1, collectionKey: "ABCD2345"),
            .pubMedRSS(token: "x", limit: nil), .pubMedRSS(token: "x", limit: 100)
        ]
        for source in sources {
            let url = source.pageURL()
            XCTAssertEqual(url.scheme, "https")
            XCTAssertTrue(["api.zotero.org", "pubmed.ncbi.nlm.nih.gov"].contains(url.host ?? ""), url.absoluteString)
        }
    }
}

