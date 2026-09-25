import Foundation
import XCTest
@testable import DesktopCore

final class DesktopChapterSummaryStoreTests: XCTestCase {
    func testSummariesPersistOnlyForMatchingSourceText() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesktopChapterSummaries-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DesktopChapterSummaryStore(directory: directory)
        try store.save(["chapter-1": "A short local summary."], itemID: "item-1", sourceText: "First source 🧭")

        XCTAssertEqual(store.load(itemID: "item-1", sourceText: "First source 🧭")["chapter-1"],
                       "A short local summary.")
        XCTAssertTrue(store.load(itemID: "item-1", sourceText: "Changed source 🧭").isEmpty)
        XCTAssertTrue(store.load(itemID: "item-2", sourceText: "First source 🧭").isEmpty)
    }
}
