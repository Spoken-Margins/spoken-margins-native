import Foundation
import XCTest
@testable import SessionKit

/// The Margins tab's Shared list groups a friend's Margins by the item they are on (#4098, #4105): newest friend
/// activity first, Margins inside a group in the order the review plays them, and a last group for Margins whose item
/// is not in the Library.
final class SharedMarginGroupsTests: XCTestCase {
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)

    private func friendMargin(
        _ id: String, sender: String? = "Sam", item: String? = "a", title: String? = nil, recordedAgo: Double = 0,
        importedAgo: Double = 0, ms: Int? = 1_000, startChar: Int? = nil, heard: Bool = false,
        resolution: ImportedAnchorResolution = .init(evidenceClass: .unresolved)
    ) -> MarginCollection.SharedEntry {
        let layerID = "layer-\(sender ?? "none")-\(item ?? "none")-\(importedAgo)"
        let layer = ImportedCommentaryLayer(
            id: layerID, itemId: item, packageDigest: "d-\(layerID)", packageId: "p-\(layerID)",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: title ?? "Title \(item ?? "")"),
            displayLabel: sender, importedAt: clock.addingTimeInterval(-importedAgo)
        )
        let evidence = ms != nil
            ? PortableAnchorEvidence(anchorType: .media, mediaTimeMs: ms)
            : PortableAnchorEvidence(anchorType: .text, startChar: startChar)
        var margin = ImportedCommentaryInterjection(
            id: id, layerId: layerID, packageScopedId: id, createdAt: clock.addingTimeInterval(-recordedAgo),
            anchorEvidence: evidence, approvedTranscript: "words", audioPath: "a.m4a", resolution: resolution
        )
        if heard { margin.firstHeardAt = clock }
        return MarginCollection.SharedEntry(interjection: margin, layer: layer, itemTitle: title ?? "Title \(item ?? "")")
    }

    private func groups(_ entries: [MarginCollection.SharedEntry], library: Set<String> = ["a", "b", "c"]) -> [SharedMarginGroups.Group] {
        SharedMarginGroups.groups(from: entries, libraryItemIDs: library)
    }

    func testOneGroupPerItemEvenFromTwoFriends() {
        let result = groups([friendMargin("1", sender: "Sam", item: "a"), friendMargin("2", sender: "Ana", item: "a"), friendMargin("3", item: "b")])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first { $0.itemID == "a" }?.count, 2)
    }

    func testGroupsRunByFriendActivityNotRecordedTime() {
        // b was recorded 40 days ago but opened today; a was recorded yesterday and opened yesterday.
        let result = groups([
            friendMargin("1", item: "a", recordedAgo: 86_400, importedAgo: 86_400),
            friendMargin("2", item: "b", recordedAgo: 40 * 86_400, importedAgo: 0),
        ])
        XCTAssertEqual(result.map(\.itemID), ["b", "a"])
        XCTAssertEqual(result.map(\.isNewest), [true, false])
    }

    func testTiesKeepFirstSeenThenLowerItemID() {
        XCTAssertEqual(groups([friendMargin("1", item: "c"), friendMargin("2", item: "a")]).map(\.itemID), ["c", "a"])
    }

    func testEmptyGivesNoGroups() {
        XCTAssertTrue(groups([]).isEmpty)
    }

    func testMarginsReadInTheOrderTheReviewPlays() {
        let result = groups([
            friendMargin("unplaced", ms: nil, startChar: nil),
            friendMargin("text", ms: nil, startChar: 40),
            friendMargin("late", ms: 1_037_000),
            friendMargin("early", ms: 134_000),
            friendMargin("textEarly", ms: nil, startChar: 5),
        ])
        XCTAssertEqual(result.first?.entries.map(\.interjection.id), ["early", "late", "textEarly", "text", "unplaced"])
    }

    func testTimesTieByRecordedTimeThenID() {
        let result = groups([friendMargin("b", recordedAgo: 0, ms: 5_000), friendMargin("a", recordedAgo: 0, ms: 5_000), friendMargin("old", recordedAgo: 60, ms: 5_000)])
        XCTAssertEqual(result.first?.entries.map(\.interjection.id), ["old", "a", "b"])
    }

    func testAMarginWhoseItemIsNotInTheLibraryLandsInTheLastGroup() {
        let result = groups([
            friendMargin("gone", item: "deleted", title: "Old Show", importedAgo: 0),
            friendMargin("nosrc", item: nil, title: "Old Show", importedAgo: 0),
            friendMargin("kept", item: "a", importedAgo: 5_000),
        ])
        XCTAssertEqual(result.map(\.inLibrary), [true, false], "the missing-item group is last even though it is newest")
        XCTAssertNil(result.last?.itemID)
        XCTAssertEqual(result.last?.title, "Old Show")
        XCTAssertEqual(result.last?.count, 2)
        XCTAssertFalse(result.last?.isNewest ?? true)
        XCTAssertTrue(result.first?.isNewest ?? false)
    }

    func testMissingGroupWithNoSharedTitleHasNone() {
        let result = groups([friendMargin("1", item: nil, title: "One"), friendMargin("2", item: "x", title: "Two")])
        XCTAssertNil(result.last?.title)
    }

    func testNewCountsComeFromUnheardMargins() {
        let result = groups([friendMargin("1", item: "a"), friendMargin("2", item: "a", heard: true), friendMargin("3", item: "a")])
        XCTAssertEqual(result.first?.newCount, 2)
        XCTAssertEqual(result.first?.line, "Newest · 3 Margins · 2 new")
    }

    func testSublineWords() {
        XCTAssertEqual(MarginCountText.itemLine(3, newCount: 2, isNewest: false), "3 Margins · 2 new")
        XCTAssertEqual(MarginCountText.itemLine(3, newCount: 0, isNewest: false), "3 Margins")
        XCTAssertEqual(MarginCountText.itemLine(1, newCount: 1, isNewest: true), "Newest · 1 Margin · 1 new")
    }

    // MARK: The "New from friends" row and the chip count

    private func fresh(_ entries: [MarginCollection.SharedEntry], library: Set<String> = ["a", "b"]) -> SharedMarginGroups.NewFromFriends? {
        SharedMarginGroups.newFromFriends(entries, libraryItemIDs: library)
    }

    func testNothingNewGivesNoRow() {
        XCTAssertNil(fresh([]))
        XCTAssertNil(fresh([friendMargin("1", heard: true)]))
    }

    func testOneFriendOnOneItemNamesFriendAndItemAndOpensIt() {
        let row = fresh([friendMargin("1", title: "Bill Gates says to prepare"), friendMargin("2", title: "Bill Gates says to prepare"), friendMargin("3", heard: true)])
        XCTAssertEqual(row?.text, "2 new Margins from Sam · Bill Gates says to prepare")
        XCTAssertEqual(row?.itemID, "a")
        XCTAssertEqual(row?.chipText, "2 new")
        XCTAssertEqual(row?.accessibilityHint, "Opens it.")
        XCTAssertEqual(row?.accessibilityLabel, "2 new Margins from Sam, on Bill Gates says to prepare")
    }

    func testOneNewMarginReadsSingular() {
        XCTAssertEqual(fresh([friendMargin("1", title: "T")])?.text, "1 new Margin from Sam · T")
    }

    func testTwoFriendsOrAnUnnamedOneFallBackToTheSharedWords() {
        XCTAssertEqual(fresh([friendMargin("1", sender: "Sam", title: "T"), friendMargin("2", sender: "Ana", title: "T")])?.text, "2 new shared Margins · T")
        XCTAssertEqual(fresh([friendMargin("1", sender: "Unsigned sender", title: "T")])?.text, "1 new shared Margin · T")
    }

    func testSeveralItemsSwitchTheListInsteadOfOpeningOne() {
        let row = fresh([friendMargin("1", item: "a"), friendMargin("2", item: "a"), friendMargin("3", item: "b")])
        XCTAssertEqual(row?.text, "3 new Margins from friends on 2 episodes or articles")
        XCTAssertNil(row?.itemID)
        XCTAssertEqual(row?.accessibilityHint, "Shows shared Margins.")
    }

    func testNewMarginsOutsideTheLibraryNeverOpenAnItem() {
        let row = fresh([friendMargin("1", item: "gone"), friendMargin("2", item: nil)])
        XCTAssertNil(row?.itemID)
        XCTAssertEqual(row?.newCount, 2)
    }

    func testThreeHundredMarginsOnFortyItemsBuildQuickly() {
        let items = (0..<40).map { "i\($0)" }
        let all = (0..<300).map { friendMargin("m\($0)", item: items[$0 % 40], recordedAgo: Double($0), ms: $0 * 1_000) }
        let start = Date()
        let result = groups(all, library: Set(items))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.05)
        XCTAssertEqual(result.count, 40)
        XCTAssertEqual(result.reduce(0) { $0 + $1.count }, 300)
    }
}
