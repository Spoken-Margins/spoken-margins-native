import XCTest
@testable import SessionKit

/// #581: a Margin note the listener edited in their notes app is kept, and keeping it is not a failure.
final class MarginNoteDeliveryTests: XCTestCase {
    func testAnEditedNoteIsKeptNotRewritten() {
        // Written once by the app ("a"), then edited by the listener ("mine"); the Margin changed to "b".
        XCTAssertEqual(MarginNoteDelivery.action(existing: "mine", intended: "b", journalPrevious: nil, journalIntended: "a"), .keepListenerEdit)
        // A file that predates the journal is not the app's to replace.
        XCTAssertEqual(MarginNoteDelivery.action(existing: "mine", intended: "b", journalPrevious: nil, journalIntended: nil), .keepListenerEdit)
    }

    func testTheAppRewritesOnlyItsOwnBytes() {
        XCTAssertEqual(MarginNoteDelivery.action(existing: nil, intended: "a", journalPrevious: nil, journalIntended: nil), .write)
        XCTAssertEqual(MarginNoteDelivery.action(existing: "a", intended: "a", journalPrevious: nil, journalIntended: nil), .upToDate)
        XCTAssertEqual(MarginNoteDelivery.action(existing: "a", intended: "b", journalPrevious: nil, journalIntended: "a"), .write)
        // Interrupted after the journal was committed but before the file was replaced.
        XCTAssertEqual(MarginNoteDelivery.action(existing: "a", intended: "b", journalPrevious: "a", journalIntended: "c"), .write)
    }

    func testAPassWithAnEditedNoteReadsCalm() {
        let summary = MarginNoteDelivery.Summary(saved: 1, keptEdits: 1)
        XCTAssertNil(MarginNoteDelivery.failureMessage(summary))
        let line = MarginNoteDelivery.statusLine(summary, folderName: "Vault", checkedAt: "3:04 PM")
        XCTAssertEqual(line, "1 Margin saved to Vault. 1 note you edited was left as is. Last checked 3:04 PM.")
        XCTAssertFalse(line.contains("attention"))
        XCTAssertFalse(line.contains("Choose another output folder"))
    }

    func testCountsReadRightForOneAndMany() {
        XCTAssertEqual(
            MarginNoteDelivery.statusLine(.init(saved: 3), folderName: "Vault", checkedAt: "9:00 AM"),
            "3 Margins saved to Vault. Last checked 9:00 AM."
        )
        XCTAssertEqual(
            MarginNoteDelivery.statusLine(.init(saved: 0, keptEdits: 2), folderName: "Vault", checkedAt: "9:00 AM"),
            "0 Margins saved to Vault. 2 notes you edited were left as is. Last checked 9:00 AM."
        )
    }

    func testRealFailuresStillNeedAttention() {
        XCTAssertEqual(
            MarginNoteDelivery.failureMessage(.init(saved: 1, failures: ["The folder is read-only."])),
            "1 Margin delivered; 1 needs attention. The folder is read-only."
        )
        XCTAssertEqual(
            MarginNoteDelivery.failureMessage(.init(saved: 2, keptEdits: 1, failures: ["Disk full.", "Disk full."])),
            "2 Margins delivered; 2 need attention. 1 note you edited was left as is. Disk full."
        )
    }
}
