import XCTest
@testable import SessionKit

final class ImportInboxSummaryTests: XCTestCase {
    func testDesignTable() {
        let rows: [(failed: Int, waiting: Int, text: String?, symbol: String?, voiceOver: String)] = [
            (0, 0, nil, nil, "Empty"),
            (1, 0, "1 failed", "exclamationmark.triangle", "1 failed share"),
            (2, 0, "2 failed", "exclamationmark.triangle", "2 failed shares"),
            (0, 1, "1 waiting", "wifi.slash", "1 link waiting for a connection"),
            (0, 3, "3 waiting", "wifi.slash", "3 links waiting for a connection"),
            (1, 1, "1 failed · 1 waiting", "exclamationmark.triangle", "1 failed share, 1 link waiting for a connection"),
            (2, 3, "2 failed · 3 waiting", "exclamationmark.triangle", "2 failed shares, 3 links waiting for a connection"),
            (120, 0, "120 failed", "exclamationmark.triangle", "120 failed shares"),
        ]
        for row in rows {
            let summary = ImportInboxSummary(failedCount: row.failed, waitingCount: row.waiting)
            let label = "failed \(row.failed), waiting \(row.waiting)"
            XCTAssertEqual(summary.trailingText, row.text, label)
            XCTAssertEqual(summary.symbolName, row.symbol, label)
            XCTAssertEqual(summary.accessibilityValue, row.voiceOver, label)
            XCTAssertEqual(summary.needsAttention, row.failed > 0, label)
        }
    }

    func testNegativeCountsAreTreatedAsZero() {
        for (failed, waiting) in [(-1, 0), (0, -1), (-1, -1), (-5, -20)] {
            let summary = ImportInboxSummary(failedCount: failed, waitingCount: waiting)
            XCTAssertEqual(summary, ImportInboxSummary(failedCount: 0, waitingCount: 0))
            XCTAssertNil(summary.trailingText)
            XCTAssertNil(summary.symbolName)
            XCTAssertEqual(summary.accessibilityValue, "Empty")
            XCTAssertFalse(summary.needsAttention)
        }
        let mixed = ImportInboxSummary(failedCount: -1, waitingCount: 2)
        XCTAssertEqual(mixed.trailingText, "2 waiting")
        XCTAssertEqual(mixed.symbolName, "wifi.slash")
    }
}
