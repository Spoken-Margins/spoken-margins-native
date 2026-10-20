import XCTest
@testable import SessionKit
import SessionKitPersistence
@testable import SpokenMarginsApp

/// #954: the Skim bridge's order of effects, its availability guard and its destination notifications, against a
/// scripted host that records every call the controller makes. The player and the resolver's store are covered
/// by the app-hosted Skim tests in `LocalAudioListeningPackageTests`.
@MainActor
final class SkimBridgeControllerTests: XCTestCase {
    private func makeBridge(
        destinationSceneId: String? = "scene-1",
        wasSourcePlaying: Bool = true,
        origin: Int = 1_000,
        destination: Int = 5_000
    ) -> SkimBridgeState {
        SkimBridgeState(
            direction: .forward, itemId: "item", originMediaTimeMs: origin, summarySceneId: "scene-0",
            destinationSceneId: destinationSceneId, destinationMediaTimeMs: destination,
            summaryAssetId: "asset", wasSourcePlaying: wasSourcePlaying, status: .playing
        )
    }

    private func makeController(_ host: ScriptedSkimHost) -> SkimBridgeController {
        let controller = SkimBridgeController(host: host)
        host.controller = controller
        return controller
    }

    // MARK: availability

    /// The model's snapshot observer asks for availability again after each flag write. With the two flags written one
    /// at a time, the second pass would see a half-written pair and write again unless the controller's guard holds.
    func testWritingTheFlagsDoesNotRunAnotherAvailabilityPass() {
        let host = ScriptedSkimHost()
        host.bridge = makeBridge()
        let controller = makeController(host)
        controller.updateAvailability(refreshResources: false)
        XCTAssertEqual(host.flagWrites, ["forward=true", "backward=true"], "each flag is written once")
        XCTAssertTrue(host.available.forward)
        XCTAssertTrue(host.available.backward)
        XCTAssertEqual(host.reentrantPasses, 2, "the observer did run after each write; the guard turned both passes away")
        XCTAssertEqual(controller.forwardDestinationMs, 5_000)
        XCTAssertEqual(controller.backwardDestinationMs, 5_000)
    }

    /// A destination that moves without the booleans flipping must still reach observers and the Lock Screen (#115).
    func testADestinationOnlyChangeIsPublishedAndRefreshesTheCompactState() {
        let host = ScriptedSkimHost()
        host.bridge = makeBridge(destination: 5_000)
        let controller = makeController(host)
        controller.updateAvailability(refreshResources: false)
        let writes = host.flagWrites.count
        XCTAssertEqual(host.destinationsWillChange, 1)
        XCTAssertEqual(host.compactRefreshes, 0, "the first pass flipped the flags, so the observer refreshed, not this call")

        host.bridge = makeBridge(destination: 4_000)
        controller.updateAvailability(refreshResources: false)
        XCTAssertEqual(controller.forwardDestinationMs, 4_000)
        XCTAssertEqual(host.flagWrites.count, writes, "the flags did not change")
        XCTAssertEqual(host.destinationsWillChange, 2, "observers are told before the destination changes")
        XCTAssertEqual(host.compactRefreshes, 1)

        controller.updateAvailability(refreshResources: false)
        XCTAssertEqual(host.destinationsWillChange, 2, "an unchanged destination publishes nothing")
        XCTAssertEqual(host.compactRefreshes, 1)
    }

    // MARK: loaded resources

    /// #2184: every reload of the selected item dropped the loaded map, so the next snapshot tick re-read the projection,
    /// proposals, layers and the owned-asset table on the main thread. They load once per item and map change now.
    func testResourcesLoadOncePerItemAndMapChange() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "skim-resources-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = ScriptedSkimHost()
        host.store = try SQLiteSessionStore(path: directory.appending(path: "store.sqlite").path)
        host.source = SkimSource(itemId: "episode", durationMs: 60_000)
        let controller = makeController(host)
        var episode = ItemDetailState()
        episode.id = "episode"
        episode.listeningMapScenes = [MediaTimelineChapter(id: "scene-0", title: "Opening", startMs: 0, transcriptSegmentId: "s0")]
        let key = SkimResourceKey(episode)

        controller.updateAvailability(refreshResources: false)
        XCTAssertEqual(controller.resourceLoadCount, 1)

        var reloaded = episode
        reloaded.status = "in_progress"
        reloaded.text = "A saved position, a new Margin."
        for _ in 0..<5 {
            controller.itemDetailChanged(from: key, to: SkimResourceKey(reloaded))
            controller.updateAvailability(refreshResources: false)
        }
        XCTAssertEqual(controller.resourceLoadCount, 1, "a reload that leaves the map alone keeps what was loaded")

