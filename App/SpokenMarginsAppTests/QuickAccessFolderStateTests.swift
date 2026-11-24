import Combine
import SwiftUI
import UIKit
import XCTest
import SessionKit
@testable import SpokenMarginsApp

/// #981 (split slice T8): the Quick Access folder concern, pinned as `QuickAccessFolderState`. These use real
/// temporary folders, real bookmarks and isolated UserDefaults suites. Only the folder scan and the
/// scoped-access calls are held or recorded, so a test can finish two overlapping scans in either order and pin
/// the order of start and stop calls.
@MainActor
final class QuickAccessFolderStateTests: XCTestCase {
    private var priorDismissedKeys: Any?

    override func setUp() {
        super.setUp()
        // The model tests below write the dismissed keys to the standard defaults.
        priorDismissedKeys = UserDefaults.standard.object(forKey: "dismissedQuickAccessFilesV1")
    }

    override func tearDown() {
        if let priorDismissedKeys {
            UserDefaults.standard.set(priorDismissedKeys, forKey: "dismissedQuickAccessFilesV1")
        } else {
            UserDefaults.standard.removeObject(forKey: "dismissedQuickAccessFilesV1")
        }
        super.tearDown()
    }

    // MARK: Stale refresh guard

    /// A refresh that started later wins, whichever scan finishes first. Removing the refresh-ID check makes
    /// the late scan publish its files, drop the newer spinner and write the diagnostics a second time.
    func testASecondRefreshWinsWhenTheFirstScanFinishesFirst() async throws {
        let fixture = try makeFixture()
        fixture.state.refresh()
        try await waitFor("first scan starts") { fixture.bench.scansStarted == 1 }
        fixture.state.refresh()
        try await waitFor("second scan starts") { fixture.bench.scansStarted == 2 }
        XCTAssertEqual(fixture.bench.cancelledScans, 1, "a newer refresh cancels the older task")

        fixture.bench.finishScan(0, with: Self.scan(["a"]))
        try await waitFor("first scan's access stops") { fixture.bench.count("stop") == 1 }
        XCTAssertTrue(fixture.state.isRefreshing, "the newer refresh is still running")
        XCTAssertEqual(fixture.state.recentFiles, [])
        XCTAssertEqual(fixture.log.entries.count, 0, "a stale scan writes no diagnostics")

        fixture.bench.finishScan(1, with: Self.scan(["b"]))
        try await waitFor("second scan's access stops") { fixture.bench.count("stop") == 2 }
        XCTAssertEqual(fixture.state.recentFiles.map(\.id), ["b"])
        XCTAssertFalse(fixture.state.isRefreshing)
        XCTAssertEqual(fixture.state.folderName, fixture.folder.lastPathComponent)
        XCTAssertEqual(fixture.log.value(for: "quickAccessRecentFiles"), "1")
    }

    func testASecondRefreshWinsWhenTheFirstScanFinishesLast() async throws {
        let fixture = try makeFixture()
        fixture.state.refresh()
        try await waitFor("first scan starts") { fixture.bench.scansStarted == 1 }
        fixture.state.refresh()
        try await waitFor("second scan starts") { fixture.bench.scansStarted == 2 }

        fixture.bench.finishScan(1, with: Self.scan(["b"]))
        try await waitFor("second scan's access stops") { fixture.bench.count("stop") == 1 }
        XCTAssertEqual(fixture.state.recentFiles.map(\.id), ["b"])
        XCTAssertFalse(fixture.state.isRefreshing)
        let diagnosticsAfterWinner = fixture.log.entries.count

        fixture.bench.finishScan(0, with: Self.scan(["a"]))
        try await waitFor("first scan's access stops") { fixture.bench.count("stop") == 2 }
        XCTAssertEqual(fixture.state.recentFiles.map(\.id), ["b"], "the stale scan must not replace the newer files")
        XCTAssertFalse(fixture.state.isRefreshing)
        XCTAssertEqual(fixture.log.entries.count, diagnosticsAfterWinner)
    }

    func testClearingTheFolderWhileAScanRunsDropsThatScan() async throws {
        let fixture = try makeFixture()
        fixture.state.folderName = "Vault"
        fixture.state.recentFiles = [Self.file("old")]
        fixture.state.followingPool = [Self.file("old")]
        fixture.state.refresh()
        try await waitFor("scan starts") { fixture.bench.scansStarted == 1 }
        XCTAssertTrue(fixture.state.isRefreshing)

        fixture.defaults.removeObject(forKey: "quickAccessFolderBookmark")
        fixture.state.refresh()
        XCTAssertFalse(fixture.state.isRefreshing, "no folder, no spinner")
        XCTAssertEqual(fixture.state.recentFiles, [])
        XCTAssertEqual(fixture.state.followingPool, [])
        XCTAssertEqual(fixture.state.folderName, "Vault", "the displayed name stays")
        XCTAssertEqual(fixture.bench.cancelledScans, 1)

        fixture.bench.finishScan(0, with: Self.scan(["late"]))
        try await waitFor("scan's access stops") { fixture.bench.count("stop") == 1 }
        XCTAssertEqual(fixture.state.recentFiles, [])
        XCTAssertFalse(fixture.state.isRefreshing)
        XCTAssertEqual(fixture.log.entries.count, 0)
    }

