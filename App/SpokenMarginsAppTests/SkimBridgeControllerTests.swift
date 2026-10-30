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
    /// proposals, layers and the owned-asset table. They load once per item and map change now, off the main actor (#2943).
    func testResourcesLoadOncePerItemAndMapChange() async throws {
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
        await controller.settleResources()
        XCTAssertEqual(controller.resourceLoadCount, 1)

        var reloaded = episode
        reloaded.status = "in_progress"
        reloaded.text = "A saved position, a new Margin."
        for _ in 0..<5 {
            controller.itemDetailChanged(from: key, to: SkimResourceKey(reloaded))
            controller.updateAvailability(refreshResources: false)
        }
        await controller.settleResources()
        XCTAssertEqual(controller.resourceLoadCount, 1, "a reload that leaves the map alone keeps what was loaded")

        var other = ItemDetailState()
        other.id = "another"
        controller.itemDetailChanged(from: key, to: SkimResourceKey(other))
        controller.updateAvailability(refreshResources: false)
        await controller.settleResources()
        XCTAssertEqual(controller.resourceLoadCount, 1, "browsing another item keeps the playing item's map")

        controller.itemDetailChanged(from: SkimResourceKey(other), to: key)
        controller.updateAvailability(refreshResources: false)
        await controller.settleResources()
        XCTAssertEqual(controller.resourceLoadCount, 2, "arriving at the playing item reads it once")

        var remapped = episode
        remapped.listeningMapScenes[0].startMs = 1_000
        controller.itemDetailChanged(from: key, to: SkimResourceKey(remapped))
        controller.updateAvailability(refreshResources: false)
        controller.updateAvailability(refreshResources: false)
        await controller.settleResources()
        XCTAssertEqual(controller.resourceLoadCount, 3, "a map change reads it once")

        controller.updateAvailability()
        await controller.settleResources()
        XCTAssertEqual(controller.resourceLoadCount, 4, "an explicit refresh still reads it")
    }

    /// #2943: opening an item and the first play tick read the store on the main thread (hangs up to 2.5 s). Asking
    /// for Skim now answers "still loading" at once, and the answer arrives with the loaded map.
    func testAskingBeforeTheResourcesLoadAnswersLoadingAndDoesNotWait() async throws {
        let host = try mappedHost(try temporaryDirectory())
        let controller = makeController(host)
        controller.updateAvailability()
        XCTAssertEqual(controller.resolve(direction: .forward, at: 1_000).unavailableReason, .loading,
                       "nothing is loaded yet, and nothing waited for the store")
        XCTAssertFalse(controller.itemHasMap)
        XCTAssertFalse(host.available.forward)

        await controller.settleResources()
        XCTAssertTrue(controller.itemHasMap, "the controls are refreshed when the load lands")
        XCTAssertTrue(host.available.forward)
        XCTAssertNil(controller.resolve(direction: .forward, at: 1_000).unavailableReason)
    }

    /// #2943: a reload keeps the last copy for the same item, so the controls don't flicker off while the store is read,
    /// and a read that an invalidation overtook is never installed as current.
    func testAReloadKeepsTheStaleCopyAndNeverInstallsAnOvertakenRead() async throws {
        let host = try mappedHost(try temporaryDirectory())
        let controller = makeController(host)
        controller.updateAvailability()
        await controller.settleResources()
        XCTAssertTrue(host.available.forward)

        controller.updateAvailability()
        XCTAssertTrue(host.available.forward, "the stale copy answers while the reload runs")
        XCTAssertNil(controller.resolve(direction: .forward, at: 1_000).unavailableReason)
        controller.updateAvailability()
        controller.updateAvailability()
        await controller.settleResources()
        XCTAssertTrue(host.available.forward)
        XCTAssertGreaterThanOrEqual(controller.resourceLoadCount, 2)
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

    func testSkimWithNothingToResolveSaysWhyLogsItAndChangesNothing() {
        let host = ScriptedSkimHost()
        let controller = makeController(host)
        controller.perform(direction: .backward)
        XCTAssertEqual(host.warnings, [SkimUnavailableReason.noSource.message])
        XCTAssertEqual(host.records, [["outcome": "no_plan", "direction": "backward", "reason": "no_source"]])
        XCTAssertEqual(host.log, [])
    }

    /// #2185: an item with no Listening Map says so instead of doing nothing.
    func testAnItemWithNoMapSaysSo() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "skim-reason-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = ScriptedSkimHost()
        host.store = try SQLiteSessionStore(path: directory.appending(path: "store.sqlite").path)
        host.source = SkimSource(itemId: "episode", durationMs: 60_000)
        let controller = makeController(host)
        controller.updateAvailability()
        await controller.settleResources()
        XCTAssertFalse(controller.itemHasMap)
        XCTAssertEqual(controller.forwardUnavailableReason, .noMap)
        controller.perform(direction: .forward)
        XCTAssertEqual(host.warnings, [SkimUnavailableReason.noMap.message])
        XCTAssertEqual(host.records.last?["reason"], "no_map")
    }

    func testASecondTapIsLoggedAsCompletingTheBridge() {
        let host = ScriptedSkimHost()
        host.bridge = makeBridge()
        makeController(host).perform(direction: .forward)
        XCTAssertEqual(host.records, [["outcome": "completed_bridge", "direction": "forward"]])
    }

    // MARK: a summary prepared on the press (#2185)

    /// A store holding a two-scene map, scene 0 from 0 and scene 1 from 5 s, each with a summary and no audio.
    private func mappedHost(_ directory: URL) throws -> ScriptedSkimHost {
        let host = ScriptedSkimHost()
        let store = try SQLiteSessionStore(path: directory.appending(path: "store.sqlite").path)
        let bounds = [0, 5_000, 10_000]
        try store.savePortableListeningMapProposal(PortableListeningMapProposalArtifact(
            id: "map", createdAt: Date(), generator: "test", scenes: (0..<2).map { index in
                PortableListeningMapScene(
                    id: "scene-\(index)", order: index, title: "Scene \(index)", summaryText: "A short recap.",
                    eligibility: .eligible,
                    startAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: bounds[index]),
                    endAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: bounds[index + 1]))
            }), itemId: "episode")
        try store.saveResolvedListeningMapProjection(ResolvedListeningMapProjection(
            id: "projection", itemId: "episode", proposalId: "map",
            algorithmVersion: "episode-projection.exact-edition.v1", points: [], intervals: []))
        host.store = store
        host.source = SkimSource(itemId: "episode", durationMs: 10_000)
        return host
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "skim-prepare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func waitForRecords(_ host: ScriptedSkimHost, count: Int) async throws {
        for _ in 0..<200 where host.records.count < count { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// The bug: a scene with a summary but no saved audio had no Skim, so the slot silently became Next chapter.
    func testASceneWithASummaryButNoAudioIsOfferedAndThePressPreparesIt() async throws {
        let host = try mappedHost(try temporaryDirectory())
        let controller = makeController(host)
        controller.updateAvailability()
        await controller.settleResources()
        XCTAssertTrue(host.available.forward, "Skim is offered before the summary's audio exists")
        XCTAssertTrue(controller.itemHasMap)
        XCTAssertNil(controller.forwardUnavailableReason)
        XCTAssertEqual(controller.forwardDestinationMs, 5_000)

        controller.perform(direction: .forward)
        try await waitForRecords(host, count: 2)
        XCTAssertEqual(host.prepared, ["episode/map/scene-0"], "the summary of the scene being left, under the map's id")
        XCTAssertEqual(host.records.first, ["outcome": "preparing_summary", "direction": "forward", "reason": "no_audio"])
        XCTAssertEqual(host.log.first, "succeeded:Preparing the scene summary.")
    }

    func testAFailedPreparationSaysWhyAndStopsOfferingThatSummary() async throws {
        let host = try mappedHost(try temporaryDirectory())
        host.prepareResult = false
        let controller = makeController(host)
        controller.updateAvailability()
        await controller.settleResources()
        controller.perform(direction: .forward)
        try await waitForRecords(host, count: 2)
        XCTAssertEqual(host.records.last?["outcome"], "no_audio")
        XCTAssertEqual(host.records.last?["reason"], "preparation_failed")
        XCTAssertEqual(host.warnings, [SkimUnavailableReason.preparationFailed.message])
        XCTAssertFalse(host.available.forward, "a summary that can't be prepared isn't offered again on every press")
        XCTAssertEqual(controller.forwardUnavailableReason, .preparationFailed)
        controller.updateAvailability()
        await controller.settleResources()
        XCTAssertTrue(host.available.forward, "a refresh (the item reopened) tries it again")
    }

    func testAPressWhileTheSameSummaryIsPreparedIsToldToWait() async throws {
        let host = try mappedHost(try temporaryDirectory())
        host.prepareDelay = .milliseconds(200)
        let controller = makeController(host)
        controller.updateAvailability()
        await controller.settleResources()
        controller.perform(direction: .forward)
        controller.perform(direction: .forward)
        XCTAssertEqual(host.records.map { $0["outcome"] }, ["preparing_summary", "already_preparing"])
        XCTAssertTrue(host.log.contains("succeeded:Still preparing the scene summary."))
        try await waitForRecords(host, count: 3)
        // The preparation runs in a task, so it is counted only once that task has run and settled.
        XCTAssertEqual(host.prepared.count, 1, "the second press does not prepare it again")
    }

    /// The audit of #2943: a summary saved while Skim has no source (a Margin is recording) must still make the next
    /// pass reload the item's assets, or the next press renders the summary again.
    func testASummarySavedWhileThereIsNoSourceIsReadWhenTheSourceReturns() async throws {
        let host = try mappedHost(try temporaryDirectory())
        let source = host.source
        host.prepareDelay = .milliseconds(50)
        host.prepareResult = true
        let controller = makeController(host)
        controller.updateAvailability()
        await controller.settleResources()
        let loadsBefore = controller.resourceLoadCount

        controller.perform(direction: .forward)
        host.source = nil
        try await waitForRecords(host, count: 2)
        host.source = source
        controller.updateAvailability(refreshResources: false)
        await controller.settleResources()
        XCTAssertGreaterThan(controller.resourceLoadCount, loadsBefore, "what was loaded predates the saved summary")
    }

    /// Prepared, but a Margin's voice took the listener's ear meanwhile: the summary must not start over it.
    func testAPreparedSummaryDoesNotStartOverAMarginsVoice() async throws {
        let host = try mappedHost(try temporaryDirectory())
        host.prepareDelay = .milliseconds(50)
        let controller = makeController(host)
        controller.updateAvailability()
        await controller.settleResources()
        controller.perform(direction: .forward)
        host.mayStartSummary = false
        try await waitForRecords(host, count: 2)
        XCTAssertEqual(host.records.last, ["outcome": "no_audio", "direction": "forward", "reason": "moved_on", "detail": "margin_playing"])
        XCTAssertNil(host.bridge, "nothing started")
        XCTAssertFalse(host.log.contains("pause"), "the source was not paused for a summary")
        XCTAssertTrue(host.warnings.isEmpty, "the Margin playing is its own answer")
    }

    /// Prepared, but saved under another voice than the one now chosen (the listener changed voice meanwhile).
    func testAPreparedSummaryInAVoiceNoLongerChosenSaysWhy() async throws {
        let host = try mappedHost(try temporaryDirectory())
        host.prepareResult = true // the scripted host never has a file, so the summary still has no audio here
        let controller = makeController(host)
        controller.updateAvailability()
        await controller.settleResources()
        controller.perform(direction: .forward)
        try await waitForRecords(host, count: 2)
        XCTAssertEqual(host.records.last?["detail"], "voice_changed")
        XCTAssertEqual(host.warnings, [SkimUnavailableReason.movedOn.message])
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
    var records: [[String: String]] = []
    var prepared: [String] = []
    var prepareResult = true
    var prepareDelay: Duration?
    var mayStartSummary = true
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
    var skimMayStartSummary: Bool { mayStartSummary }
    var skimMediaPlaybackRate: Double { 1 }

    func summaryBridgeAssetID(itemId: String, proposalId: String, sceneId: String, suppliedAssetId: String?) -> String {
        "summary-\(itemId)-\(proposalId)-\(sceneId)"
    }
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
    func skimPrepareSummaryAudio(itemId: String, proposalId: String, scene: PortableListeningMapScene) async throws -> Bool {
        prepared.append("\(itemId)/\(proposalId)/\(scene.id)")
        if let prepareDelay { try await Task.sleep(for: prepareDelay) }
        return prepareResult
    }
    func skimRecord(_ fields: [String: String]) { records.append(fields) }
    func skimWarn(_ message: String) { warnings.append(message) }
    func skimSucceeded(_ message: String) { log.append("succeeded:\(message)") }
    func skimConfirmed(_ message: String) { log.append("confirmed:\(message)") }
    func skimFailed(_ error: Error, context: String) {
        failures.append(context)
        log.append("failed:\(context)")
    }
}
