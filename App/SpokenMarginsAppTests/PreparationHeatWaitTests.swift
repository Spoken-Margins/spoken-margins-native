import Foundation
import SessionKit
import SessionKitPersistence
import XCTest
@testable import SpokenMarginsApp

/// #905: a Make available offline run stopped for heat carries on by itself once the phone cools.
/// The owner's 2026-10-08 export showed a run stopped for heat while the phone read nominal,
/// because the loop ended on the pause and nothing started it again.
final class PreparationHeatWaitTests: XCTestCase {
    @MainActor
    private func makeModel(queuingAnExplicitJob queuesJob: Bool = true) throws -> Gate1AppModel {
        let root = FileManager.default.temporaryDirectory.appending(path: "heat-wait-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(),
                                  databaseURLOverride: root.appending(path: "store.sqlite"))
        let store = try model.libraryStoreForTesting()
        addTeardownBlock { [weak model, weak store] in
            // Startup tasks can retain the connection after the test finishes.
            if model == nil, store == nil { try? FileManager.default.removeItem(at: root) }
        }
        if queuesJob {
            try store.saveAudioPreparationJob(
                AudioPreparationJob(id: "job-heat-wait", itemId: "item-heat-wait", manifestId: "manifest-heat-wait", policy: .explicit)
            )
        }
        return model
    }

    @MainActor
    func testAHotPhoneIsWaitedOutAndTheRunResumesWhenItCools() async throws {
        let model = try makeModel()
        let heat = HeatSequence(hotReads: 3)
        let waits = WaitLog()
        model.preparationSeams = PreparationPassSeams(
            deviceConditions: { SpeechEngineConditions(thermal: heat.read()) },
            pause: { seconds in await waits.add(seconds) }
        )

        let resumed = await model.waitOutPreparationHeat()

        XCTAssertTrue(resumed, "the run goes on once the phone reads cool")
        let seconds = await waits.seconds
        XCTAssertEqual(seconds, [15, 15, 15], "a hot phone is rechecked every 15 seconds at first")
        XCTAssertFalse(model.isWaitingOutPreparationHeat)
        XCTAssertEqual(model.diagnostics["preparationHeatWait"], "resumed_after_45s")
    }

    @MainActor
    func testNothingQueuedMeansNoWait() async throws {
        let model = try makeModel(queuingAnExplicitJob: false)
        let waits = WaitLog()
        model.preparationSeams = PreparationPassSeams(
            deviceConditions: { SpeechEngineConditions(thermal: .serious) },
            pause: { seconds in await waits.add(seconds) }
        )

        let resumed = await model.waitOutPreparationHeat()

        XCTAssertFalse(resumed)
        let seconds = await waits.seconds
        XCTAssertEqual(seconds, [], "a finished queue has nothing to wait for")
    }

    @MainActor
    func testAPassThatStoppedWithoutHeatIsNotWaitedOn() async throws {
        let model = try makeModel()
        let waits = WaitLog()
        model.preparationSeams = PreparationPassSeams(
            deviceConditions: { SpeechEngineConditions(thermal: .nominal) },
            pause: { seconds in await waits.add(seconds) }
        )

        let resumed = await model.waitOutPreparationHeat()

        XCTAssertFalse(resumed, "another reason stopped the pass: running it again would spin")
        let seconds = await waits.seconds
        XCTAssertEqual(seconds, [])
    }

    @MainActor
    func testAPhoneThatStaysHotEndsTheWaitAfterHalfAnHour() async throws {
        let model = try makeModel()
        let waits = WaitLog()
        model.preparationSeams = PreparationPassSeams(
            deviceConditions: { SpeechEngineConditions(thermal: .critical) },
            pause: { seconds in await waits.add(seconds) }
        )

        let resumed = await model.waitOutPreparationHeat()

        XCTAssertFalse(resumed)
        let total = await waits.seconds.reduce(0, +)
        XCTAssertGreaterThanOrEqual(total, OfflinePreparationRun.maximumHeatWaitSeconds)
        XCTAssertLessThan(total, OfflinePreparationRun.maximumHeatWaitSeconds + 60)
        XCTAssertEqual(model.diagnostics["preparationHeatWait"], "stopped_waited_too_long_after_\(total)s")
        XCTAssertFalse(model.isWaitingOutPreparationHeat)
    }

    @MainActor
    func testCancellingTheLoopEndsTheWaitAtOnce() async throws {
        let model = try makeModel()
        model.preparationSeams = PreparationPassSeams(
            deviceConditions: { SpeechEngineConditions(thermal: .serious) },
            pause: { _ in throw CancellationError() }
        )

        let resumed = await model.waitOutPreparationHeat()

        XCTAssertFalse(resumed)
        XCTAssertFalse(model.isWaitingOutPreparationHeat, "the cooling flag is cleared when the wait ends")
    }
}

/// Serious heat for the first reads, then nominal.
@MainActor private final class HeatSequence {
    private var hotReads: Int
    init(hotReads: Int) { self.hotReads = hotReads }

    func read() -> SpeechThermalLevel {
        guard hotReads > 0 else { return .nominal }
        hotReads -= 1
        return .serious
    }
}

/// The seconds each wait would have slept, so a test runs at once.
private actor WaitLog {
    private(set) var seconds: [Int] = []
    func add(_ value: Int) { seconds.append(value) }
}