    func testAScanErrorClearsTheFilesAndKeepsTheName() async throws {
        let fixture = try makeFixture()
        fixture.state.folderName = "Vault"
        fixture.state.recentFiles = [Self.file("old")]
        fixture.state.followingPool = [Self.file("old")]
        fixture.state.refresh()
        try await waitFor("scan starts") { fixture.bench.scansStarted == 1 }
        fixture.bench.finishScan(0, with: QuickAccessFolderScan(files: [], errorDescription: "unreadable"))
        try await waitFor("scan's access stops") { fixture.bench.count("stop") == 1 }
        XCTAssertEqual(fixture.state.recentFiles, [])
        XCTAssertEqual(fixture.state.followingPool, [])
        XCTAssertEqual(fixture.state.folderName, "Vault")
        XCTAssertFalse(fixture.state.isRefreshing)
        XCTAssertEqual(fixture.log.value(for: "quickAccessError"), "unreadable")
    }

    // MARK: Files past the newest eight (#4274)

    /// 12 files saved after the folder was chosen: once the newest 8 are dismissed (adding a file dismisses it too), the older 4
    /// are listed, each with its time. Before #4274 Following listed only the scan's newest 8, so these 4 never appeared.
    func testNewFilesPastTheNewestEightAppearOnceNewerOnesAreDismissed() async throws {
        let fixture = try makeFixture(now: { Self.chosenAt })
        XCTAssertEqual(fixture.state.folderChosenAt, Self.chosenAt, "a folder saved by an earlier build takes this launch as its date")
        fixture.state.refresh()
        try await waitFor("scan starts") { fixture.bench.scansStarted == 1 }
        fixture.bench.finishScan(0, with: Self.scan(dated: Self.twelveFiles(newestAt: Self.chosenAt.addingTimeInterval(3_600))))
        try await waitFor("scan stored") { fixture.state.lastCheckedAt != nil }
        XCTAssertEqual(fixture.state.recentFiles.count, 8, "the Add sheet keeps the newest eight")
        XCTAssertEqual(fixture.state.followingPool.count, 12)
        XCTAssertEqual(Self.localFileIDs(fixture.state), Array(Self.twelveIDs.prefix(8)))

        fixture.state.followingPool.prefix(8).forEach { fixture.state.dismiss($0) }

        let listed = Self.localFiles(fixture.state)
        XCTAssertEqual(listed.map(\.id), Array(Self.twelveIDs.suffix(4)))
        XCTAssertTrue(listed.allSatisfy { !$0.modifiedAtDescription.isEmpty }, "each listed row keeps its time")
    }

    /// The same 12 files, all older than the folder's date: only the newest 8 are ever listed, as before, so a long-lived
    /// folder's old files don't come back as new.
    func testOldFilesPastTheNewestEightStayHidden() async throws {
        let fixture = try makeFixture(now: { Self.chosenAt })
        fixture.state.refresh()
        try await waitFor("scan starts") { fixture.bench.scansStarted == 1 }
        fixture.bench.finishScan(0, with: Self.scan(dated: Self.twelveFiles(newestAt: Self.chosenAt.addingTimeInterval(-60))))
        try await waitFor("scan stored") { fixture.state.lastCheckedAt != nil }
        XCTAssertEqual(fixture.state.followingPool.count, 8)

        fixture.state.followingPool.forEach { fixture.state.dismiss($0) }

        XCTAssertEqual(Self.localFileIDs(fixture.state), [])
    }

    /// The date is set once on upgrade and stored, kept when the same folder is chosen again (Choose Folder or Choose Folder
    /// Again), restarted for a different folder, and cleared with the folder.
    func testTheChosenDateIsSetOnUpgradeKeptForTheSameFolderAndClearedOnRemove() async throws {
        let clock = SettableClock(Self.chosenAt)
        let fixture = try makeFixture(now: { clock.now })
        XCTAssertEqual(fixture.state.folderChosenAt, Self.chosenAt)
        XCTAssertEqual(fixture.defaults.object(forKey: "quickAccessFolderChosenAt") as? Date, Self.chosenAt)
        clock.now = Self.chosenAt.addingTimeInterval(100)
        let reopened = QuickAccessFolderState(defaults: fixture.defaults, dependencies: fixture.bench.dependencies())
        XCTAssertEqual(reopened.folderChosenAt, Self.chosenAt, "a later launch reads the stored date")

        fixture.state.refresh()
        try await waitFor("scan starts") { fixture.bench.scansStarted == 1 }
        fixture.bench.finishScan(0, with: Self.scan(["a"]))
        try await waitFor("scan stored") { fixture.state.lastCheckedAt != nil }

        clock.now = Self.chosenAt.addingTimeInterval(200)
        try fixture.state.configure(url: URL(fileURLWithPath: fixture.folder.path, isDirectory: true)) {}
        XCTAssertEqual(fixture.state.folderChosenAt, Self.chosenAt, "Choose Folder on the same folder keeps its date")
        try await waitFor("second scan starts") { fixture.bench.scansStarted == 2 }
        fixture.bench.finishScan(1, with: Self.scan(["a"]))
        try await waitFor("second scan stored") { fixture.state.folderPath != nil && !fixture.state.isRefreshing }
        let decision = try fixture.state.reconnect(url: fixture.folder) {}
        XCTAssertEqual(decision, .keepSeenFiles)
        XCTAssertEqual(fixture.state.folderChosenAt, Self.chosenAt, "Choose Folder Again on the same folder keeps its date")
        try await waitFor("third scan starts") { fixture.bench.scansStarted == 3 }
        fixture.bench.finishScan(2, with: Self.scan(["a"]))
        try await waitFor("third scan stored") { !fixture.state.isRefreshing }

        let other = try makeFolder(named: fixture.folder.lastPathComponent)
        clock.now = Self.chosenAt.addingTimeInterval(300)
        try fixture.state.configure(url: other) {}
        XCTAssertEqual(fixture.state.folderChosenAt, Self.chosenAt.addingTimeInterval(300), "a different folder starts its own date")
        try await waitFor("fourth scan starts") { fixture.bench.scansStarted == 4 }

        fixture.state.remove()
        fixture.bench.finishScan(3, with: Self.scan(["late"]))
        XCTAssertNil(fixture.state.folderChosenAt)
        XCTAssertNil(fixture.defaults.object(forKey: "quickAccessFolderChosenAt"))
        XCTAssertNil(QuickAccessFolderState(defaults: try makeDefaults()).folderChosenAt, "no folder, no date")
    }