        var other = ItemDetailState()
        other.id = "another"
        controller.itemDetailChanged(from: key, to: SkimResourceKey(other))
        controller.updateAvailability(refreshResources: false)
        XCTAssertEqual(controller.resourceLoadCount, 1, "browsing another item keeps the playing item's map")

        controller.itemDetailChanged(from: SkimResourceKey(other), to: key)
        controller.updateAvailability(refreshResources: false)
        XCTAssertEqual(controller.resourceLoadCount, 2, "arriving at the playing item reads it once")

        var remapped = episode
        remapped.listeningMapScenes[0].startMs = 1_000
        controller.itemDetailChanged(from: key, to: SkimResourceKey(remapped))
        controller.updateAvailability(refreshResources: false)
        controller.updateAvailability(refreshResources: false)
        XCTAssertEqual(controller.resourceLoadCount, 3, "a map change reads it once")

        controller.updateAvailability()
        XCTAssertEqual(controller.resourceLoadCount, 4, "an explicit refresh still reads it")
    }

    // MARK: a second tap and an unavailable Skim

    func testASecondSkimTapCompletesTheBridgeAtItsDestinationInsteadOfResolvingAnother() {
        let host = ScriptedSkimHost()
        host.bridge = makeBridge()
        let controller = makeController(host)
        controller.perform(direction: .forward)
        XCTAssertEqual(host.log, ["state:completing", "state:nil", "seek:5000", "resume", "finished"])
        XCTAssertTrue(host.warnings.isEmpty)
    }

    func testSkimWithNothingToResolveWarnsAndChangesNothing() {
        let host = ScriptedSkimHost()
        let controller = makeController(host)
        controller.perform(direction: .backward)
        XCTAssertEqual(host.warnings, ["Skim is unavailable until a verified scene summary is ready."])
        XCTAssertEqual(host.log, [])
    }

    // MARK: completion order

    func testCompletingResumesASourceThatWasPlaying() {
        let host = ScriptedSkimHost()
        host.bridge = makeBridge(wasSourcePlaying: true)
        makeController(host).complete()
        XCTAssertEqual(host.log, ["state:completing", "state:nil", "seek:5000", "resume", "finished"])
    }

    func testCompletingLeavesASourcePausedThatWasPaused() {
        let host = ScriptedSkimHost()
        host.bridge = makeBridge(wasSourcePlaying: false)
        makeController(host).complete()
        XCTAssertEqual(host.log, ["state:completing", "state:nil", "seek:5000", "pause", "finished"])
    }

    func testCompletingTheFinalSceneSummaryPausesEvenAPlayingSource() {
        let host = ScriptedSkimHost()
        host.bridge = makeBridge(destinationSceneId: nil, wasSourcePlaying: true)
        makeController(host).complete()
        XCTAssertEqual(host.log, ["state:completing", "state:nil", "seek:5000", "pause", "confirmed:Finished the final scene summary.", "finished"])
    }

    /// Existing behavior, kept by the move: the record is cleared before the seek, so a failed seek has no origin to restore.
    func testAFailedSeekWhileCompletingReportsAndDoesNotRestoreTheOrigin() {
        let host = ScriptedSkimHost()
        host.bridge = makeBridge()
        host.failSeek = true
        makeController(host).complete()
        XCTAssertEqual(host.log, ["state:completing", "state:nil", "seek:5000", "failed:Completing Skim failed"])
        XCTAssertNil(host.bridge)
    }

    func testCompletingWithoutAnEngineLeavesTheBridgeAlone() {
        let host = ScriptedSkimHost()
        host.bridge = makeBridge()
        host.hasEngine = false
        makeController(host).complete()
        XCTAssertEqual(host.log, [])
        XCTAssertNotNil(host.bridge)
    }

    // MARK: cancellation order

    func testCancellingAndResumingGoesBackToTheOriginAndPlays() {
        let host = ScriptedSkimHost()
        host.bridge = makeBridge(wasSourcePlaying: true, origin: 1_000)
        makeController(host).cancel(restoringOrigin: true, resumeSource: true)
        XCTAssertEqual(host.log, ["state:nil", "seek:1000", "resume"])
    }

    func testCancellingWithoutResumingPausesAtTheOrigin() {
        let host = ScriptedSkimHost()
        host.bridge = makeBridge(wasSourcePlaying: true, origin: 1_000)
        makeController(host).cancel(restoringOrigin: true, resumeSource: false)
        XCTAssertEqual(host.log, ["state:nil", "seek:1000", "pause"])
    }

    func testCancellingWithoutRestoringTouchesNeitherTheSeekNorTheEngine() {
        let host = ScriptedSkimHost()
        host.bridge = makeBridge()
        makeController(host).cancel(restoringOrigin: false, resumeSource: true)
        XCTAssertEqual(host.log, ["state:nil"])
    }

    func testCancellingIgnoresAFailedSeekAndStillSettlesTheEngine() {
        let host = ScriptedSkimHost()
        host.bridge = makeBridge(wasSourcePlaying: false)
        host.failSeek = true
        makeController(host).cancel(restoringOrigin: true, resumeSource: true)
        XCTAssertEqual(host.log, ["state:nil", "seek:1000", "kept snapshot", "pause"], "a source that was paused stays paused, and the refused seek leaves the snapshot as it was")
        XCTAssertTrue(host.failures.isEmpty)
    }

    func testCancellingWithNoBridgeDoesNothing() {
        let host = ScriptedSkimHost()
        makeController(host).cancel(restoringOrigin: true, resumeSource: true)
        XCTAssertEqual(host.log, [])
    }

    func testRestoringBeforeTransportResumesOnlyASourceThatWasPlaying() {
        let playing = ScriptedSkimHost()
        playing.bridge = makeBridge(wasSourcePlaying: true)
        makeController(playing).restoreOriginBeforeCanonicalTransport()
        XCTAssertEqual(playing.log, ["state:nil", "seek:1000", "resume"])

        let paused = ScriptedSkimHost()
        paused.bridge = makeBridge(wasSourcePlaying: false)
        makeController(paused).restoreOriginBeforeCanonicalTransport()
        XCTAssertEqual(paused.log, ["state:nil", "seek:1000", "pause"])
    }
}

