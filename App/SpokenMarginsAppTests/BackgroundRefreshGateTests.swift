import XCTest
import SessionKit
import SessionKitAudio
@testable import SpokenMarginsApp

/// #2102: a reload read off the main thread may publish only while nothing newer has happened. The first version of
/// the Library and item refreshes had no such check in a test, so a slow read could overwrite a newer screen.
@MainActor
final class BackgroundRefreshGateTests: XCTestCase {
    private var priorTermsVersion: Any?
    private var priorTermsDate: Any?

    override func setUpWithError() throws {
        try super.setUpWithError()
        // The lane wipes the app's data, and this class runs first, so no earlier test had accepted the terms. The
        // first playback then waited for the terms decision and started no session.
        priorTermsVersion = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceVersionKey)
        priorTermsDate = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceDateKey)
        SpokenMarginsTerms.recordAcceptance()
    }

    override func tearDownWithError() throws {
        for (value, key) in [(priorTermsVersion, SpokenMarginsTerms.acceptanceVersionKey), (priorTermsDate, SpokenMarginsTerms.acceptanceDateKey)] {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        try super.tearDownWithError()
    }

    func testANewerReloadOvertakesTheOneInFlight() {
        let gate = BackgroundRefreshGate()
        let first = gate.beginItem()
        XCTAssertTrue(gate.isCurrentItem(first))
        let second = gate.beginItem()
        XCTAssertFalse(gate.isCurrentItem(first), "the older read must not publish after a newer one began")
        XCTAssertTrue(gate.isCurrentItem(second))
    }

    func testAnotherAssignmentToTheSelectedItemOvertakesTheReload() {
        let gate = BackgroundRefreshGate()
        let reload = gate.beginItem()
        gate.selectionWasAssigned()
        XCTAssertFalse(gate.isCurrentItem(reload), "opening another item while a read is in flight drops that read")
    }

    func testPublishingTheReloadItselfDoesNotInvalidateIt() {
        let gate = BackgroundRefreshGate()
        let reload = gate.beginItem()
        gate.publishItem {
            gate.selectionWasAssigned() // the didSet fires for our own assignment
        }
        XCTAssertTrue(gate.isCurrentItem(reload))
    }

    func testTheLibraryAndItemGenerationsAreIndependent() {
        let gate = BackgroundRefreshGate()
        let item = gate.beginItem()
        let library = gate.beginLibrary()
        _ = gate.beginLibrary()
        XCTAssertFalse(gate.isCurrentLibrary(library))
        XCTAssertTrue(gate.isCurrentItem(item), "a newer Library read leaves the item reload alone")
    }

    func testAnItemOpenedWhileAPauseReloadsIsNotOverwrittenByTheOlderRead() async throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.importTitle = "First Item"
        model.importText = "One sentence only."
        model.importTextItem()
        let firstId = model.selectedItem.id
        model.pause() // reloads "First Item" off the main thread

        model.importTitle = "Second Item"
        model.importText = "Another sentence only."
        model.importTextItem()
        let secondId = model.selectedItem.id
        XCTAssertNotEqual(firstId, secondId)

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(model.selectedItem.id, secondId, "the older read finished after the newer item opened and must be dropped")
        XCTAssertEqual(model.activePlaybackItemId, secondId)
    }

    /// A read that the test holds open: call N waits for `release(N)` and announces itself on `started`.
    private final class HeldReads: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        let started = AsyncStream<Void>.makeStream()
        let releases = (0..<4).map { _ in AsyncStream<Void>.makeStream() }
        var count: Int { lock.withLock { calls } }
        func next() -> Int { lock.withLock { calls += 1; return calls } }
        func release(_ call: Int) { releases[call - 1].continuation.yield(()) }
    }

    private func holdReads(_ held: HeldReads, on model: Gate1AppModel) {
        model.navigationLibraryRead = { store in
            let call = held.next()
            let data = try LibraryReadSnapshot.read(store: store)
            held.started.continuation.yield(())
            for await _ in held.releases[call - 1].stream { break }
            return data
        }
    }

    func testATapReloadOvertakenBySynchronousRowsReadsAgainInsteadOfRestoringOldRows() async throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        let held = HeldReads()
        holdReads(held, on: model)
        var started = held.started.stream.makeAsyncIterator()

        model.refreshLibraryRowsInBackground(mustPublish: true)
        await started.next()
        // A synchronous reload (permanent delete, Play) lands while the first read is out; that read is now older.
        model.libraryItems = [LibraryItemRow(id: "newer-item", title: "Newer state", status: "Ready", canDelete: true)]
        held.release(1)
        await started.next()
        held.release(2)
        await model.settleLibraryReload()

        XCTAssertEqual(held.count, 2, "the older read must not publish over the newer rows; the reload reads again")
        XCTAssertNotEqual(model.libraryItems.map(\.id), ["newer-item"], "the second read, which saw no change, publishes the stored Library")
    }

    func testATapReloadThatKeepsBeingOvertakenPublishesOnItsThirdRead() async throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        let held = HeldReads()
        holdReads(held, on: model)
        var started = held.started.stream.makeAsyncIterator()

        model.refreshLibraryRowsInBackground(mustPublish: true)
        for call in 1...3 {
            await started.next()
            model.libraryItems = [LibraryItemRow(id: "churn-\(call)", title: "Churn", status: "Ready", canDelete: true)]
            held.release(call)
        }
        await model.settleLibraryReload()

        XCTAssertEqual(held.count, 3, "three reads, then the tap's rows are published whatever moved")
        XCTAssertFalse(model.libraryItems.map(\.id).contains { $0.hasPrefix("churn-") }, "the tapped change must show under churn")
    }

    func testASkipThatFinishesTheItemShowsTheFinishedSessionAtOnce() throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.importTitle = "Short Item"
        model.importText = "One sentence only."
        model.importTextItem()
        model.skipUnit = "section"
        model.skipForward()

        XCTAssertEqual(model.snapshot.sourceProgressPercent, 100)
        let shown = try XCTUnwrap(model.selectedItem.sessions.last)
        XCTAssertEqual(shown.completionPercent, 100, "Resume and Play read the finished session off the item at once, not after a background read")
    }
}
