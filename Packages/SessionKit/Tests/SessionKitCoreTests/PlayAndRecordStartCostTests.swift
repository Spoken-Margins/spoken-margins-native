import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// What a play start and a Margin's start cost, on a real SQLite file the size of a Library (#2256). The player and the
/// recorder are fakes, because `AVAudioSession` does not exist on macOS: these figures are the engine's own work, never
/// the audio session's.
final class PlayAndRecordStartCostTests: XCTestCase {
    private var fixtures: [LibraryFixture] = []

    override func tearDown() {
        fixtures.forEach { $0.remove() }
        fixtures = []
    }

    private static let profile = RuntimeCapabilityProfile(
        id: "phone", displayName: "Phone",
        capabilities: [
            "sync": ["canonical_persistence"], "playback": ["native_media", "prerendered_audio"],
            "interjection": ["record_audio"]
        ])

    private func milliseconds(_ body: () throws -> Void) rethrows -> Double {
        let elapsed = try ContinuousClock().measure(body)
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }

    private func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    private func longArticleText(characters: Int) -> String {
        let sentence = "The quick brown fox jumps over the lazy dog, and then it naps in the café until noon. "
        return String(repeating: sentence, count: characters / sentence.count + 1)
    }

    /// Prints the table for the PR. Set `SESSIONKIT_START_COST=1` to run it; a normal run skips the Library-size build.
    func testPrintTheStartCostsAtLibrarySize() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SESSIONKIT_START_COST"] == "1")
        let fixture = try LibraryFixture.build(.library)
        fixtures.append(fixture)
        let meter = StoreReadMeter()
        let store = try fixture.openStore(meter: meter)
        let longTextId = "item-long-text"
        try store.saveItem(Item(
            id: longTextId, title: "A long text", mediaType: "article", text: longArticleText(characters: 1_000_000),
            externalReference: nil, status: "ready", media: nil))

        for (name, itemId) in [("podcast", LibraryFixture.mappedItemId), ("article", fixture.articleItemId), ("long text", longTextId)] {
            var firstStart = 0.0
            var starts: [Double] = [], begins: [Double] = [], cancels: [Double] = [], pauses: [Double] = [], rates: [Double] = []
            var pausedOnTap = true
            var startReads = 0, beginReads = 0, startRows = 0, beginRows = 0
            for run in 0..<7 {
                let engine = SessionEngine(profile: Self.profile, repository: store)
                meter.reset()
                let start = try milliseconds { _ = try engine.startSession(itemId: itemId) }
                let startTotals = meter.totals().values
                let rate = try milliseconds { _ = try engine.setPlaybackRate(1) }
                let pause = milliseconds { _ = engine.pauseSourceForInterjection(request: MarginCaptureRequest()) }
                // A pause that returns at its first guard costs nothing and proves nothing (#4221): the figure only
                // counts when the playing source was paused by the tap.
                pausedOnTap = pausedOnTap && engine.isSourcePausedOnTap
                meter.reset()
                let begin = try milliseconds { _ = try engine.beginInterjection() }
                let beginTotals = meter.totals().values
                let cancel = try milliseconds { _ = try engine.cancelInterjection(resumesSource: false) }
                _ = try engine.endSession()
                guard run > 0 else { firstStart = start; continue } // the first start fills SQLite's cache
                starts.append(start); begins.append(begin); cancels.append(cancel); pauses.append(pause); rates.append(rate)
                startReads = startTotals.reduce(0) { $0 + $1.calls }; startRows = startTotals.reduce(0) { $0 + $1.rows }
                beginReads = beginTotals.reduce(0) { $0 + $1.calls }; beginRows = beginTotals.reduce(0) { $0 + $1.rows }
            }
            XCTAssertTrue(pausedOnTap, "\(name): the source was not playing when the tap paused it, so the pause figure measures nothing")
            print("START-COST \(name): first start \(firstStart) ms, repeat start \(median(starts)) ms (\(startReads) reads, \(startRows) rows), setPlaybackRate \(median(rates)) ms, pauseSource of a playing source (paused on the tap: \(pausedOnTap)) \(median(pauses)) ms, beginInterjection \(median(begins)) ms (\(beginReads) reads, \(beginRows) rows), cancel \(median(cancels)) ms")
        }

        var detail: [Double] = []
        for _ in 0..<7 {
            detail.append(try milliseconds {
                _ = try ItemDetailLoader.load(
                    id: LibraryFixture.mappedItemId, store: store, snapshotItemId: nil, snapshotSessionId: nil,
                    placementPasses: SharedMarginPlacementPasses())
            })
        }
        print("START-COST item detail (podcast): \(median(detail)) ms")

        let text = longArticleText(characters: 1_000_000)
        var counts: [Double] = [], trims: [Double] = []
        for _ in 0..<7 {
            counts.append(milliseconds { _ = text.count })
            trims.append(milliseconds { _ = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        }
        print("START-COST 1 MB text: count \(median(counts)) ms, trim \(median(trims)) ms")
    }

    /// A long main-thread wait behind a background write must name itself, or the hang reads as the work after it.
    func testAMainThreadWaitBehindABackgroundWriteIsLabelled() throws {
        let fixture = try LibraryFixture.build(.small)
        fixtures.append(fixture)
        let store = try fixture.openStore(meter: StoreReadMeter())
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let writerDone = expectation(description: "the background write ended")
        DispatchQueue.global().async {
            store.withConnectionLock {
                held.signal()
                release.wait()
            }
            writerDone.fulfill()
        }
        XCTAssertEqual(held.wait(timeout: .now() + 5), .success)

        let saw = LockedFlag()
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if MainThreadOperationLabels.shared.current.contains("store.writeWait") { saw.set(); break }
                usleep(2_000)
            }
            release.signal() // only now can the main thread's wait end
        }
        store.withConnectionLock {}
        wait(for: [writerDone], timeout: 5)
        XCTAssertTrue(saw.value)
        XCTAssertFalse(MainThreadOperationLabels.shared.current.contains("store.writeWait"), "the label ends with the wait")
    }

    func testTheLockStaysRecursiveWithTheWaitLabelInPlace() throws {
        let fixture = try LibraryFixture.build(.small)
        fixtures.append(fixture)
        let store = try fixture.openStore(meter: StoreReadMeter())
        let answer = store.withConnectionLock { store.withConnectionLock { 7 } }
        XCTAssertEqual(answer, 7)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false
    func set() { lock.withLock { isSet = true } }
    var value: Bool { lock.withLock { isSet } }
}
