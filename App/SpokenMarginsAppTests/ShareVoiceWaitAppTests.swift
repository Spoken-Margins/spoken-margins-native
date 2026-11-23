import Foundation
import XCTest
import Combine
import SessionKitSharing
@testable import SessionKit
@testable import SpokenMarginsApp

/// #4647: the Share Margins list reads the words at once and a share waits only for the voices it needs. These run the
/// real model and coordinator with a renderer the test holds, so "nothing builds until the voice lands" is a fact about
/// the code, not about timing.
@MainActor
final class ShareVoiceWaitAppTests: XCTestCase {
    private var revisionsBefore: Set<String> = []
    private var shareRevisions: URL?

    override func setUp() async throws {
        // The model writes cleaned copies under the real Application Support; every folder a test adds is removed.
        let revisions = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appending(path: "SpokenMargins/ShareRevisions", directoryHint: .isDirectory)
        shareRevisions = revisions
        revisionsBefore = Set((try? FileManager.default.contentsOfDirectory(atPath: revisions.path)) ?? [])
    }

    override func tearDown() async throws {
        guard let shareRevisions else { return }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: shareRevisions.path)) ?? []
        where !revisionsBefore.contains(name) {
            try? FileManager.default.removeItem(at: shareRevisions.appending(path: name))
        }
    }

    /// The words of every included Margin are cleaned before the first voice comes back, and Share stays enabled while
    /// the voices are made (#4647 `main-thread`).
    func testEveryMarginsWordsAreCleanedBeforeTheFirstVoiceReturns() async throws {
        let fixture = try makeFixture(marginCount: 3)
        defer { fixture.cleanUp() }
        fixture.model.prepareAllIncludedShareDrafts()
        try await pollUntil { await fixture.gate.heldCount == 1 }

        XCTAssertTrue(fixture.model.sharingState.drafts.allSatisfy { $0.approvedTranscript == "Keep words." },
                      "the words go first, all at once")
        let snapshot = fixture.coordinator.snapshot
        XCTAssertEqual(snapshot.readiness, .waiting(count: 3))
        XCTAssertTrue(snapshot.canAdvance, "nothing a sender chooses waits on cleanup")
        XCTAssertTrue(snapshot.margins.allSatisfy { $0.displayedVersion == .cleaned && $0.waits })
        XCTAssertTrue(snapshot.margins.allSatisfy { $0.menuOptions == [.original, .cleaned, .textOnly] })

        try await fixture.drain()
        XCTAssertEqual(fixture.coordinator.snapshot.readiness, .ready(count: 3))
    }

    /// A share tapped while voices are made builds nothing until the last one lands, then builds once; a second tap
    /// during the wait adds nothing.
    func testATapWhileWaitingBuildsNothingUntilTheVoicesLandThenBuildsOnce() async throws {
        let fixture = try makeFixture(marginCount: 2)
        defer { fixture.cleanUp() }
        fixture.model.prepareAllIncludedShareDrafts()
        try await pollUntil { await fixture.gate.heldCount == 1 }
        var builds = 0
        let watch = fixture.coordinator.$previewState.sink { if $0 == .building { builds += 1 } }
        defer { withExtendedLifetime(watch) {} }

        fixture.coordinator.send(.beginSendWait(.file))
        fixture.coordinator.send(.beginSendWait(.file))
        XCTAssertEqual(fixture.coordinator.snapshot.sendWaitCount, 2)
        XCTAssertEqual(fixture.coordinator.pendingShare, .file)
        XCTAssertEqual(fixture.coordinator.previewState, .notBuilt)
        XCTAssertNil(fixture.model.sharingState.errorMessage)

        await fixture.gate.releaseAll()
        try await pollUntil { fixture.coordinator.snapshot.sendWaitCount == 1 }
        XCTAssertEqual(builds, 0, "one voice still comes: nothing is built")

        try await fixture.drain()
        try await pollUntil { builds > 0 }
        XCTAssertEqual(builds, 1, "the share goes on by itself, once")
        XCTAssertNil(fixture.coordinator.sendWait)
        try await waitForSharingPreview(fixture.coordinator) { $0.snapshot.previewState != .building }
        if let url = fixture.coordinator.verifiedPreview?.fileURL { try? FileManager.default.removeItem(at: url) }
    }

    /// "Stop sharing" ends the wait and sends nothing; the cleanup keeps running. Tap, Stop, tap gives one export.
    func testStopSharingSendsNothingAndATapAfterItBuildsOnce() async throws {
        let fixture = try makeFixture(marginCount: 1)
        defer { fixture.cleanUp() }
        fixture.model.prepareAllIncludedShareDrafts()
        try await pollUntil { await fixture.gate.heldCount == 1 }
        var builds = 0
        let watch = fixture.coordinator.$previewState.sink { if $0 == .building { builds += 1 } }
        defer { withExtendedLifetime(watch) {} }

        fixture.coordinator.send(.beginSendWait(.link))
        fixture.coordinator.send(.stopSendWait)
        XCTAssertNil(fixture.coordinator.sendWait)
        XCTAssertNil(fixture.coordinator.pendingShare)
        XCTAssertTrue(fixture.model.sharingState.isBulkPreparing, "the cleanup keeps running")

        fixture.coordinator.send(.beginSendWait(.file))
        try await fixture.drain()
        try await pollUntil { builds > 0 }
        XCTAssertEqual(builds, 1)
        try await waitForSharingPreview(fixture.coordinator) { $0.snapshot.previewState != .building }
        if let url = fixture.coordinator.verifiedPreview?.fileURL { try? FileManager.default.removeItem(at: url) }
    }

    /// A voice that fails during the wait raises the alert once every wait has ended: "Not now" sends nothing, and
    /// "Share anyway" builds with the fallback. It never sends silently.
    func testAFailedVoiceAsksOnceThenNotNowSendsNothingAndShareAnywayBuilds() async throws {
        let fixture = try makeFixture(marginCount: 1, rendersFail: true)
        defer { fixture.cleanUp() }
        fixture.model.prepareAllIncludedShareDrafts()
        try await pollUntil { await fixture.gate.heldCount == 1 }
        var builds = 0
        let watch = fixture.coordinator.$previewState.sink { if $0 == .building { builds += 1 } }
        defer { withExtendedLifetime(watch) {} }

        fixture.coordinator.send(.beginSendWait(.file))
        try await fixture.drain()
        try await pollUntil { fixture.coordinator.sendWaitFailedCount != nil }
        XCTAssertEqual(fixture.coordinator.snapshot.sendWaitFailedCount, 1)
        XCTAssertNil(fixture.coordinator.snapshot.sendWaitCount)
        XCTAssertEqual(builds, 0, "a failed voice never sends silently")
        XCTAssertEqual(fixture.model.sharingState.drafts[0].representationChoice, .original, "it fell back as today")

        fixture.coordinator.send(.sendWaitNotNow)
        XCTAssertNil(fixture.coordinator.sendWaitFailedCount)
        XCTAssertNil(fixture.coordinator.pendingShare)
        XCTAssertEqual(builds, 0)

        fixture.coordinator.send(.beginSendWait(.file))
        XCTAssertNil(fixture.coordinator.sendWait, "nothing waits now: the share builds at once")
        try await pollUntil { builds > 0 }
        XCTAssertEqual(builds, 1)
        try await waitForSharingPreview(fixture.coordinator) { $0.snapshot.previewState != .building }
        if let url = fixture.coordinator.verifiedPreview?.fileURL { try? FileManager.default.removeItem(at: url) }

        // The same failure answered with "Share anyway".
        let again = try makeFixture(marginCount: 1, rendersFail: true)
        defer { again.cleanUp() }
        again.model.prepareAllIncludedShareDrafts()
        try await pollUntil { await again.gate.heldCount == 1 }
        again.coordinator.send(.beginSendWait(.file))
        try await again.drain()
        try await pollUntil { again.coordinator.sendWaitFailedCount != nil }
        again.coordinator.send(.sendWaitShareAnyway)
        XCTAssertNil(again.coordinator.sendWaitFailedCount)
        XCTAssertNotEqual(again.coordinator.previewState, .notBuilt, "Share anyway builds with the fallback")
        try await waitForSharingPreview(again.coordinator) { $0.snapshot.previewState != .building }
        if let url = again.coordinator.verifiedPreview?.fileURL { try? FileManager.default.removeItem(at: url) }
    }

    /// A Margin set to As recorded leaves the wait at once: a share then goes without waiting for its voice.
    func testPickingAsRecordedStopsWaitingForThatVoice() async throws {
        let fixture = try makeFixture(marginCount: 1)
        defer { fixture.cleanUp() }
        fixture.model.prepareAllIncludedShareDrafts()
        try await pollUntil { await fixture.gate.heldCount == 1 }
        XCTAssertTrue(fixture.coordinator.snapshot.readiness.isWaiting)

        fixture.coordinator.send(.setRepresentation(id: "margin-wait-0", choice: .original))
        XCTAssertEqual(fixture.coordinator.snapshot.readiness, .ready(count: 1))
        XCTAssertEqual(fixture.coordinator.snapshot.margins[0].displayedVersion, .original)

        try await fixture.drain()
        XCTAssertEqual(fixture.model.sharingState.drafts[0].representationChoice, .original, "the pick holds when the voice lands")
    }

    /// The export itself refuses while a voice it needs is still being made: the sheet waits before it asks.
    func testTheExportRefusesWhileAVoiceItNeedsIsBeingMade() async throws {
        let fixture = try makeFixture(marginCount: 1)
        defer { fixture.cleanUp() }
        fixture.model.prepareAllIncludedShareDrafts()
        try await pollUntil { await fixture.gate.heldCount == 1 }
        let url = await fixture.model.exportSharedInterjections(presentsReadySheet: false)
        XCTAssertNil(url)
        XCTAssertEqual(fixture.model.sharingState.errorMessage, ShareReviewCardWords.waiting(count: 1))
        try await fixture.drain()
    }

    // MARK: Fixture

    private struct Fixture {
        let model: Gate1AppModel
        let coordinator: Build23SharingCoordinator
        let gate: GatedRenders
        let root: URL

        /// Releases each held render until the run has finished.
        @MainActor
        func drain() async throws {
            try await pollUntil {
                await gate.releaseAll()
                return !model.sharingState.isBulkPreparing && model.sharingState.queuedVoiceIDs.isEmpty
            }
            XCTAssertFalse(model.sharingState.isBulkPreparing, "the run finished")
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeFixture(marginCount: Int, rendersFail: Bool = false) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "share-voice-wait-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = root.appending(path: "voice.m4a")
        try Data([0x53, 0x4D, 0x01, 0x35]).write(to: audio)
        let gate = GatedRenders(fails: rendersFail)
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            shareMarginSilenceAnalysisHandler: { _, _ in [] },
            shareMarginAudioCleanupHandler: { _, destinationURL, _ in
                try await gate.render(destinationURL: destinationURL)
            }
        )
        model.resetAndSeed()
        let itemID = model.selectedItem.id
        model.selectedItem.interjections = (0..<marginCount).map { index in
            let id = "margin-wait-\(index)"
            return Interjection(
                id: id, itemId: itemID, sessionId: "session-share-wait", targetType: .item, targetId: itemID,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index + 1)), roughPercent: 20 * (index + 1),
                anchor: Anchor(anchorType: .text, startChar: 0, endChar: 5, anchorBefore: "Before", anchorAfter: "After"),
                audioPath: audio.path, audioStatus: "saved", transcriptionStatus: "transcribed",
                transcript: "Keep um words.", cleanedTranscript: nil, displayText: nil, status: "active",
                alignedTranscript: AlignedInterjectionTranscript(text: "Keep um words.", segments: [
                    .init(id: "\(id)-keep", text: "Keep", startMs: 0, endMs: 200),
                    .init(id: "\(id)-um", text: "um", startMs: 240, endMs: 380),
                    .init(id: "\(id)-words", text: "words.", startMs: 420, endMs: 700)
                ])
            )
        }
        let coordinator = Build23SharingCoordinator(model: model)
        // Whatever the stored switch says, the sheet opens with no run of its own for the test to race.
        let priorDecision = UserDefaults.standard.object(forKey: ShareAutoCleanPreference.decisionRecordedKey)
        let priorEnabled = UserDefaults.standard.object(forKey: ShareAutoCleanPreference.enabledKey)
        UserDefaults.standard.set(false, forKey: ShareAutoCleanPreference.enabledKey)
        coordinator.send(.begin)
        restore(priorDecision, forKey: ShareAutoCleanPreference.decisionRecordedKey)
        restore(priorEnabled, forKey: ShareAutoCleanPreference.enabledKey)
        model.cancelBulkSharePreparation()
        return Fixture(model: model, coordinator: coordinator, gate: gate, root: root)
    }

    private func restore(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

/// A renderer the test holds: each render waits until the test releases it, then writes a copy or throws.
private actor GatedRenders {
    private var held: [CheckedContinuation<Void, Never>] = []
    private let fails: Bool

    init(fails: Bool) {
        self.fails = fails
    }

    var heldCount: Int { held.count }

    func render(destinationURL: URL) async throws -> Int {
        await withCheckedContinuation { held.append($0) }
        if fails { throw SessionKitError.persistenceFailed("deliberate_cleanup_failure") }
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x01, 0x02, 0x03]).write(to: destinationURL)
        return 600
    }

    func releaseAll() {
        let released = held
        held = []
        released.forEach { $0.resume() }
    }
}