    // MARK: Lifetime and scoped access

    /// The scan holds the folder's access on its own: it starts before the scan, stops once after it, and
    /// still stops when the state was freed in between. Freeing the state cancels the task.
    func testScopedAccessStopsExactlyOnceAfterTheScanEvenIfTheOwnerIsGone() async throws {
        let defaults = try makeDefaults()
        let folder = try makeFolder()
        try save(folder, in: defaults)
        let bench = ScanBench()
        var state: QuickAccessFolderState? = QuickAccessFolderState(defaults: defaults, dependencies: bench.dependencies())
        weak var weakState = state
        state?.refresh()
        try await waitFor("scan starts") { bench.scansStarted == 1 }

        state = nil
        XCTAssertNil(weakState, "the refresh task must not keep its owner alive")
        try await waitFor("task cancelled by deinit") { bench.cancelledScans == 1 }
        XCTAssertEqual(bench.events, ["start", "scan"], "access is held while the scan runs")

        bench.finishScan(0, with: Self.scan(["a"]))
        try await waitFor("access stops") { bench.count("stop") == 1 }
        XCTAssertEqual(bench.events, ["start", "scan", "stop"])
    }

    func testConfigureHoldsAccessThroughSavingRefreshKickoffAndReporting() async throws {
        let defaults = try makeDefaults()
        let folder = try makeFolder(named: "Vault")
        let bench = ScanBench()
        let state = QuickAccessFolderState(defaults: defaults, dependencies: bench.dependencies())

        try state.configure(url: folder) { bench.record("saved") }

        XCTAssertEqual(bench.events, ["start", "saved", "stop"], "configure's access spans the report; the refresh resolves and starts its own access off the main actor (#3770)")
        XCTAssertEqual(state.folderName, "Vault")
        XCTAssertEqual(defaults.string(forKey: "quickAccessFolderName"), "Vault")
        XCTAssertNotNil(defaults.data(forKey: "quickAccessFolderBookmark"))
        XCTAssertTrue(state.isRefreshing)
        try await waitFor("scan starts") { bench.scansStarted == 1 }
        bench.finishScan(0, with: Self.scan(["a"]))
        try await waitFor("refresh's access stops") { bench.count("stop") == 2 }
        XCTAssertEqual(state.recentFiles.map(\.id), ["a"])
    }

    func testConfigureFailureSavesNothingAndStillBalancesAccess() throws {
        let defaults = try makeDefaults()
        defaults.set("Old", forKey: "quickAccessFolderName")
        let bench = ScanBench()
        let state = QuickAccessFolderState(defaults: defaults, dependencies: bench.dependencies())
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)", isDirectory: true)

        XCTAssertThrowsError(try state.configure(url: missing) { XCTFail("must not report success") })

