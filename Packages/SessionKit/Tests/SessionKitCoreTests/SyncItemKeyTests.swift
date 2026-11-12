import Foundation
import XCTest
@testable import SessionKit

/// #4152: two phones that each added the same article, episode or note must make one record; two items that merely look
/// alike must not. The table is the neighbours of a match, per AGENTS.md: case, whitespace, normalization, punctuation,
/// empty, very long, the same item from another source, and lookalikes.
final class SyncItemKeyTests: XCTestCase {
    private func key(guid: String? = nil, show: String? = nil, url: String? = nil, digest: String? = nil, note: String? = nil) -> String? {
        SyncItemKey.derive(noteId: note, episodeGUID: guid, showTitle: show, sourceURL: url, normalizedContentSHA256: digest)
    }

    func testASpokenNoteIsKeyedByItsNoteIdAndNothingElseOutranksIt() {
        XCTAssertEqual(key(note: "n-1"), "spoken-note-n-1")
        XCTAssertEqual(key(guid: "g", show: "Show", url: "https://a.example/x", digest: "abc", note: "n-1"), "spoken-note-n-1")
        XCTAssertNil(key(note: ""), "an empty note id is not a key")
    }

    func testAnEpisodeIsKeyedByGUIDAndShowAndTheSameEpisodeFromAnotherSourceMatches() {
        let base = key(guid: "tag:show,2026:ep42", show: "The Show", url: "https://feed-a.example/ep42.mp3")
        XCTAssertEqual(base, key(guid: "tag:show,2026:ep42", show: "The Show", url: "https://feed-b.example/other-link.mp3"), "another audio link")
        XCTAssertEqual(base, key(guid: " tag:show,2026:ep42 ", show: "  the   SHOW "), "case and whitespace in the show, edge whitespace in the GUID")
        XCTAssertEqual(key(guid: "g", show: "Caf\u{e9}"), key(guid: "g", show: "Cafe\u{301}"), "Unicode normalization")
        XCTAssertNotEqual(base, key(guid: "tag:show,2026:ep43", show: "The Show"), "another episode")
        XCTAssertNotEqual(base, key(guid: "tag:show,2026:ep42", show: "Another Show"), "the same GUID in another show")
        XCTAssertNotEqual(key(guid: "ABC", show: "S"), key(guid: "abc", show: "S"), "a GUID is case-sensitive")
        XCTAssertTrue(base!.hasPrefix("ep-"))
    }

    func testAGUIDWithoutAShowDoesNotMatchByGUIDAlone() {
        XCTAssertNil(key(guid: "g"))
        XCTAssertNil(key(guid: "g", show: "  "))
        XCTAssertEqual(key(guid: "g", url: "https://a.example/p"), key(url: "https://a.example/p"), "falls to the address")
    }

    func testTheSameArticleAddressMatchesThroughHarmlessDifferences() {
        let base = key(url: "https://example.com/post/one")
        for same in [
            "https://EXAMPLE.com/post/one", "https://example.com/post/one/", "https://example.com/post/one#section-2",
            "https://example.com/post/one?utm_source=news&utm_medium=email", "https://example.com:443/post/one",
            "http://example.com/post/one", "  https://example.com/post/one \n", "https://example.com/post/one?fbclid=xyz",
        ] {
            XCTAssertEqual(key(url: same), base, same)
        }
        XCTAssertEqual(key(url: "https://example.com/p?b=2&a=1"), key(url: "https://example.com/p?a=1&b=2"), "parameter order")
    }

    func testDifferentOrLookalikeAddressesStayApart() {
        let base = key(url: "https://example.com/post/one")
        for different in [
            "https://www.example.com/post/one", "https://example.com/post/two", "https://example.com/Post/one",
            "https://example.com/post/one?page=2", "https://example.org/post/one", "https://example.com:8443/post/one",
            "https://example.com/post/one/extra",
        ] {
            XCTAssertNotEqual(key(url: different), base, different)
        }
        XCTAssertNotEqual(key(url: "https://example.com/p?id=1"), key(url: "https://example.com/p?id=2"), "a meaningful parameter")
        XCTAssertNotEqual(key(url: "https://example.com/"), key(url: "https://example.com/about"))
        XCTAssertEqual(key(url: "https://example.com"), key(url: "https://example.com/"))
    }

    func testAnItemWithNoAddressFallsToItsTextDigestAndAnUnmatchableOneHasNoKey() {
        let digest = String(repeating: "ab", count: 32)
        XCTAssertEqual(key(digest: digest), key(digest: digest.uppercased()), "case of the hex")
        XCTAssertNotEqual(key(digest: digest), key(digest: String(repeating: "cd", count: 32)))
        XCTAssertTrue(key(digest: digest)!.hasPrefix("txt-"))
        XCTAssertEqual(key(url: "mailto:me@example.com", digest: digest), key(digest: digest), "not a web address")
        XCTAssertEqual(key(url: "file:///private/var/article.html", digest: digest), key(digest: digest))
        XCTAssertNil(key())
        XCTAssertNil(key(url: "", digest: "  "))
        XCTAssertNil(key(url: "not a url"))
    }

    func testTheAddressOutranksTheDigestSoTwoEditionsOfOnePageShareAKeyAndTwoPagesWithOneTextDoNot() {
        XCTAssertEqual(key(url: "https://a.example/x", digest: "111"), key(url: "https://a.example/x", digest: "222"))
        XCTAssertNotEqual(key(url: "https://a.example/x", digest: "111"), key(url: "https://b.example/x", digest: "111"))
    }

    func testAVeryLongAddressAndOddCharactersGiveAShortSafeKey() {
        let long = "https://example.com/" + String(repeating: "a/", count: 5000) + "?q=" + String(repeating: "é", count: 2000)
        let value = key(url: long)
        XCTAssertEqual(value?.count, 4 + 64, "a hash, so a record name never carries the address")
        XCTAssertFalse(value!.contains("example"))
        XCTAssertEqual(value, key(url: long + "#frag"))
    }

    func testAnItemOfTheLibraryGetsItsKeyFromItsFieldsAndDigests() {
        var episode = Item(id: "local-1", title: "Ep", mediaType: "audio", text: nil, externalReference: nil, status: "ready")
        episode.episodeGUID = "g1"
        episode.showTitle = "Show"
        XCTAssertEqual(SyncItemKey.derive(item: episode, digests: nil), key(guid: "g1", show: "Show"))

        var article = Item(id: "local-2", title: "A", mediaType: "text", text: "body", externalReference: "https://example.com/a", status: "ready")
        XCTAssertEqual(SyncItemKey.derive(item: article, digests: nil), key(url: "https://example.com/a"), "the item's own link")
        article.sourceURL = "https://example.com/canonical"
        XCTAssertEqual(SyncItemKey.derive(item: article, digests: nil), key(url: "https://example.com/canonical"))
        let pasted = Item(id: "local-3", title: "P", mediaType: "text", text: "pasted", externalReference: nil, status: "ready")
        XCTAssertNil(SyncItemKey.derive(item: pasted, digests: nil), "pasted text with no digest stays on its phone")
        XCTAssertEqual(
            SyncItemKey.derive(item: pasted, digests: ItemTextDigests(normalizedContentSHA256: "abc", exactEditionSHA256: "def")),
            key(digest: "abc")
        )
        let note = SpokenNoteItem.makeItem(note: SpokenNote(id: "n9"), createdAt: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(SyncItemKey.derive(item: note, digests: nil), "spoken-note-n9")
    }
}
