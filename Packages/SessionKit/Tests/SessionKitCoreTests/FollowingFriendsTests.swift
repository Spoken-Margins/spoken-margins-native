import XCTest
@testable import SessionKit

/// #3291 done-when 6: Following shows each friend who sent Margins as a row.
final class FollowingFriendsTests: XCTestCase {
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)

    func testOneFriendsThreeMarginsOnOneEpisode() {
        let entries = (1...3).map { entry("m\($0)", from: "Cole", item: "ep", seconds: $0) }
        let friends = FollowingFriends.friends(from: entries)
        XCTAssertEqual(friends.count, 1)
        XCTAssertEqual(friends.first?.name, "Cole")
        XCTAssertEqual(friends.first?.summary, "3 Margins on 1 episode")
        XCTAssertEqual(friends.first?.items.map(\.id), ["ep"])
        XCTAssertEqual(friends.first?.items.first?.countLabel, "3 Margins")
    }

    func testOneMarginAndSeveralItems() {
        XCTAssertEqual(FollowingFriends.friends(from: [entry("m", from: "Cole", item: "ep")]).first?.summary, "1 Margin on 1 episode")
        let friends = FollowingFriends.friends(from: [
            entry("a", from: "Cole", item: "old", seconds: 1),
            entry("b", from: "Cole", item: "new", seconds: 5),
            entry("c", from: "Cole", item: "old", seconds: 2),
        ])
        XCTAssertEqual(friends.first?.summary, "3 Margins on 2 episodes")
        XCTAssertEqual(friends.first?.items.map(\.id), ["new", "old"], "the item with their newest Margin first")
        XCTAssertEqual(friends.first?.items.map(\.marginCount), [1, 2])
    }

    func testTheNounFollowsTheKindOfItem() {
        XCTAssertEqual(FollowingFriends.friends(from: [entry("m", from: "Cole", item: "a", kind: .text)]).first?.summary, "1 Margin on 1 article")
        XCTAssertEqual(FollowingFriends.friends(from: [entry("m", from: "Cole", item: "a", kind: .pdf)]).first?.summary, "1 Margin on 1 PDF")
        XCTAssertEqual(FollowingFriends.friends(from: [entry("m", from: "Cole", item: "a", kind: .epub)]).first?.summary, "1 Margin on 1 book")
        XCTAssertEqual(FollowingFriends.friends(from: [
            entry("m", from: "Cole", item: "a", kind: .text), entry("n", from: "Cole", item: "b", kind: .podcast),
        ]).first?.summary, "2 Margins on 2 items")
    }

    /// The name comes from the sender's app; the neighbours a listener would read as the same name share a row.
    func testNamesThatReadTheSameShareARow() {
        let sameAsCole = ["Cole", " Cole", "Cole\n", "cole", "COLE", "\tCole  "]
        let entries = sameAsCole.enumerated().map { entry("m\($0.offset)", from: $0.element, item: "ep", seconds: $0.offset) }
        let friends = FollowingFriends.friends(from: entries)
        XCTAssertEqual(friends.count, 1)
        XCTAssertEqual(friends.first?.marginCount, sameAsCole.count)
        XCTAssertEqual(friends.first?.name, "Cole", "the newest packet's spelling, trimmed")

        let accents = FollowingFriends.friends(from: [
            entry("a", from: "Zo\u{00EB}", item: "ep", seconds: 1), // precomposed ë
            entry("b", from: "Zoe\u{0308}", item: "ep", seconds: 2), // e + combining diaeresis
        ])
        XCTAssertEqual(accents.count, 1)
        XCTAssertEqual(FollowingFriends.friends(from: [
            entry("a", from: "Mary  Ann", item: "ep", seconds: 1), entry("b", from: "Mary Ann", item: "ep", seconds: 2),
        ]).count, 1, "doubled inner spaces")
    }

    func testDifferentNamesAreDifferentRowsNewestFirst() {
        let friends = FollowingFriends.friends(from: [
            entry("a", from: "Cole", item: "ep", seconds: 1),
            entry("b", from: "Zoe", item: "ep", seconds: 9),
            entry("c", from: "Coleman", item: "ep", seconds: 5),
            entry("d", from: "Zoë", item: "ep", seconds: 3),
        ])
        XCTAssertEqual(friends.map(\.name), ["Zoe", "Coleman", "Zoë", "Cole"], "an accent is part of the name; a longer name is another person")
        XCTAssertEqual(friends.map(\.summary), Array(repeating: "1 Margin on 1 episode", count: 4))
    }

    func testUnnamedPacketsAndItemsOutsideTheLibraryHaveNoRow() {
        let friends = FollowingFriends.friends(from: [
            entry("a", from: nil, item: "ep"),
            entry("b", from: "", item: "ep"),
            entry("c", from: "   \n", item: "ep"),
            entry("d", from: "Cole", item: nil),
        ])
        XCTAssertEqual(friends, [])
        XCTAssertEqual(FollowingFriends.friends(from: []), [])
    }

    func testAVeryLongNameIsKeptWhole() {
        let long = String(repeating: "Ann ", count: 60)
        let friend = FollowingFriends.friends(from: [entry("a", from: long, item: "ep")]).first
        XCTAssertEqual(friend?.name, String(repeating: "Ann ", count: 60).trimmingCharacters(in: .whitespaces))
    }

    func testTheSameMarginListedTwiceCountsOnce() {
        let margin = entry("a", from: "Cole", item: "ep")
        XCTAssertEqual(FollowingFriends.friends(from: [margin, margin]).first?.summary, "1 Margin on 1 episode")
    }

    private func entry(
        _ id: String, from sender: String?, item itemId: String?, kind: SharedItemType = .podcast, seconds: Int = 0
    ) -> MarginCollection.SharedEntry {
        let layerId = "layer-\(sender ?? "none")-\(itemId ?? "none")"
        let layer = ImportedCommentaryLayer(
            id: layerId, itemId: itemId, packageDigest: "digest-\(layerId)", packageId: "package-\(layerId)",
            itemIdentity: SharedItemIdentity(itemType: kind, title: "Title \(itemId ?? "")"),
            displayLabel: sender, importedAt: clock
        )
        let margin = ImportedCommentaryInterjection(
            id: id, layerId: layerId, packageScopedId: id, createdAt: clock.addingTimeInterval(Double(seconds)),
            anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 1_000), approvedTranscript: "words"
        )
        return MarginCollection.SharedEntry(interjection: margin, layer: layer, itemTitle: "Title \(itemId ?? "")")
    }
}
