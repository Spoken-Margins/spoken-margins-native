import XCTest
@testable import SessionKit

final class SessionShareFilesTests: XCTestCase {
    private var temporary: URL!
    private var root: URL { SessionShareFiles.shareRoot(in: temporary) }

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("session-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: temporary) }

    private func sources() -> [SessionShareFiles.Source] {
        let date = Date(timeIntervalSince1970: 1_769_068_800)
        return [.init(sessionId: "session-a", itemTitle: "First article", sessionDate: date),
                .init(sessionId: "session-b", itemTitle: "Second article", sessionDate: date)]
    }

    func testTwoSessionsBecomeTwoMarkdownFilesUnderTheShareRootAndNothingElseIsWritten() throws {
        let files = SessionShareFiles.build(sources(), root: root) { "# " + $0.itemTitle }

        XCTAssertEqual(files.fileURLs.count, 2)
        XCTAssertTrue(files.failures.isEmpty)
        let directory = try XCTUnwrap(files.directory)
        XCTAssertEqual(directory.deletingLastPathComponent().standardizedFileURL.path, root.standardizedFileURL.path)
        for url in files.fileURLs {
            XCTAssertEqual(url.pathExtension, "md")
            XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path, directory.standardizedFileURL.path)
        }
        XCTAssertEqual(try String(contentsOf: files.fileURLs[0], encoding: .utf8), "# First article")
        XCTAssertTrue(files.fileURLs[0].lastPathComponent.hasPrefix("First article — "))
        XCTAssertEqual(try String(contentsOf: files.fileURLs[1], encoding: .utf8), "# Second article")
        // Only the share root was created inside the temporary folder.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporary.path), [SessionShareFiles.folderName])
    }

    func testTwoSessionsWithTheSameTitleAndMinuteKeepBothFiles() throws {
        let date = Date(timeIntervalSince1970: 1_769_068_800)
        let same = [SessionShareFiles.Source(sessionId: "a", itemTitle: "Same", sessionDate: date),
                    SessionShareFiles.Source(sessionId: "b", itemTitle: "Same", sessionDate: date)]
        let files = SessionShareFiles.build(same, root: root) { $0.sessionId }
        XCTAssertEqual(Set(files.fileURLs.map(\.lastPathComponent)).count, 2)
        XCTAssertEqual(try files.fileURLs.map { try String(contentsOf: $0, encoding: .utf8) }, ["a", "b"])
    }

    func testOneSessionFailingIsListedAndTheOthersAreStillBuilt() throws {
        struct Broken: LocalizedError { var errorDescription: String? { "export failed" } }
        let files = SessionShareFiles.build(sources(), root: root) {
            if $0.sessionId == "session-a" { throw Broken() }
            return "ok"
        }
        XCTAssertEqual(files.fileURLs.count, 1)
        XCTAssertEqual(files.failures, ["First article: export failed"])
        XCTAssertNotNil(files.directory)
    }

