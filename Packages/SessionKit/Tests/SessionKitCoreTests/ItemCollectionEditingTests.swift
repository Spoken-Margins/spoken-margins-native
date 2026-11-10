import Foundation
import XCTest
@testable import SessionKit

/// #490: collections in the app. The sheet's edits and the Margins scope are pure logic, tested here.
final class ItemCollectionEditingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)
    private let later = Date(timeIntervalSince1970: 2_000)

    private func collection(_ id: String, _ name: String, _ items: [String] = []) -> ItemCollection {
        ItemCollection(id: id, name: name, itemIDs: items, createdAt: now)
    }

    // MARK: Names

    func testANameIsTrimmedAndWhitespaceCollapsed() {
        XCTAssertEqual(ItemCollectionEditing.normalizedName("  HIST \n 210  "), "HIST 210")
        XCTAssertNil(ItemCollectionEditing.normalizedName(" \n\t "))
        XCTAssertNil(ItemCollectionEditing.normalizedName(""))
        XCTAssertEqual(ItemCollectionEditing.normalizedName(String(repeating: "a", count: 200))?.count,
                       ItemCollectionEditing.maximumNameCharacters)
    }

    func testNamesClashIgnoringCaseAccentsAndSpacing() {
        let existing = [collection("a", "Café Club")]
        XCTAssertTrue(ItemCollectionEditing.isNameTaken("cafe  club", in: existing))
        XCTAssertTrue(ItemCollectionEditing.isNameTaken("CAFÉ CLUB", in: existing))
        XCTAssertFalse(ItemCollectionEditing.isNameTaken("Café Clubs", in: existing))
        XCTAssertFalse(ItemCollectionEditing.isNameTaken("Café Club", in: existing, excluding: "a"))
    }

    // MARK: Creating, renaming, toggling

    func testCreatingStartsWithTheItemAndUsesTheNormalizedName() {
        let created = ItemCollectionEditing.creating(name: " HIST  210 ", itemID: "item-1", id: "c1", now: now, in: [])
        XCTAssertEqual(created, ItemCollection(id: "c1", name: "HIST 210", itemIDs: ["item-1"], createdAt: now))
        XCTAssertEqual(ItemCollectionEditing.creating(name: "Empty", itemID: nil, id: "c2", now: now, in: [])?.itemIDs, [])
    }

    func testCreatingRefusesABlankOrTakenName() {
        let existing = [collection("a", "HIST 210")]
        XCTAssertNil(ItemCollectionEditing.creating(name: "  ", itemID: "x", id: "c", now: now, in: existing))
        XCTAssertNil(ItemCollectionEditing.creating(name: "hist 210", itemID: "x", id: "c", now: now, in: existing))
    }

    func testRenamingKeepsTheItemsAndBumpsUpdatedAt() {
        let original = collection("a", "HIST 210", ["i1", "i2"])
        let renamed = ItemCollectionEditing.renaming(original, to: "History 210", now: later, in: [original])
        XCTAssertEqual(renamed?.name, "History 210")
        XCTAssertEqual(renamed?.itemIDs, ["i1", "i2"])
        XCTAssertEqual(renamed?.updatedAt, later)
        XCTAssertEqual(renamed?.createdAt, now)
    }

    func testRenamingToItsOwnNameInAnotherCaseIsAllowedButToAnotherCollectionsNameIsNot() {
        let first = collection("a", "HIST 210"), second = collection("b", "Book club")
        XCTAssertEqual(ItemCollectionEditing.renaming(first, to: "hist 210", now: later, in: [first, second])?.name, "hist 210")
        XCTAssertNil(ItemCollectionEditing.renaming(first, to: "BOOK CLUB", now: later, in: [first, second]))
        XCTAssertNil(ItemCollectionEditing.renaming(first, to: "   ", now: later, in: [first, second]))
    }

    func testTogglingAddsAtTheEndThenTakesTheItemOut() {
        let start = collection("a", "HIST 210", ["i1"])
        let added = ItemCollectionEditing.toggling(itemID: "i2", in: start, now: later)
        XCTAssertEqual(added.itemIDs, ["i1", "i2"])
        XCTAssertEqual(added.updatedAt, later)
        XCTAssertEqual(ItemCollectionEditing.toggling(itemID: "i1", in: added, now: later).itemIDs, ["i2"])
    }

    // MARK: Margins scope

    func testACollectionScopeIncludesOnlyItsItems() {
        var query = MarginCollectionQuery()
        query.selectScope(tag: MarginCollectionQuery.collectionTagPrefix + "a", collections: [collection("a", "HIST", ["i1", "i2"])])
        XCTAssertTrue(query.includes(itemID: "i1"))
        XCTAssertTrue(query.includes(itemID: "i2"))
        XCTAssertFalse(query.includes(itemID: "i3"))
        XCTAssertFalse(query.includes(itemID: nil))
        XCTAssertNil(query.itemID)
    }

    func testTheItemAndAllScopesAreUnchanged() {
        var query = MarginCollectionQuery()
        XCTAssertTrue(query.includes(itemID: "anything"))
        XCTAssertTrue(query.includes(itemID: nil))
        query.selectScope(tag: "i1", collections: [])
        XCTAssertTrue(query.includes(itemID: "i1"))
        XCTAssertFalse(query.includes(itemID: "i2"))
        XCTAssertNil(query.collection)
        XCTAssertEqual(query.scopeTag, "i1")
    }

    func testChoosingAnItemLeavesTheCollectionAndBackToAllClearsBoth() {
        let collections = [collection("a", "HIST", ["i1"])]
        var query = MarginCollectionQuery()
        query.selectScope(tag: "collection:a", collections: collections)
        XCTAssertEqual(query.scopeTag, "collection:a")
        query.selectScope(tag: "i9", collections: collections)
        XCTAssertNil(query.collection)
        XCTAssertEqual(query.itemID, "i9")
        query.selectScope(tag: nil, collections: collections)
        XCTAssertNil(query.scopeTag)
        XCTAssertTrue(query.includes(itemID: "i3"))
    }

    func testATagForACollectionThatIsGoneMeansAllItems() {
        var query = MarginCollectionQuery(itemID: "i1")
        query.selectScope(tag: "collection:missing", collections: [])
        XCTAssertNil(query.scopeTag)
        XCTAssertTrue(query.includes(itemID: "i2"))
    }

    func testRefreshingPicksUpNewItemsAndDropsADeletedCollection() {
        var query = MarginCollectionQuery()
        query.selectScope(tag: "collection:a", collections: [collection("a", "HIST", ["i1"])])
        XCTAssertFalse(query.includes(itemID: "i2"))
        query.refreshCollection(from: [collection("a", "HIST", ["i1", "i2"])])
        XCTAssertTrue(query.includes(itemID: "i2"))
        query.refreshCollection(from: [])
        XCTAssertNil(query.collection)
        XCTAssertTrue(query.includes(itemID: "i3"))
    }

    func testRefreshingLeavesAnItemScopeAlone() {
        var query = MarginCollectionQuery(itemID: "i1")
        query.refreshCollection(from: [])
        XCTAssertEqual(query.itemID, "i1")
    }

    func testTheScopeKeepsTheOtherFilters() {
        var query = MarginCollectionQuery(text: "wages", filter: .starred)
        query.selectScope(tag: "collection:a", collections: [collection("a", "HIST", ["i1"])])
        XCTAssertEqual(query.text, "wages")
        XCTAssertEqual(query.filter, .starred)
    }
}
