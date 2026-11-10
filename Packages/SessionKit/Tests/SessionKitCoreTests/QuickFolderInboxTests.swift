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

    // MARK: A batch of more than eight files (#3767)

    private func numbered(_ count: Int) -> [QuickAccessFile] {
        (1...count).map { file(String(format: "ch%02d.md", $0), at: 1_000 + TimeInterval($0)) }
    }

    func testNoBaselineMarksTheWholeFolderSeenNotJustTheNewestEight() {
        let files = numbered(20)
        let plan = QuickFolderInbox.plan(files: files, seenKeys: nil, dismissedKeys: [])
        XCTAssertTrue(plan.toImport.isEmpty)
        XCTAssertEqual(plan.newSeenKeys, Set(files.map(\.id)))
    }

    func testTwentyNewFilesArriveWholeInPassesOfEightInFilenameOrder() {
        let old = file("old.md", at: 1)
        let files = [old] + numbered(20)
        var seen: Set<String> = [old.id]
        var imported: [String] = []
        var passes = 0
        while true {
            let plan = QuickFolderInbox.plan(files: files, seenKeys: seen, dismissedKeys: [])
            if plan.toImport.isEmpty { break }
            XCTAssertLessThanOrEqual(plan.toImport.count, QuickFolderInbox.batchSize)
            imported += plan.toImport.map(\.id)
            seen.formUnion(plan.newSeenKeys)
            passes += 1
            XCTAssertLessThan(passes, 10, "the passes must end")
        }
        XCTAssertEqual(passes, 3, "20 files at eight a pass")
        XCTAssertEqual(imported, numbered(20).map(\.id), "every file once, in filename order across the passes")
    }

    /// The inbox used to be handed only the newest eight files, so a baseline kept by those builds lists at most eight
    /// names. The inbox now sees the whole folder; without this, every older file would look new and flood the queue.
    func testABaselineThatOnlyKnewTheNewestEightDoesNotSweepInOlderFiles() {
        let files = numbered(12) // ch01 is the oldest
        let oldBaseline = Set(files.suffix(8).map(\.id)) // the newest eight, as the old build kept them
        let upgraded = QuickFolderInbox.plan(
            files: files, seenKeys: oldBaseline, dismissedKeys: [], seenCoversWholeFolder: false)
        XCTAssertTrue(upgraded.toImport.isEmpty, "the four older files were there before the upgrade")
        XCTAssertEqual(upgraded.grandfatheredKeys, Set(files.prefix(4).map(\.id)))
        // Once the caller records that the seen set covers the folder, the same call treats a file as new again.
        let afterwards = QuickFolderInbox.plan(
            files: files, seenKeys: oldBaseline.union(upgraded.grandfatheredKeys), dismissedKeys: [])
        XCTAssertTrue(afterwards.toImport.isEmpty)
        // With the flag already true, the same four files would be imported: this is what the flag prevents.
        let withoutTheGuard = QuickFolderInbox.plan(files: files, seenKeys: oldBaseline, dismissedKeys: [])
        XCTAssertEqual(withoutTheGuard.toImport.map(\.id), files.prefix(4).map(\.id))
    }

    func testAFileInsideTheNewestEightStillImportsWhenTheBaselineIsUpgraded() {
        let files = numbered(12)
        let oldBaseline = Set(files.suffix(8).map(\.id)).subtracting(["ch12.md"]) // ch12 is the new one
        let plan = QuickFolderInbox.plan(
            files: files, seenKeys: oldBaseline, dismissedKeys: [], seenCoversWholeFolder: false)
        XCTAssertEqual(plan.toImport.map(\.id), ["ch12.md"])
        XCTAssertEqual(plan.grandfatheredKeys, Set(files.prefix(4).map(\.id)))
    }

    func testGrandfatheringLeavesTheFilesTheListenerAlreadyDismissedAlone() {
        let files = numbered(12)
        let dismissed = files[0]
        let plan = QuickFolderInbox.plan(
            files: files, seenKeys: Set(files.suffix(8).map(\.id)), dismissedKeys: [dismissed.dismissalKey],
            seenCoversWholeFolder: false)
        XCTAssertTrue(plan.toImport.isEmpty)
        XCTAssertEqual(plan.grandfatheredKeys.count, 4, "marked seen too, which is harmless: it stays out either way")
    }
}
