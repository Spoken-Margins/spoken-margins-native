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

    // MARK: Inbox feeds the queue (#1990 slice 3)

    /// The setting is off by default, persists, and a completed refresh reports to the model so the inbox can run.
    func testInboxSettingIsOffByDefaultPersistsAndRefreshReportsToTheModel() async throws {
        let fixture = try makeFixture()
        XCTAssertFalse(fixture.state.inboxFeedsQueue)
        var refreshed = 0
        fixture.state.onFilesRefreshed = { refreshed += 1 }
        fixture.state.inboxFeedsQueue = true
        try await waitFor("toggle starts a scan") { fixture.bench.scansStarted == 1 }
        fixture.bench.finishScan(0, with: Self.scan(["a"]))
        try await waitFor("refresh reports") { refreshed == 1 }
        XCTAssertNil(fixture.state.inboxSeenFileIds, "turning it on starts with no baseline")
        fixture.state.inboxSeenFileIds = ["a"]
        XCTAssertTrue(QuickAccessFolderState(defaults: fixture.defaults, dependencies: fixture.bench.dependencies()).inboxFeedsQueue)
        XCTAssertEqual(QuickAccessFolderState(defaults: fixture.defaults, dependencies: fixture.bench.dependencies()).inboxSeenFileIds, ["a"])
        fixture.state.inboxFeedsQueue = false
        XCTAssertNil(fixture.state.inboxSeenFileIds)
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
        fixture.state.refresh()
        try await waitFor("scan starts") { fixture.bench.scansStarted == 1 }
        XCTAssertTrue(fixture.state.isRefreshing)

        fixture.defaults.removeObject(forKey: "quickAccessFolderBookmark")
        fixture.state.refresh()
        XCTAssertFalse(fixture.state.isRefreshing, "no folder, no spinner")
        XCTAssertEqual(fixture.state.recentFiles, [])
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
        fixture.state.refresh()
        try await waitFor("scan starts") { fixture.bench.scansStarted == 1 }
        fixture.bench.finishScan(0, with: QuickAccessFolderScan(files: [], errorDescription: "unreadable"))
        try await waitFor("scan's access stops") { fixture.bench.count("stop") == 1 }
        XCTAssertEqual(fixture.state.recentFiles, [])
        XCTAssertEqual(fixture.state.folderName, "Vault")
        XCTAssertFalse(fixture.state.isRefreshing)
        XCTAssertEqual(fixture.log.value(for: "quickAccessError"), "unreadable")
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

        XCTAssertEqual(bench.events, ["start", "start", "saved", "stop"], "configure's access spans the refresh start and the report")
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

    func testABookmarkThatNoLongerResolvesIsReportedAndYieldsNoFolder() throws {
        let defaults = try makeDefaults()
        defaults.set(Data([1, 2, 3]), forKey: "quickAccessFolderBookmark")
        let state = QuickAccessFolderState(defaults: defaults)
        let log = DiagnosticLog()
        state.recordDiagnostic = { log.append($0, $1) }

        XCTAssertNil(state.resolvedFolderURL())
        XCTAssertNotNil(log.value(for: "quickAccessBookmarkError"))

        state.refresh()
        XCTAssertFalse(state.isRefreshing)
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
    /// and this state's own files and dismissed keys. A cache that misses any one shows a stale list here.
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
        model.quickAccess.recentFiles = []
        model.followedSourceEntries = []
        model.feedSubscriptions = []
        model.libraryItems = []
        XCTAssertEqual(ids(), [])

        model.quickAccess.recentFiles = [file]
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

    private func makeFixture() throws -> Fixture {
        let defaults = try makeDefaults()
        let folder = try makeFolder()
        try save(folder, in: defaults)
        let bench = ScanBench()
        let state = QuickAccessFolderState(defaults: defaults, dependencies: bench.dependencies())
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
        for _ in 0..<200 {
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