        XCTAssertEqual(bench.events, ["start", "stop"])
        XCTAssertNil(defaults.data(forKey: "quickAccessFolderBookmark"))
        XCTAssertEqual(defaults.string(forKey: "quickAccessFolderName"), "Old")
        XCTAssertFalse(state.isRefreshing)
    }

    // MARK: Bookmark

    func testSavedFolderSurvivesAReopenAndKeepsItsKeys() throws {
        let defaults = try makeDefaults()
        let folder = try makeFolder(named: "Vault")
        let first = QuickAccessFolderState(defaults: defaults)
        try first.configure(url: folder) {}

        let reopened = QuickAccessFolderState(defaults: defaults)
        XCTAssertEqual(reopened.folderName, "Vault")
        XCTAssertEqual(reopened.resolvedFolderURL()?.resolvingSymlinksInPath().path, folder.resolvingSymlinksInPath().path)
        XCTAssertEqual(
            Set(defaults.dictionaryRepresentation().keys).intersection(["quickAccessFolderBookmark", "quickAccessFolderName"]),
            ["quickAccessFolderBookmark", "quickAccessFolderName"],
            "the keys Build 29 wrote are the keys this writes"
        )
    }

    func testAStaleBookmarkIsRefreshedUnderItsOwnBalancedAccess() throws {
        let defaults = try makeDefaults()
        let folder = try makeFolder()
        defaults.set(Data([9]), forKey: "quickAccessFolderBookmark")
        let bench = ScanBench()
        var dependencies = bench.dependencies()
        dependencies.resolveBookmark = { _ in (folder, true) }
        let state = QuickAccessFolderState(defaults: defaults, dependencies: dependencies)

        XCTAssertEqual(state.resolvedFolderURL(), folder)

        XCTAssertEqual(bench.events, ["start", "stop"])
        let refreshed = try XCTUnwrap(defaults.data(forKey: "quickAccessFolderBookmark"))
        XCTAssertNotEqual(refreshed, Data([9]), "the refreshed bookmark is written back")
    }

    func testABookmarkThatNoLongerResolvesIsReportedAndYieldsNoFolder() async throws {
        let defaults = try makeDefaults()
        defaults.set(Data([1, 2, 3]), forKey: "quickAccessFolderBookmark")
        let state = QuickAccessFolderState(defaults: defaults)
        let log = DiagnosticLog()
        state.recordDiagnostic = { log.append($0, $1) }

        XCTAssertNil(state.resolvedFolderURL())
        XCTAssertNotNil(log.value(for: "quickAccessBookmarkError"))

        state.followingPool = [Self.file("old")]
        state.refresh()
        try await waitFor("the refresh gives up on the bookmark") { !state.isRefreshing }
        XCTAssertEqual(state.followingPool, [])
        XCTAssertEqual(state.problem, .cantOpen, "a bookmark that doesn't resolve is \"can't open this folder\"")
        XCTAssertNil(QuickAccessFolderState(defaults: try makeDefaults()).resolvedFolderURL(), "no bookmark, no folder, no diagnostic")
    }

    func testImportURLsPointInsideTheFolderAndNeedASavedFolder() throws {
        let defaults = try makeDefaults()
        let folder = try makeFolder()
        let state = QuickAccessFolderState(defaults: defaults)
        XCTAssertNil(state.importURLs(for: Self.file("notes.md")))

        try save(folder, in: defaults)
        let urls = try XCTUnwrap(state.importURLs(for: Self.file("notes.md")))
        XCTAssertEqual(urls.fileURL.lastPathComponent, "notes.md")
        XCTAssertEqual(urls.fileURL.deletingLastPathComponent().resolvingSymlinksInPath().path, folder.resolvingSymlinksInPath().path)
        XCTAssertEqual(urls.folderURL.resolvingSymlinksInPath().path, folder.resolvingSymlinksInPath().path)
    }

    // MARK: What a scan remembers (#3770)

    nonisolated private static let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)

    /// A scan that finishes writes the folder's path and the time, and they survive a reopen. Without the write, Settings
    /// would have nothing to say about where the folder is or when it was last read.
    func testASuccessfulScanStoresThePathAndTheTimeAndTheyOutliveTheState() async throws {
        let fixture = try makeFixture(now: { Self.checkedAt })
        XCTAssertNil(fixture.state.folderPath)
        XCTAssertNil(fixture.state.lastCheckedAt)
        fixture.state.refresh()
        try await waitFor("scan starts") { fixture.bench.scansStarted == 1 }
        XCTAssertNil(fixture.state.lastCheckedAt, "nothing is stored until the scan finishes")
        fixture.bench.finishScan(0, with: Self.scan(["a"]))
        try await waitFor("scan stored") { fixture.state.lastCheckedAt != nil }

        XCTAssertEqual(fixture.state.lastCheckedAt, Self.checkedAt)
        XCTAssertEqual(fixture.state.folderPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }, fixture.folder.resolvingSymlinksInPath().path)
        XCTAssertNil(fixture.state.problem)
        let reopened = QuickAccessFolderState(defaults: fixture.defaults, dependencies: fixture.bench.dependencies())
        XCTAssertEqual(reopened.lastCheckedAt, Self.checkedAt)
        XCTAssertEqual(reopened.folderPath, fixture.state.folderPath)
        XCTAssertEqual(
            Set(fixture.defaults.dictionaryRepresentation().keys).intersection(["quickAccessFolderPath", "quickAccessLastCheckedAt"]),
            ["quickAccessFolderPath", "quickAccessLastCheckedAt"]
        )
    }

    /// A scan that can't read the folder marks it "can't open" and leaves the last good time and path alone; the next scan that
    /// works clears the mark. A scan that a newer refresh replaced writes nothing, and exactly one completion writes the time.
    func testAFailedScanMarksTheFolderAndTheNextGoodScanClearsIt() async throws {
        let ticks = Counter()
        let fixture = try makeFixture(now: { Self.checkedAt.addingTimeInterval(Double(ticks.next())) })
        fixture.state.refresh()
        try await waitFor("first scan starts") { fixture.bench.scansStarted == 1 }
        fixture.bench.finishScan(0, with: Self.scan(["a"]))
        try await waitFor("first scan stored") { fixture.state.lastCheckedAt != nil }
        let firstTime = fixture.state.lastCheckedAt
        let firstPath = fixture.state.folderPath

        fixture.state.refresh()
        try await waitFor("second scan starts") { fixture.bench.scansStarted == 2 }
        fixture.bench.finishScan(1, with: QuickAccessFolderScan(files: [], errorDescription: "unreadable"))
        try await waitFor("the failure is marked") { fixture.state.problem == .cantOpen }
        XCTAssertEqual(fixture.state.lastCheckedAt, firstTime, "a failed scan is not a check")
        XCTAssertEqual(fixture.state.folderPath, firstPath)
        XCTAssertEqual(QuickAccessFolderState(defaults: fixture.defaults, dependencies: fixture.bench.dependencies()).problem, .cantOpen)
        XCTAssertEqual(fixture.defaults.string(forKey: "quickAccessFolderProblem"), "cantOpen")

        fixture.state.refresh()
        try await waitFor("third scan starts") { fixture.bench.scansStarted == 3 }
        fixture.state.refresh()
        try await waitFor("fourth scan starts") { fixture.bench.scansStarted == 4 }
        fixture.bench.finishScan(2, with: Self.scan(["stale"]))
        try await waitFor("stale scan's access stops") { fixture.bench.count("stop") == 3 }
        XCTAssertEqual(fixture.state.problem, .cantOpen, "a replaced scan clears nothing")
        // Judged by the stored time, not by how often the clock was read: the state also reads it in `init` for an upgraded
        // folder's chosen-at date (#4274), and counting every read broke this test on main (#5217).
        XCTAssertEqual(fixture.state.lastCheckedAt, firstTime, "and writes no time")
        let readsBeforeTheGoodScan = ticks.value
        fixture.bench.finishScan(3, with: Self.scan(["b"]))
        try await waitFor("the good scan clears the mark") { fixture.state.problem == nil }
        XCTAssertEqual(ticks.value, readsBeforeTheGoodScan + 1, "exactly one completion wrote a time")
        XCTAssertEqual(fixture.state.lastCheckedAt, Self.checkedAt.addingTimeInterval(Double(readsBeforeTheGoodScan + 1)))
        XCTAssertNil(fixture.defaults.object(forKey: "quickAccessFolderProblem"))
    }

    /// The bookmark is resolved in the refresh's own task, off the main actor, so a slow provider folder can't hold the screen.
    func testTheRefreshResolvesTheBookmarkOffTheMainThread() async throws {
        let seen = Counter()
        let onMain = Counter()
        let folder = try makeFolder()
        let fixture = try makeFixture(resolveBookmark: { _ in
            _ = seen.next()
            if Thread.isMainThread { _ = onMain.next() }
            return (folder, false)
        })
        fixture.state.refresh()
        XCTAssertEqual(seen.value, 0, "nothing resolves before the task runs")
        try await waitFor("scan starts") { fixture.bench.scansStarted == 1 }
        XCTAssertEqual(seen.value, 1)
        XCTAssertEqual(onMain.value, 0, "the resolve ran off the main thread")
        fixture.bench.finishScan(0, with: Self.scan([]))
        try await waitFor("scan stored") { fixture.state.lastCheckedAt != nil }
        XCTAssertEqual(fixture.state.folderPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }, folder.resolvingSymlinksInPath().path)
    }

    /// An upgrade from a build that had the queue switch (#4274): the four retired keys are deleted at launch, so an older build
    /// installed over this one reads the switch as off with no stale baseline. The folder and the dismissed files read as
    /// before, and the newer values are unknown, not invented.
    func testAnUpgradeRetiresTheQueueKeysAndKeepsTheFolder() throws {
        let defaults = try makeDefaults()
        let folder = try makeFolder(named: "Clippings")
        try save(folder, in: defaults)
        defaults.set(["quick-access:a.md"], forKey: "dismissedQuickAccessFilesV1")
        defaults.set(true, forKey: "quickFolderFeedsQueueV1")
        defaults.set(["a.md"], forKey: "quickFolderInboxSeenFilesV1")
        defaults.set(true, forKey: "quickFolderInboxSeenWholeFolderV1")
        defaults.set(Data(#"{"fileName":"a.pdf","reason":"x","date":0}"#.utf8), forKey: "quickAccessLastImportProblem")

        let state = QuickAccessFolderState(defaults: defaults)

        for key in ["quickFolderFeedsQueueV1", "quickFolderInboxSeenFilesV1", "quickFolderInboxSeenWholeFolderV1", "quickAccessLastImportProblem"] {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
        XCTAssertEqual(state.folderName, "Clippings")
        XCTAssertEqual(state.dismissedFileKeys, ["quick-access:a.md"])
        XCTAssertNotNil(defaults.data(forKey: "quickAccessFolderBookmark"), "the folder is kept")
        XCTAssertNil(state.folderPath)
        XCTAssertNil(state.lastCheckedAt)
        XCTAssertNil(state.problem)
    }

    // MARK: Choose again and remove (#3770)

    /// The same folder keeps what the last scan learned; a different folder, or an unknown stored path, drops it.
    func testChoosingTheSameFolderAgainKeepsWhatTheScanLearnedAndAnyOtherFolderStartsOver() async throws {
        let fixture = try makeFixture(now: { Self.checkedAt })
        fixture.state.refresh()
        try await waitFor("scan starts") { fixture.bench.scansStarted == 1 }
        fixture.bench.finishScan(0, with: Self.scan(["a"]))
        try await waitFor("scan stored") { fixture.state.lastCheckedAt != nil }
        fixture.state.dismiss(Self.file("gone.md"))

        // Same folder, written as a URL with a trailing slash.
        let decision = try fixture.state.reconnect(url: URL(fileURLWithPath: fixture.folder.path, isDirectory: true)) {}
        XCTAssertEqual(decision, .keepSeenFiles)
        XCTAssertEqual(fixture.state.lastCheckedAt, Self.checkedAt)
        XCTAssertNotNil(fixture.state.folderPath)
        XCTAssertEqual(fixture.state.dismissedFileKeys, [Self.file("gone.md").dismissalKey])

        // A different folder with the same name.
        let other = try makeFolder(named: fixture.folder.lastPathComponent)
        XCTAssertNotEqual(other.path, fixture.folder.path)
        let otherDecision = try fixture.state.reconnect(url: other) {}
        XCTAssertEqual(otherDecision, .freshBaseline)
        XCTAssertNil(fixture.state.folderPath)
        XCTAssertNil(fixture.state.lastCheckedAt)
        XCTAssertNil(fixture.state.problem)
        XCTAssertEqual(fixture.state.dismissedFileKeys, [Self.file("gone.md").dismissalKey], "dismissed files stay dismissed")
    }

    func testChoosingAgainWithNoStoredPathStartsOver() throws {
        let defaults = try makeDefaults()
        let folder = try makeFolder()
        try save(folder, in: defaults)
        let state = QuickAccessFolderState(defaults: defaults, dependencies: ScanBench().dependencies())

        let decision = try state.reconnect(url: folder) {}

        XCTAssertEqual(decision, .freshBaseline, "an upgrade stored no path, so the folder can't be known to be the same")
    }

    /// Removing forgets the folder and what was learned about it, keeps what was dismissed, and ends a scan in flight. Nothing
    /// already imported is this state's to touch.
    func testRemovingTheFolderForgetsItKeepsTheDismissedFilesAndEndsTheScan() async throws {
        let fixture = try makeFixture(now: { Self.checkedAt })
        fixture.state.refresh()
        try await waitFor("scan starts") { fixture.bench.scansStarted == 1 }
        fixture.bench.finishScan(0, with: Self.scan(["a"]))
        try await waitFor("scan stored") { fixture.state.lastCheckedAt != nil }
        fixture.state.dismiss(Self.file("gone.md"))
        fixture.state.refresh()
        try await waitFor("the second scan starts") { fixture.bench.scansStarted == 2 }

        fixture.state.remove()

        XCTAssertEqual(fixture.state.folderName, "No folder selected")
        XCTAssertNil(fixture.state.folderPath)
        XCTAssertNil(fixture.state.lastCheckedAt)
        XCTAssertNil(fixture.state.problem)
        XCTAssertEqual(fixture.state.recentFiles, [])
        XCTAssertFalse(fixture.state.isRefreshing)
        XCTAssertEqual(fixture.state.dismissedFileKeys, [Self.file("gone.md").dismissalKey])
        for key in [
            "quickAccessFolderBookmark", "quickAccessFolderName", "quickAccessFolderPath", "quickAccessLastCheckedAt",
            "quickAccessFolderProblem", "quickAccessFolderChosenAt",
        ] {
            XCTAssertNil(fixture.defaults.object(forKey: key), key)
        }
        XCTAssertEqual(fixture.defaults.stringArray(forKey: "dismissedQuickAccessFilesV1"), [Self.file("gone.md").dismissalKey])

        // The scan that was in flight finishes into a state with no folder and changes nothing.
        fixture.bench.finishScan(1, with: Self.scan(["late"]))
        try await waitFor("late scan's access stops") { fixture.bench.count("stop") == 2 }
        XCTAssertEqual(fixture.state.recentFiles, [])
        XCTAssertNil(fixture.state.lastCheckedAt)
        XCTAssertEqual(fixture.state.folderName, "No folder selected")
    }

    // MARK: Dismissed files

    func testDismissAndRestorePersistAndSurviveAReopen() throws {
        let defaults = try makeDefaults()
        let state = QuickAccessFolderState(defaults: defaults)
        let first = Self.file("a.md")
        let second = Self.file("b.md")

        state.dismiss(second)
        state.dismiss(first)
        XCTAssertEqual(
            defaults.stringArray(forKey: "dismissedQuickAccessFilesV1"),
            [first.dismissalKey, second.dismissalKey].sorted(),
            "stored sorted, under the key earlier builds wrote"
        )
        XCTAssertEqual(QuickAccessFolderState(defaults: defaults).dismissedFileKeys, [first.dismissalKey, second.dismissalKey])

        state.restore(first)
        XCTAssertEqual(QuickAccessFolderState(defaults: defaults).dismissedFileKeys, [second.dismissalKey])
    }

    // MARK: Candidate cache

    /// The cache is cleared by five inputs: the Library, followed entries, subscriptions (all on the model)
    /// and this state's own Following pool (#4274) and dismissed keys. A cache that misses any one shows a stale list here.
    func testQuickAddCandidatesFollowEveryInput() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        let file = Self.file("notes.md")
        let entry = FeedEntry(id: "episode", subscriptionId: "show", canonicalURL: "https://example.com/e/1", title: "Episode", publishedAt: Date(timeIntervalSince1970: 50))
        let subscription = FeedSubscription(
            id: "show",
            source: SourceIdentity(id: "source-show", kind: .podcastFeed, canonicalURL: "https://example.com/feed.xml", host: "example.com", title: "The Show"),
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let sameURL = LibraryItemRow(id: "imported", title: "Unrelated", status: "Ready", canDelete: true, mediaType: "text", sourceReference: "https://Example.com/e/1/#top")
        let sameShowAndTitle = LibraryItemRow(id: "heard", title: "Episode", status: "Ready", canDelete: true, mediaType: "text", sourceTitle: "The Show")
        func ids() -> [String] { model.quickAddCandidates.map(\.id) }
        model.quickAccess.dismissedFileKeys = []
        model.quickAccess.followingPool = []
        model.followedSourceEntries = []
        model.feedSubscriptions = []
        model.libraryItems = []
        XCTAssertEqual(ids(), [])

        model.quickAccess.followingPool = [file]
        XCTAssertEqual(ids(), ["local-file:notes.md"], "files")
        model.followedSourceEntries = [entry]
        XCTAssertEqual(ids(), ["local-file:notes.md", "followed-source:episode"], "followed entries")
        model.libraryItems = [sameURL]
        XCTAssertEqual(ids(), ["local-file:notes.md"], "the Library, by source URL")
        model.libraryItems = [sameShowAndTitle]
        XCTAssertEqual(ids(), ["local-file:notes.md", "followed-source:episode"], "the Library, show not yet known")
        model.feedSubscriptions = [subscription]
        XCTAssertEqual(ids(), ["local-file:notes.md"], "subscriptions name the show")
        model.dismissQuickAccessFile(file)
        XCTAssertEqual(ids(), [], "dismissed keys")
        model.restoreQuickAccessFile(file)
        XCTAssertEqual(ids(), ["local-file:notes.md"], "restored")
    }

    // MARK: Notifications

    func testTheStateAnnouncesEveryPublishedChangeToItsTarget() throws {
        let state = QuickAccessFolderState(defaults: try makeDefaults())
        let target = ObservableObjectPublisher()
        var notifications = 0
        let observer = target.sink { notifications += 1 }
        state.forwardWillChange(to: target)

        state.folderName = "Vault"
        XCTAssertEqual(notifications, 1)
        state.recentFiles = [Self.file("a")]
        XCTAssertEqual(notifications, 2)
        state.dismiss(Self.file("a"))
        XCTAssertEqual(notifications, 3)
        state.recordDiagnostic("key", "value")
        state.invalidateCandidates()
        XCTAssertEqual(notifications, 3, "diagnostics and the cache are not published")
        withExtendedLifetime(observer) {}
    }

    func testTheModelForwardsAndRecordsDiagnosticsWithoutNotifying() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        var notifications = 0
        let observer = model.objectWillChange.sink { notifications += 1 }

        model.quickAccess.recentFiles = [Self.file("a")]
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(model.quickAccessRecentFiles.map(\.id), ["a"])
        model.quickAccess.folderName = "Vault"
        XCTAssertEqual(notifications, 2)
        XCTAssertEqual(model.quickAccessFolderName, "Vault")

        model.quickAccess.recordDiagnostic("quickAccessProbe", "1")
        XCTAssertEqual(model.diagnostics["quickAccessProbe"], "1")
        XCTAssertEqual(notifications, 2, "a diagnostics write does not invalidate the model")
        withExtendedLifetime(observer) {}
    }

    func testAHostedViewRendersTheNewNameAndFilesAfterTheStateChanges() async throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        let log = RenderLog()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(rootView: QuickFolderProbe(model: model, log: log))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }
        try await waitFor("first render") { !log.lines.isEmpty }

        model.quickAccess.folderName = "Vault"
        model.quickAccess.recentFiles = [Self.file("Notes")]
        try await waitFor("the view re-reads the new state") { log.lines.last == "Vault|Notes" }
    }

    // MARK: Helpers

    /// 2026-09-21 14:13:20 UTC: when the fixture's folder counts as chosen.
    nonisolated private static let chosenAt = Date(timeIntervalSince1970: 1_790_000_000)
    private static let twelveIDs = (0..<12).map { String(format: "f%02d.md", $0) }

    /// `f00.md` the newest at `newest`, each next one a minute older.
    private static func twelveFiles(newestAt newest: Date) -> [QuickAccessFileCandidate] {
        twelveIDs.enumerated().map { index, id in
            QuickAccessFileCandidate(id: id, name: id, relativePath: id, modifiedAt: newest.addingTimeInterval(-Double(index) * 60))
        }
    }

    /// A scan as the scanner gives it: the newest eight as `files`, every file as `allFiles`.
    private static func scan(dated all: [QuickAccessFileCandidate]) -> QuickAccessFolderScan {
        QuickAccessFolderScan(files: Array(all.prefix(QuickAccessFolderScanner.quickAddLimit)), errorDescription: nil, allFiles: all)
    }

    private static func localFiles(_ state: QuickAccessFolderState) -> [QuickAccessFile] {
        state.candidates(followedEntries: [], subscriptions: [], libraryItems: []).compactMap { candidate -> QuickAccessFile? in
            if case .localFile(let file) = candidate { return file }
            return nil
        }
    }

    private static func localFileIDs(_ state: QuickAccessFolderState) -> [String] { localFiles(state).map(\.id) }

    private static func scan(_ ids: [String]) -> QuickAccessFolderScan {
        QuickAccessFolderScan(
            files: ids.map { QuickAccessFileCandidate(id: $0, name: $0, relativePath: $0, modifiedAt: Date(timeIntervalSince1970: 100)) },
            errorDescription: nil
        )
    }

    private static func file(_ id: String) -> QuickAccessFile {
        QuickAccessFile(id: id, name: id, relativePath: id, modifiedAt: Date(timeIntervalSince1970: 100), modifiedAtDescription: "now")
    }

    private struct Fixture {
        let state: QuickAccessFolderState
        let defaults: UserDefaults
        let folder: URL
        let bench: ScanBench
        let log: DiagnosticLog
    }

    private func makeFixture(now: (@Sendable () -> Date)? = nil, resolveBookmark: (@Sendable (Data) throws -> (url: URL, isStale: Bool))? = nil) throws -> Fixture {
        let defaults = try makeDefaults()
        let folder = try makeFolder()
        try save(folder, in: defaults)
        let bench = ScanBench()
        var dependencies = bench.dependencies()
        if let now { dependencies.now = now }
        if let resolveBookmark { dependencies.resolveBookmark = resolveBookmark }
        let state = QuickAccessFolderState(defaults: defaults, dependencies: dependencies)
        let log = DiagnosticLog()
        state.recordDiagnostic = { log.append($0, $1) }
        return Fixture(state: state, defaults: defaults, folder: folder, bench: bench, log: log)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "quick-access-state-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func makeFolder(named name: String = "Folder") throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickAccessFolderStateTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        return folder
    }

    private func save(_ folder: URL, in defaults: UserDefaults) throws {
        defaults.set(
            try folder.bookmarkData(options: QuickAccessFolderState.platformCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil),
            forKey: "quickAccessFolderBookmark"
        )
        defaults.set(folder.lastPathComponent, forKey: "quickAccessFolderName")
    }

    private func waitFor(_ description: String, _ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let pollDeadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < pollDeadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for: \(description)", file: file, line: line)
    }
}

