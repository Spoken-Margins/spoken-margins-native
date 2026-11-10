import Foundation
import XCTest
@testable import SessionKit

/// #3599: the AI Handoff export is text a listener shares, so its source line must not say "Item".
/// Layer that should have caught it: a host test on the renderer; the word guard only reads string literals.
final class HandoffExportWordsTests: XCTestCase {
    private func render(externalReference: String?) -> String {
        let export = SessionExport(
            item: ExportItem(id: "item", title: "Plan", externalReference: externalReference, sourceURL: nil,
                             mediaSourceType: nil, includedFullText: false, text: nil),
            session: ExportSession(id: "s", status: "in_progress", completionPercent: 40),
            listeningMap: nil, turns: [], timeline: [], interjections: []
        )
        return SessionExportMarkdownRenderer.render(export)
    }

    func testTheSourceReferenceLineIsLabelledReferenceNotItem() {
        let lines = render(externalReference: "https://example.com/a").split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains("Reference: https://example.com/a"))
        XCTAssertFalse(lines.contains { $0.hasPrefix("Item:") }, "the export still labels the source \"Item\"")
    }

    func testNoReferenceMeansNoReferenceLine() {
        for reference in [nil, ""] as [String?] {
            let lines = render(externalReference: reference).split(separator: "\n").map(String.init)
            XCTAssertFalse(lines.contains { $0.hasPrefix("Reference:") || $0.hasPrefix("Item:") }, "reference \(String(describing: reference))")
        }
    }
}