@MainActor
private final class ScriptedSkimHost: SkimBridgeHost {
    struct ScriptedFailure: Error {}

    weak var controller: SkimBridgeController?
    var log: [String] = []
    var warnings: [String] = []
    var failures: [String] = []
    var flagWrites: [String] = []
    var reentrantPasses = 0
    var destinationsWillChange = 0
    var compactRefreshes = 0
    var hasEngine = true
    var failSeek = false
    var available: (forward: Bool, backward: Bool) = (false, false)

    var bridge: SkimBridgeState?

    var skimBridgeState: SkimBridgeState? {
        get { bridge }
        set {
            bridge = newValue
            log.append("state:" + (newValue.map { $0.status.rawValue } ?? "nil"))
        }
    }

    /// Like the model's snapshot observer: after each flag write it asks the controller for another pass.
    var skimAvailability: (forward: Bool, backward: Bool) {
        get { available }
        set {
            available.forward = newValue.forward
            flagWrites.append("forward=\(newValue.forward)")
            reentrantPasses += 1
            if reentrantPasses < 20 { controller?.updateAvailability(refreshResources: false) } // a cap, so a missing guard fails the assertions instead of overflowing the stack
            available.backward = newValue.backward
            flagWrites.append("backward=\(newValue.backward)")
            reentrantPasses += 1
            if reentrantPasses < 20 { controller?.updateAvailability(refreshResources: false) }
        }
    }

    var skimSourceIsPlaying: Bool { true }
    var skimCurrentMediaTimeMs: Int? { 1_000 }
    var source: SkimSource?
    var store: SQLiteSessionStore?
    var skimSource: SkimSource? { source }
    var skimStore: SQLiteSessionStore? { store }
    var skimHasEngine: Bool { hasEngine }
    var skimMediaPlaybackRate: Double { 1 }

    func summaryBridgeAssetID(itemId: String, proposalId: String, sceneId: String, suppliedAssetId: String?) -> String { "" }
    func resolvedApplicationSupportAssetURL(for path: String) -> URL? { nil }

    func skimPauseEngine() throws { log.append("pause") }
    func skimResumeEngine() throws { log.append("resume") }
    func skimSeekOrStage(toMediaTimeMs mediaTimeMs: Int) throws {
        log.append("seek:\(mediaTimeMs)")
        if failSeek { throw ScriptedFailure() }
    }
    func skimBridgeDidFinish() { log.append("finished") }
    func skimEngineCallFailedWhileCancelling() { log.append("kept snapshot") }
    func skimDestinationsWillChange() { destinationsWillChange += 1 }
    func skimDestinationsChangedWithoutAvailabilityChange() { compactRefreshes += 1 }
    func skimWarn(_ message: String) { warnings.append(message) }
    func skimSucceeded(_ message: String) { log.append("succeeded:\(message)") }
    func skimConfirmed(_ message: String) { log.append("confirmed:\(message)") }
    func skimFailed(_ error: Error, context: String) {
        failures.append(context)
        log.append("failed:\(context)")
    }
}