    func testWhenEverySessionFailsNoFolderIsLeftBehind() throws {
        struct Broken: Error {}
        let files = SessionShareFiles.build(sources(), root: root) { _ in throw Broken() }
        XCTAssertTrue(files.fileURLs.isEmpty)
        XCTAssertEqual(files.failures.count, 2)
        XCTAssertNil(files.directory)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    // The off-main build (#2510): same files, same failure text, but the folder and the file writes leave the
    // calling thread.

    @MainActor
    func testOffMainBuildMakesTheSameFilesAsTheSynchronousBuild() async throws {
        let sync = SessionShareFiles.build(sources(), root: root) { "# " + $0.itemTitle }
        let off = await SessionShareFiles.buildOffMain(sources(), root: root) { "# " + $0.itemTitle }

        XCTAssertEqual(off.fileURLs.map(\.lastPathComponent), sync.fileURLs.map(\.lastPathComponent))
        XCTAssertEqual(try off.fileURLs.map { try String(contentsOf: $0, encoding: .utf8) }, ["# First article", "# Second article"])
        XCTAssertTrue(off.failures.isEmpty)
        let directory = try XCTUnwrap(off.directory)
        XCTAssertEqual(directory.deletingLastPathComponent().standardizedFileURL.path, root.standardizedFileURL.path)
    }

    @MainActor
    func testOffMainBuildRendersOnTheCallersActorAndWritesAwayFromIt() async throws {
        var renderedOnMain: [Bool] = []
        let files = await SessionShareFiles.buildOffMain(sources(), root: root) { _ in
            renderedOnMain.append(Thread.isMainThread)
            // A render that suspends (the app's store read) lets the main actor run other work in between.
            await Task.yield()
            return "text"
        }
        XCTAssertEqual(renderedOnMain, [true, true])
        XCTAssertEqual(files.fileURLs.count, 2)
    }

    @MainActor
    func testOffMainBuildListsAFailureAndStillBuildsTheOthers() async throws {
        struct Broken: LocalizedError { var errorDescription: String? { "export failed" } }
        let files = await SessionShareFiles.buildOffMain(sources(), root: root) {
            if $0.sessionId == "session-a" { throw Broken() }
            return "ok"
        }
        XCTAssertEqual(files.fileURLs.count, 1)
        XCTAssertEqual(files.failures, ["First article: export failed"])
        XCTAssertNotNil(files.directory)
    }

    @MainActor
    func testOffMainBuildLeavesNoFolderWhenEverySessionFails() async throws {
        struct Broken: Error {}
        let files = await SessionShareFiles.buildOffMain(sources(), root: root) { _ in throw Broken() }
        XCTAssertTrue(files.fileURLs.isEmpty)
        XCTAssertEqual(files.failures.count, 2)
        XCTAssertNil(files.directory)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    @MainActor
    func testOffMainBuildCancelledPartWayRemovesWhatItWroteAndListsTheRest() async throws {
        let task = Task { @MainActor in
            await SessionShareFiles.buildOffMain(self.sources(), root: self.root) { source in
                if source.sessionId == "session-a" { withUnsafeCurrentTask { $0?.cancel() } }
                return "text"
            }
        }
        let files = await task.value
        XCTAssertNil(files.directory)
        XCTAssertTrue(files.fileURLs.isEmpty)
        XCTAssertEqual(files.failures, ["Second article: cancelled"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [], "no half share is left behind")
    }

    func testDiscardRemovesOnlyThisSharesFolder() throws {
        let one = SessionShareFiles.build(sources(), root: root) { _ in "one" }
        let other = SessionShareFiles.build(sources(), root: root) { _ in "other" }
        one.discard(root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(one.directory).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(other.directory).path), "another share's files stay")

        // A folder that is not under the share root is never removed.
        let outside = temporary.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        SessionShareFiles(directory: outside, fileURLs: [], failures: []).discard(root: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testLeftoversFromAKilledAppAreRemovedAtLaunch() throws {
        _ = SessionShareFiles.build(sources(), root: root) { _ in "left behind" }
        _ = SessionShareFiles.build(sources(), root: root) { _ in "left behind" }
        SessionShareFiles.removeLeftovers(root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        SessionShareFiles.removeLeftovers(root: root) // nothing there: no error
    }

    func testSharedSummaryNamesTheActivityOnlyWhenIOSGivesAKnownOne() {
        XCTAssertEqual(SessionShareFiles.sharedSummary(count: 2, activityType: nil), "Shared 2 files")
        XCTAssertEqual(SessionShareFiles.sharedSummary(count: 1, activityType: nil), "Shared 1 file")
        XCTAssertEqual(SessionShareFiles.sharedSummary(count: 2, activityType: "com.apple.UIKit.activity.AirDrop"), "Shared 2 files with AirDrop")
        XCTAssertEqual(SessionShareFiles.sharedSummary(count: 3, activityType: "com.apple.DocumentManagerUICore.SaveToFiles"), "Shared 3 files with Save to Files")
        // Another app's identifier is not shown to the listener.
        XCTAssertEqual(SessionShareFiles.sharedSummary(count: 2, activityType: "com.example.Notes.ShareExtension"), "Shared 2 files")
        XCTAssertEqual(SessionShareFiles.sharedSummary(count: 2, activityType: ""), "Shared 2 files")
    }
}
