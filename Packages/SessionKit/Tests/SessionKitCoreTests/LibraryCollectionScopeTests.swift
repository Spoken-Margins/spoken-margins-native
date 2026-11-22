import Foundation
import XCTest
@testable import SessionKit

/// #4343, #3769: the order collections are listed in, and the record a shipped build wrote.
final class LibraryCollectionScopeTests: XCTestCase {
    private func collection(_ id: String, _ members: [String], name: String? = nil) -> ItemCollection {
        ItemCollection(id: id, name: name ?? id, itemIDs: members, createdAt: Date(timeIntervalSince1970: 1))
    }

    private func row(_ id: String) -> LibraryItemRow {
        LibraryItemRow(id: id, title: "Title \(id)", status: "ready", canDelete: true, mediaType: "text", storageRecencyRank: .max)
    }

    func testCollectionsAreAlphabeticalLocalizedAndCaseInsensitiveWithTiesByID() {
        let collections = [
            collection("3", [], name: "zebra readings"),
            collection("2", [], name: "Éclair club"),
            collection("1", [], name: "apple course"),
            collection("5", [], name: "Apple Course"),
            collection("4", [], name: "HIST 210"),
        ]
        XCTAssertEqual(LibraryCollectionScope.chipOrder(collections).map(\.id), ["1", "5", "2", "4", "3"])
        XCTAssertEqual(LibraryCollectionScope.chipOrder(collections.reversed()).map(\.id), ["1", "5", "2", "4", "3"], "input order never matters")
        XCTAssertEqual(LibraryCollectionScope.chipOrder([]).map(\.id), [])
    }

    /// The record a build that already shipped collections wrote: this build must read it unchanged, and count only
    /// members that are Library rows.
    func testACollectionRecordFromThePreviousBuildDecodes() throws {
        let json = #"{"id":"course","name":"HIST 210","itemIDs":["a","b","a"],"createdAt":"2026-10-01T12:00:00Z","updatedAt":"2026-10-02T12:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ItemCollection.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.name, "HIST 210")
        let rows = Dictionary(uniqueKeysWithValues: ["b", "c"].map { ($0, row($0)) })
        XCTAssertEqual(LibraryCollectionProgress(collection: decoded, rows: rows).itemIDs, ["b"], "a member not in the Library isn't counted")
    }
}