/// Holds each folder scan open until the test resumes it, records the scoped-access calls in order, and
/// counts cancellations. The scan ignores cancellation, as the real detached scan does.
private final class ScanBench: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<QuickAccessFolderScan, Never>] = []
    private var recorded: [String] = []
    private var cancelled = 0

    var scansStarted: Int { lock.withLock { continuations.count } }
    var cancelledScans: Int { lock.withLock { cancelled } }
    var events: [String] { lock.withLock { recorded } }
    func count(_ event: String) -> Int { lock.withLock { recorded.filter { $0 == event }.count } }
    func record(_ event: String) { lock.withLock { recorded.append(event) } }

    func finishScan(_ index: Int, with scan: QuickAccessFolderScan) {
        let continuation = lock.withLock { continuations[index] }
        continuation.resume(returning: scan)
    }

    func dependencies() -> QuickAccessFolderState.Dependencies {
        QuickAccessFolderState.Dependencies(
            scan: { [self] _ in await heldScan() },
            startAccess: { [self] _ in record("start"); return true },
            stopAccess: { [self] _ in record("stop") }
        )
    }

    private func heldScan() async -> QuickAccessFolderScan {
        record("scan")
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<QuickAccessFolderScan, Never>) in
                lock.withLock { continuations.append(continuation) }
            }
        } onCancel: {
            lock.withLock { cancelled += 1 }
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    @discardableResult func next() -> Int { lock.withLock { count += 1; return count } }
}

@MainActor
private final class DiagnosticLog {
    private(set) var entries: [(key: String, value: String)] = []
    func append(_ key: String, _ value: String) { entries.append((key, value)) }
    func value(for key: String) -> String? { entries.last { $0.key == key }?.value }
}

@MainActor
private final class RenderLog {
    var lines: [String] = []
}

private struct QuickFolderProbe: View {
    @ObservedObject var model: Gate1AppModel
    let log: RenderLog

    var body: some View {
        let _ = log.lines.append("\(model.quickAccessFolderName)|\(model.quickAccessRecentFiles.map(\.name).joined(separator: ","))")
        Text(model.quickAccessFolderName)
    }
}

/// A clock a test moves by hand, read from the state's `@Sendable` `now`.
private final class SettableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ start: Date) { value = start }
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
