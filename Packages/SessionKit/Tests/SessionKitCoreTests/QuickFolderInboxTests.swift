import Foundation
import XCTest
@testable import SessionKit

final class QuickFolderInboxTests: XCTestCase {
    private func file(_ name: String, at seconds: TimeInterval = 100) -> QuickAccessFile {
        QuickAccessFile(id: name, name: name, relativePath: name, modifiedAt: Date(timeIntervalSince1970: seconds), modifiedAtDescription: "")
    }

    func testNoBaselineMarksCurrentFilesSeenAndImportsNone() {
        let files = [file("a.md"), file("b.md")]
        let plan = QuickFolderInbox.plan(files: files, seenKeys: nil, dismissedKeys: [])
        XCTAssertTrue(plan.toImport.isEmpty)
        XCTAssertEqual(plan.newSeenKeys, Set(files.map(\.id)))
    }

    func testNewFilesComeInFilenameOrderWithNumbersByValue() {
        let seen = file("old.md")
        let plan = QuickFolderInbox.plan(
            files: [file("ch10.md"), seen, file("Ch2.md"), file("ch1.md")],
            seenKeys: [seen.id], dismissedKeys: []
        )
        XCTAssertEqual(plan.toImport.map(\.relativePath), ["ch1.md", "Ch2.md", "ch10.md"])
    }

    func testSeenAndDismissedFilesAreNotQueuedAgain() {
        let seen = file("a.md"), dismissed = file("b.md"), fresh = file("c.md")
        let plan = QuickFolderInbox.plan(
            files: [seen, dismissed, fresh], seenKeys: [seen.id], dismissedKeys: [dismissed.dismissalKey]
        )
        XCTAssertEqual(plan.toImport.map(\.relativePath), ["c.md"])
    }

    func testAFileEditedAfterItWasSeenIsNotQueuedAgain() {
        let before = file("a.md", at: 100), after = file("a.md", at: 200)
        let plan = QuickFolderInbox.plan(files: [after], seenKeys: [before.id], dismissedKeys: [])
        XCTAssertTrue(plan.toImport.isEmpty)
    }
}
