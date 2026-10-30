import XCTest
import SessionKit
import SessionKitAudio
import SessionKitPersistence
@testable import SpokenMarginsApp

/// The coordinator that places a shared podcast Margin on the listener's own copy and rations the transcript of that
/// copy (#1015). Built directly from recording dependencies, never through `Gate1AppModel`. Real temporary files and a
/// real SQLite store stand at the boundaries; only the transcriber is a fake, and it is gated so a test decides when
/// the transient transcript finishes.
@MainActor
final class ImportedPodcastPlacementCoordinatorTests: XCTestCase {
    // MARK: Admission

    /// The boundary itself (59.999 s refused, 60 s allowed) is `ImportedPodcastPlacementPolicyTests`' row. Mutation:
    /// writing `lastTransientStart` when the attempt ends instead of when it starts (it would refuse at +60s, the
    /// attempt having ended at +5s); passing the policy no `lastStart` or the wrong clock admits the request at +30s.
    func testTransientCooldownIsStartToStart() async throws {
        let h = try PlacementCoordinatorHarness()
        defer { h.shutdown() }
        let item = h.makeItem()
        let file = try h.writeAudio("episode.mp3")
        let start = h.spies.clock
        XCTAssertTrue(h.coordinator.scheduleTransientTranscript(for: item, localSourceURL: file))

        h.spies.clock = start.addingTimeInterval(5) // the first attempt finishes at +5s
        h.transcriber.open()
        let released = try await h.waitUntil { h.coordinator.admission[item.id] == nil }
        XCTAssertTrue(released, "the first transcript should have finished")

        h.spies.clock = start.addingTimeInterval(30)
        XCTAssertFalse(h.coordinator.scheduleTransientTranscript(for: item, localSourceURL: file))
        h.spies.clock = start.addingTimeInterval(ImportedPodcastPlacementCoordinator.transientCooldown)
        XCTAssertTrue(h.coordinator.scheduleTransientTranscript(for: item, localSourceURL: file))
        XCTAssertEqual(h.coordinator.lastTransientStart[item.id], start.addingTimeInterval(60))
    }

    /// Mutation: writing `lastTransientStart` before the readability or slot checks (or on a refusal) pushes the next
    /// admission past +60s from the first start.
    func testRefusedRequestsLeaveTheCooldownTimestampAlone() async throws {
        let h = try PlacementCoordinatorHarness()
        defer { h.shutdown() }
        let item = h.makeItem()
        let file = try h.writeAudio("episode.mp3")
        let missing = h.root.appendingPathComponent("never-written.mp3")
        let start = h.spies.clock
        XCTAssertTrue(h.coordinator.scheduleTransientTranscript(for: item, localSourceURL: file))
        h.transcriber.open()
        let released = try await h.waitUntil { h.coordinator.admission[item.id] == nil }
        XCTAssertTrue(released)

        h.spies.clock = start.addingTimeInterval(10)
        XCTAssertFalse(h.coordinator.scheduleTransientTranscript(for: item, localSourceURL: missing), "an unreadable file is refused")
        XCTAssertEqual(h.coordinator.lastTransientStart[item.id], start)

        h.spies.clock = start.addingTimeInterval(30)
        XCTAssertTrue(h.coordinator.beginFullSourceTranscription(itemId: item.id))
        XCTAssertFalse(h.coordinator.scheduleTransientTranscript(for: item, localSourceURL: file), "the held slot refuses it")
        XCTAssertEqual(h.coordinator.lastTransientStart[item.id], start)
        h.coordinator.releaseFullSourceTranscription(itemId: item.id)

        h.spies.clock = start.addingTimeInterval(60)
        XCTAssertTrue(h.coordinator.scheduleTransientTranscript(for: item, localSourceURL: file),
                      "the cooldown runs from the first start, not from either refusal")
    }

    /// Mutation: clearing `lastTransientStart` (or releasing nothing) when a successful pass ends; skipping the purge,
    /// the diagnostic or the `.transcript` display end on success.
    func testSuccessfulTransientPassKeepsTheCooldownAndReleasesEverything() async throws {
        let h = try PlacementCoordinatorHarness()
        defer { h.shutdown() }
        let item = h.makeItem()
        let file = try h.writeAudio("episode.mp3")
        let start = h.spies.clock
        XCTAssertTrue(h.coordinator.scheduleTransientTranscript(for: item, localSourceURL: file))
        XCTAssertNotNil(h.coordinator.passes.pass(itemId: item.id), "the .transcript display begins with the pass")

        h.transcriber.open()
        let released = try await h.waitForTransientPassToFinish()
        XCTAssertTrue(released)

        XCTAssertEqual(h.coordinator.lastTransientStart[item.id], start)
        XCTAssertEqual(h.spies.transientDiagnostics(item.id), ["transcribing_transiently", "consumed_and_deleted"])
        XCTAssertEqual(h.spies.purged, [item.id])
        XCTAssertNil(h.coordinator.passes.pass(itemId: item.id), "the .transcript display ends with the pass")
    }

    /// Mutation: leaving the slot held, skipping the purge, writing another diagnostic text, or leaving the
    /// `.transcript` display up when the transcriber throws.
    func testFailedTransientPassKeepsTheCooldownAndCleansUp() async throws {
        let h = try PlacementCoordinatorHarness()
        defer { h.shutdown() }
        let item = h.makeItem()
        let file = try h.writeAudio("episode.mp3")
        let start = h.spies.clock
        XCTAssertTrue(h.coordinator.scheduleTransientTranscript(for: item, localSourceURL: file))

        let failure = PlacementTestFailure()
        h.transcriber.open(failingWith: failure)
        let released = try await h.waitForTransientPassToFinish()
        XCTAssertTrue(released)

        XCTAssertEqual(h.coordinator.lastTransientStart[item.id], start)
        XCTAssertEqual(h.spies.transientDiagnostics(item.id),
                       ["transcribing_transiently", "failed_and_deleted:\(failure.localizedDescription)"])
        XCTAssertEqual(h.spies.purged, [item.id])
        XCTAssertNil(h.coordinator.passes.pass(itemId: item.id))
        XCTAssertTrue(h.spies.deferCalls.isEmpty, "a failed transcript never reaches placement")
    }

    /// Mutation: letting the full-source pass skip the slot check, or letting a transient pass start while the slot is
    /// held; letting the full-source pass write `lastTransientStart` makes the transient request at +30s refuse.
    func testFullSourceHoldsTheSlotAgainstATransientRequestWithoutWritingTheCooldown() throws {
        let h = try PlacementCoordinatorHarness()
        defer { h.shutdown() }
        let item = h.makeItem()
        let file = try h.writeAudio("episode.mp3")
        let start = h.spies.clock

        XCTAssertTrue(h.coordinator.beginFullSourceTranscription(itemId: item.id))
        XCTAssertFalse(h.coordinator.beginFullSourceTranscription(itemId: item.id), "one holder at a time")
        h.spies.clock = start.addingTimeInterval(30)
        XCTAssertFalse(h.coordinator.scheduleTransientTranscript(for: item, localSourceURL: file))
        XCTAssertEqual(h.coordinator.admission[item.id], .fullSource)
        XCTAssertNil(h.coordinator.lastTransientStart[item.id])
        XCTAssertTrue(h.spies.diagnosticLog.isEmpty)
        XCTAssertNil(h.coordinator.passes.pass(itemId: item.id), "full-source shows no placement display")

        h.coordinator.releaseFullSourceTranscription(itemId: item.id)
        XCTAssertTrue(h.coordinator.scheduleTransientTranscript(for: item, localSourceURL: file),
                      "a full-source run in between is not a transient attempt, so no cooldown applies")
    }

    /// Mutation: making the full-source pass obey the cooldown, or write to it; letting it start while a transient
    /// pass holds the slot; dropping the `admission[item.id] == nil` guard in `scheduleTransientTranscript`, which
    /// admits a second transcript of the same item while one runs (the clock is far past the cooldown, so only the
    /// held slot can refuse it).
    func testATransientPassBlocksFullSourceButFullSourceIgnoresTheCooldown() async throws {
        let h = try PlacementCoordinatorHarness()
        defer { h.shutdown() }
        let item = h.makeItem()
        let file = try h.writeAudio("episode.mp3")
        let start = h.spies.clock
        XCTAssertTrue(h.coordinator.scheduleTransientTranscript(for: item, localSourceURL: file))
        XCTAssertFalse(h.coordinator.beginFullSourceTranscription(itemId: item.id), "the transient pass holds the slot")
        let admitted = h.coordinator.admission[item.id]
        h.spies.clock = start.addingTimeInterval(ImportedPodcastPlacementCoordinator.transientCooldown * 2)
        XCTAssertFalse(h.coordinator.scheduleTransientTranscript(for: item, localSourceURL: file), "a second transient request")
        XCTAssertEqual(h.coordinator.admission[item.id], admitted)
        XCTAssertEqual(h.coordinator.lastTransientStart[item.id], start, "a refused request must not move the cooldown clock")
        XCTAssertEqual(h.spies.transientDiagnostics(item.id), ["transcribing_transiently"], "only the first request started a transcript")
        h.spies.clock = start

        h.transcriber.open()
        let released = try await h.waitUntil { h.coordinator.admission[item.id] == nil }
        XCTAssertTrue(released)

        // Still inside the transient cooldown: full-source is not held back by it, and does not touch it.
        XCTAssertTrue(h.coordinator.beginFullSourceTranscription(itemId: item.id))
        XCTAssertEqual(h.coordinator.lastTransientStart[item.id], start)

        h.spies.clock = start.addingTimeInterval(60)
        XCTAssertFalse(h.coordinator.scheduleTransientTranscript(for: item, localSourceURL: file), "the slot is held")
        XCTAssertEqual(h.coordinator.lastTransientStart[item.id], start)
        h.coordinator.releaseFullSourceTranscription(itemId: item.id)
        XCTAssertTrue(h.coordinator.scheduleTransientTranscript(for: item, localSourceURL: file),
                      "the cooldown still runs from the transient start at +0s")
        XCTAssertEqual(h.coordinator.lastTransientStart[item.id], start.addingTimeInterval(60))
    }

    /// Mutation: taking the slot (or writing the cooldown, a diagnostic or a display) before the readability check.
    func testAnUnreadableFileDoesNotTakeTheSlot() throws {
        let h = try PlacementCoordinatorHarness()
        defer { h.shutdown() }
        let item = h.makeItem()
        let missing = h.root.appendingPathComponent("never-written.mp3")

        XCTAssertFalse(h.coordinator.scheduleTransientTranscript(for: item, localSourceURL: missing))

        XCTAssertNil(h.coordinator.admission[item.id])
        XCTAssertNil(h.coordinator.lastTransientStart[item.id])
        XCTAssertTrue(h.spies.diagnosticLog.isEmpty)
        XCTAssertEqual(h.coordinator.passes, SharedMarginPlacementPasses())
        XCTAssertTrue(h.coordinator.beginFullSourceTranscription(itemId: item.id))
    }

    // MARK: Placement: rejected preflight

    /// Mutation: letting `resolve` continue past a nil store (or returning something other than `.rejected`), or not
    /// clearing the item's earlier deferral.
    func testResolveRejectsARequestWithoutAStore() async throws {
        let h = try PlacementCoordinatorHarness()
        defer { h.shutdown() }
        let store = try h.makeStore()
        try h.seedPodcastItem(in: store)
        let file = try h.writeAudio("episode.mp3")
        h.spies.store = nil

        await assertRejectedPreflight(h, url: file)
    }

    /// Mutation: dropping the file-identity read from the preflight guard.
    func testResolveRejectsARequestForAMissingFile() async throws {
        let h = try PlacementCoordinatorHarness()
        defer { h.shutdown() }
        let store = try h.makeStore()
        try h.seedPodcastItem(in: store)

        await assertRejectedPreflight(h, url: h.root.appendingPathComponent("never-written.mp3"))
    }

    /// Mutation: dropping the item load from the preflight guard (an orphaned layer would then be placed).
    func testResolveRejectsARequestForAMissingItem() async throws {
        let h = try PlacementCoordinatorHarness()
        defer { h.shutdown() }
        let store = try h.makeStore()
        try h.seedLayer(in: store) // a layer for an item the store does not hold
        let file = try h.writeAudio("episode.mp3")

        await assertRejectedPreflight(h, url: file)
    }

    /// Mutation: dropping the `!layers.isEmpty` clause, which would treat "no layers loaded" as "evaluated empty"
    /// and cancel the running pass.
    func testResolveRejectsAnItemWithNoLoadedLayers() async throws {
        let h = try PlacementCoordinatorHarness()
        defer { h.shutdown() }
        let store = try h.makeStore()
        try store.saveItem(h.makeItem())
        let file = try h.writeAudio("episode.mp3")

        await assertRejectedPreflight(h, url: file)
    }

    /// Mutation: cancelling the matching pass or ending its display on a rejected preflight (the old model code did
    /// both for every empty result).
    func testRejectedPreflightDoesNotDisturbARunningPass() async throws {
        let h = try PlacementCoordinatorHarness()
        defer { h.shutdown() }
        let store = try h.makeStore()
        try h.seedPodcastItem(in: store)
        let fileA = try h.writeAudio("a.mp3")
        let scheduled = try await h.resolveReplacingThePass(url: fileA)
        XCTAssertEqual(scheduled.outcome, .scheduled(joined: false))
        let running = scheduled.probe
        let passesBefore = h.coordinator.passes
        XCTAssertNotNil(passesBefore.pass(itemId: h.itemId))

        let outcome = await h.coordinator.resolveAndWait(itemId: h.itemId, localURL: h.root.appendingPathComponent("missing-b.mp3"))

        XCTAssertEqual(outcome, .rejected)
        XCTAssertTrue(h.coordinator.matching.isCurrent(running), "the running pass was not cancelled")
        XCTAssertEqual(h.coordinator.passes, passesBefore)
        XCTAssertEqual(h.coordinator.requestedURL[h.itemId], fileA)
        XCTAssertEqual(h.spies.clearedDeferred, [h.itemId])
    }

    // MARK: Placement: evaluated results

    /// Mutation: treating "layers exist, none with podcast work" like a rejection (running pass kept, URL not
    /// remembered), or letting it end the `.transcript` display or free the transcription slot.
    func testEvaluatedEmptyWorkCancelsTheMatchingPassAndKeepsTheTranscript() async throws {
        let h = try PlacementCoordinatorHarness()
        defer { h.shutdown() }
        let store = try h.makeStore()
        try h.seedPodcastItem(in: store)
        let fileA = try h.writeAudio("a.mp3")
        let fileC = try h.writeAudio("c.mp3")
        let item = h.makeItem()
        XCTAssertTrue(h.coordinator.scheduleTransientTranscript(for: item, localSourceURL: fileA))
        let transientFile = try PodcastPlacementFile(url: fileA)
        let scheduled = try await h.resolveReplacingThePass(url: fileA)
        XCTAssertEqual(scheduled.outcome, .scheduled(joined: false))
        let running = scheduled.probe
        XCTAssertTrue(h.coordinator.matching.isCurrent(running))
        XCTAssertEqual(h.coordinator.passes, h.expectedPasses(.transcript, .matching))

        // The only layer is now deleted: layers load, but there is no podcast work in them.
        var layer = try XCTUnwrap(try store.loadImportedCommentaryLayers(itemId: h.itemId).first)
        layer.deletedAt = Date(timeIntervalSince1970: 1_700_000_100)
        try store.saveImportedCommentaryLayer(layer)
        let deferCallsBefore = h.spies.deferCalls.count

        let outcome = await h.coordinator.resolveAndWait(itemId: h.itemId, localURL: fileC)

        XCTAssertEqual(outcome, .noPodcastWork)
        XCTAssertEqual(h.coordinator.requestedURL[h.itemId], fileC, "an evaluated request is remembered")
        XCTAssertFalse(h.coordinator.matching.isCurrent(running), "the running pass was cancelled")
        XCTAssertEqual(h.coordinator.passes, h.expectedPasses(.transcript), "only the .matching display ended")
        XCTAssertEqual(h.coordinator.admission[h.itemId], .transient(transientFile))
        XCTAssertEqual(h.spies.deferCalls.count, deferCallsBefore + 1, "the deferral check ran before the work was evaluated")
        XCTAssertTrue(h.spies.clearedDeferred.isEmpty, "an evaluated request is not a rejection")
    }

    /// Mutation: moving the `deferPlacement` check after `requestedURL[itemId] = localURL` or after the pass is
    /// scheduled; clearing the deferral (the model already wrote it).
    func testDeferredPlacementChangesNothingElse() async throws {
        let h = try PlacementCoordinatorHarness()
        defer { h.shutdown() }
        let store = try h.makeStore()
        try h.seedPodcastItem(in: store)
        let file = try h.writeAudio("episode.mp3")
        let running = try await h.installProbePass(url: file)
        h.spies.deferHandler = { _, _ in true }

        let outcome = await h.coordinator.resolveAndWait(itemId: h.itemId, localURL: file)

        XCTAssertEqual(outcome, .deferred)
        XCTAssertEqual(h.spies.deferCalls.count, 1)
        XCTAssertNil(h.coordinator.requestedURL[h.itemId])
        XCTAssertTrue(h.coordinator.matching.isCurrent(running), "nothing was scheduled over the existing pass")
        XCTAssertEqual(h.coordinator.passes, SharedMarginPlacementPasses())
        XCTAssertTrue(h.spies.diagnosticLog.isEmpty)
        XCTAssertTrue(h.spies.clearedDeferred.isEmpty)
    }

    /// Mutation: releasing the admission slot after `resolve` (or not at all) in the transient task, which lets the
    /// stronger pass's own follow-up request find the slot taken.
    func testTransientSuccessReleasesAdmissionBeforeTheStrongerPassIsRequested() async throws {
        let h = try PlacementCoordinatorHarness()
        defer { h.shutdown() }
        let store = try h.makeStore()
        try h.seedPodcastItem(in: store)
        let file = try h.writeAudio("episode.mp3")
        let item = h.makeItem()
        // The first request is a real one (it records the URL the transient task checks); the second is the stronger
        // pass the finished transcript asks for, and is stopped at the deferral spy after it has looked at the slot.
        h.spies.deferHandler = { [unowned h] _, _ in
            h.spies.slotWasFreeAtDeferral.append(h.coordinator.admission[h.itemId] == nil)
            return h.spies.deferCalls.count > 1
        }
        let scheduledOutcome = await h.coordinator.resolveAndWait(itemId: h.itemId, localURL: file)
        XCTAssertEqual(scheduledOutcome, .scheduled(joined: false))
        h.coordinator.matching.cancel(itemId: h.itemId)
        XCTAssertTrue(h.coordinator.scheduleTransientTranscript(for: item, localSourceURL: file))
        XCTAssertEqual(h.coordinator.admission[h.itemId], .transient(try PodcastPlacementFile(url: file)))

        h.transcriber.open()
        let finished = try await h.waitForTransientPassToFinish()
        XCTAssertTrue(finished)

        XCTAssertEqual(h.spies.deferCalls.count, 2, "the finished transcript asked for exactly one stronger pass")
        XCTAssertEqual(h.spies.slotWasFreeAtDeferral, [true, true], "the slot was already free when placement ran")
        XCTAssertNil(h.coordinator.admission[h.itemId])
    }

    /// Mutation: dropping the `requestedURL[item.id] == localSourceURL` check, so a transcript made for an earlier
    /// request is placed against a newer one. The purge and diagnostic must still happen.
    func testTranscriptIsDiscardedWhenAnotherURLWasRequestedMeanwhile() async throws {
        let h = try PlacementCoordinatorHarness()
        defer { h.shutdown() }
        let store = try h.makeStore()
        try h.seedPodcastItem(in: store)
        let fileA = try h.writeAudio("a.mp3")
        let fileC = try h.writeAudio("c.mp3")
        let item = h.makeItem()
        let scheduledOutcome = await h.coordinator.resolveAndWait(itemId: h.itemId, localURL: fileA)
        XCTAssertEqual(scheduledOutcome, .scheduled(joined: false))
        h.coordinator.matching.cancel(itemId: h.itemId)
        XCTAssertTrue(h.coordinator.scheduleTransientTranscript(for: item, localSourceURL: fileA))
        let secondOutcome = await h.coordinator.resolveAndWait(itemId: h.itemId, localURL: fileC)
        XCTAssertEqual(secondOutcome, .scheduled(joined: false))
        h.coordinator.matching.cancel(itemId: h.itemId)
        XCTAssertEqual(h.spies.deferCalls.count, 2)

        h.transcriber.open()
        let finished = try await h.waitForTransientPassToFinish()
        XCTAssertTrue(finished)

        XCTAssertEqual(h.spies.deferCalls.count, 2, "no matching was requested for the stale transcript")
        XCTAssertEqual(h.coordinator.requestedURL[h.itemId], fileC)
        XCTAssertEqual(h.spies.purged, [h.itemId])
        XCTAssertEqual(h.spies.transientDiagnostics(h.itemId).last, "consumed_and_deleted")
    }

    /// Mutation: dropping the `PodcastPlacementFile(url:) == sourceFile` check, so a transcript of a file that was
    /// replaced at the same URL is placed against the new file.
    func testTranscriptIsDiscardedWhenTheFileWasReplacedAtTheSameURL() async throws {
        let h = try PlacementCoordinatorHarness()
        defer { h.shutdown() }
        let store = try h.makeStore()
        try h.seedPodcastItem(in: store)
        let file = try h.writeAudio("episode.mp3", bytes: 64)
        let item = h.makeItem()
        let scheduledOutcome = await h.coordinator.resolveAndWait(itemId: h.itemId, localURL: file)
        XCTAssertEqual(scheduledOutcome, .scheduled(joined: false))
        h.coordinator.matching.cancel(itemId: h.itemId)
        XCTAssertTrue(h.coordinator.scheduleTransientTranscript(for: item, localSourceURL: file))
        // An atomic write puts a new file (new inode, size and modification time) at the same URL.
        try Data(repeating: 0x42, count: 4_096).write(to: file, options: .atomic)
        XCTAssertNotEqual(try PodcastPlacementFile(url: file), try h.coordinator.admissionFile(itemId: h.itemId))
        XCTAssertEqual(h.coordinator.requestedURL[h.itemId], file, "only the file identity differs")

        h.transcriber.open()
        let finished = try await h.waitForTransientPassToFinish()
        XCTAssertTrue(finished)

        XCTAssertEqual(h.spies.deferCalls.count, 1, "no matching was requested for the stale transcript")
        XCTAssertEqual(h.spies.purged, [h.itemId])
        XCTAssertEqual(h.spies.transientDiagnostics(h.itemId).last, "consumed_and_deleted")
    }

    /// Mutation: moving the `didSet` notification into a `Task`/`DispatchQueue.main.async`, or dropping the old value.
    func testPassChangesNotifyTheModelSynchronouslyWithOldAndNewValues() async throws {
        let h = try PlacementCoordinatorHarness()
        defer { h.shutdown() }
        let item = h.makeItem()
        let file = try h.writeAudio("episode.mp3")

        XCTAssertTrue(h.coordinator.scheduleTransientTranscript(for: item, localSourceURL: file))
        // Nothing awaited yet: the notification must already have arrived.
        XCTAssertEqual(h.spies.passesLog.count, 1)
        XCTAssertEqual(h.spies.passesLog.first?.old, SharedMarginPlacementPasses())
        XCTAssertEqual(h.spies.passesLog.first?.new, h.expectedPasses(.transcript))

        h.transcriber.open()
        let released = try await h.waitForTransientPassToFinish()
        XCTAssertTrue(released)
        XCTAssertEqual(h.spies.passesLog.count, 2)
        XCTAssertEqual(h.spies.passesLog.last?.old, h.expectedPasses(.transcript))
        XCTAssertEqual(h.spies.passesLog.last?.new, SharedMarginPlacementPasses())
    }

    /// Mutation: letting a superseded operation end the `.matching` display (dropping the `isCurrent` / cancellation
    /// guards in the operation's cancellation path), which would show "placed" while the newer pass still runs.
    /// Flaked when the test joined the pass after `resolveAndWait` returned (#2952): the pass had already ended.
    func testASupersededPassNeverEndsTheDisplay() async throws {
        let h = try PlacementCoordinatorHarness()
        defer { h.shutdown() }
        let store = try h.makeStore()
        try h.seedPodcastItem(in: store)
        let file = try h.writeAudio("episode.mp3")
        // The pass `resolve` starts is joined, to hold its completion handle, and superseded by a pass of the test's own,
        // both before the main actor is released: that pass runs on a detached task and could otherwise end first.
        let scheduled = try await h.resolveReplacingThePass(url: file)
        XCTAssertEqual(scheduled.outcome, .scheduled(joined: false))
        let newer = scheduled.probe
        await scheduled.realPass.value

        XCTAssertTrue(h.coordinator.matching.isCurrent(newer))
        XCTAssertEqual(h.coordinator.passes, h.expectedPasses(.matching), "the newer pass is still displayed as placing")
        XCTAssertEqual(h.spies.diagnostics["importedPodcastAnchorResolution:\(h.itemId)"], "scheduled:1",
                       "the superseded operation recorded no result")
    }

    // MARK: Helpers

    private func assertRejectedPreflight(
        _ h: PlacementCoordinatorHarness,
        url: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let requestedBefore = h.coordinator.requestedURL
        let passesBefore = h.coordinator.passes

        let outcome = await h.coordinator.resolveAndWait(itemId: h.itemId, localURL: url)

        XCTAssertEqual(outcome, .rejected, file: file, line: line)
        XCTAssertEqual(h.spies.clearedDeferred, [h.itemId], file: file, line: line)
        XCTAssertTrue(h.spies.diagnosticLog.isEmpty, file: file, line: line)
        XCTAssertEqual(h.coordinator.requestedURL, requestedBefore, file: file, line: line)
        XCTAssertTrue(h.spies.deferCalls.isEmpty, file: file, line: line)
        XCTAssertEqual(h.coordinator.passes, passesBefore, file: file, line: line)
    }
}

// MARK: - Fixtures

private extension ImportedPodcastPlacementCoordinator {
    /// The file the item's transient admission was made for, so a test can show a replaced file no longer matches it.
    func admissionFile(itemId: String) throws -> PodcastPlacementFile {
        guard case .transient(let file)? = admission[itemId] else {
            throw PlacementTestFailure()
        }
        return file
    }
}

private struct PlacementTestFailure: LocalizedError {
    var errorDescription: String? { "the transcriber refused the file" }
}

/// A transcriber that waits until the test opens it, then returns an empty timeline or throws the given error.
/// Once opened it stays open. A lock, not an actor, so `open` can be called from a synchronous `defer`.
private final class PlacementGatedTranscriber: SourceTranscriptionClient, @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var failure: (any Error)?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open(failingWith error: (any Error)? = nil) {
        let toResume = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            failure = error
            let waiting = waiters
            waiters = []
            return waiting
        }
        for continuation in toResume { continuation.resume() }
    }

    func transcribeSourceAudio(url: URL, itemId: String, durationMs: Int?) async throws -> TranscriptTimeline {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
        if let error = lock.withLock({ failure }) { throw error }
        return TranscriptTimeline(segments: [], chapters: [], durationMs: durationMs)
    }
}

/// Holds the context of a matching pass the test scheduled itself, and keeps that pass alive until it is cancelled.
private actor PlacementPassProbe {
    private(set) var context: PodcastPlacementPassCoordinator.Context?

    func started(_ context: PodcastPlacementPassCoordinator.Context) {
        self.context = context
    }
}

/// What `resolveReplacingThePass`'s diagnostic hook captured.
@MainActor
private final class PlacementPassHook {
    var realPass: Task<Void, Never>?
    var probe: PlacementPassProbe?
    var failure: (any Error)?
}

/// Everything the coordinator's dependencies reported, in the order it happened.
@MainActor
private final class PlacementSpies {
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    var store: SQLiteSessionStore?
    var deferHandler: @MainActor (Item, URL) -> Bool = { _, _ in false }

    private(set) var diagnostics: [String: String] = [:]
    private(set) var diagnosticLog: [(key: String, value: String)] = []
    private(set) var clearedDeferred: [String] = []
    private(set) var deferCalls: [(itemId: String, url: URL)] = []
    private(set) var purged: [String] = []
    private(set) var refreshedAfterInvalidation: [String] = []
    private(set) var passesLog: [(old: SharedMarginPlacementPasses, new: SharedMarginPlacementPasses)] = []
    var slotWasFreeAtDeferral: [Bool] = []
    /// Runs inside each reported diagnostic, on the main actor, so a test can act at a point `resolve` reaches
    /// without having awaited anything since it scheduled its pass.
    var onDiagnostic: (@MainActor (String, String) -> Void)?

    func recordDiagnostic(_ key: String, _ value: String) {
        diagnostics[key] = value
        diagnosticLog.append((key: key, value: value))
        onDiagnostic?(key, value)
    }

    func recordDeferral(_ item: Item, _ url: URL) {
        deferCalls.append((itemId: item.id, url: url))
    }

    func recordClearedDeferral(_ itemId: String) { clearedDeferred.append(itemId) }
    func recordPurge(_ itemId: String) { purged.append(itemId) }
    func recordRefresh(_ itemId: String) { refreshedAfterInvalidation.append(itemId) }

    func recordPassesChange(_ old: SharedMarginPlacementPasses, _ new: SharedMarginPlacementPasses) {
        passesLog.append((old: old, new: new))
    }

    func transientDiagnostics(_ itemId: String) -> [String] {
        diagnosticLog.filter { $0.key == "recipientAlignmentTranscript:\(itemId)" }.map(\.value)
    }
}

@MainActor
private final class PlacementCoordinatorHarness {
    let itemId = "episode-1"
    let root: URL
    let spies: PlacementSpies
    let transcriber: PlacementGatedTranscriber
    let coordinator: ImportedPodcastPlacementCoordinator

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("imported-podcast-placement-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let spies = PlacementSpies()
        let transcriber = PlacementGatedTranscriber()
        self.root = root
        self.spies = spies
        self.transcriber = transcriber
        coordinator = ImportedPodcastPlacementCoordinator(dependencies: .init(
            store: { spies.store },
            now: { spies.clock },
            transcriber: transcriber,
            deferPlacement: { item, url in
                spies.recordDeferral(item, url)
                return spies.deferHandler(item, url)
            },
            clearDeferredPlacement: { spies.recordClearedDeferral($0) },
            localAudiobookDigest: { _ in nil },
            applicationSupportDirectory: { nil },
            listenerHasListeningMap: { _, _ in false },
            purgeTransientCaches: { spies.recordPurge($0) },
            prepareSummaryBridgeAsset: { _, _, _, _ in },
            updateSkimAvailability: {},
            refreshAfterInvalidation: { spies.recordRefresh($0) },
            refreshSelectedItemIfShowing: { _ in },
            recordDiagnostic: { spies.recordDiagnostic($0, $1) },
            passesDidChange: { old, new in spies.recordPassesChange(old, new) },
            retainHost: { nil }
        ))
    }

    /// Opens the gate so no transcript task stays suspended, retires any pass, and removes the temporary files.
    func shutdown() {
        transcriber.open()
        coordinator.matching.cancel(itemId: itemId)
        try? FileManager.default.removeItem(at: root)
    }

    func makeItem() -> Item {
        Item(
            id: itemId, title: "Episode", mediaType: "podcast", text: nil, externalReference: nil, status: "ready",
            media: ItemMedia(sourceType: .nativeMediaFile, durationMs: 120_000)
        )
    }

    func writeAudio(_ name: String, bytes: Int = 64) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    /// A real SQLite store, which is also what the coordinator's `store` dependency returns from now on.
    func makeStore() throws -> SQLiteSessionStore {
        let store = try SQLiteSessionStore(path: root.appendingPathComponent("library.sqlite").path)
        spies.store = store
        return store
    }

    func seedPodcastItem(in store: SQLiteSessionStore) throws {
        try store.saveItem(makeItem())
        try seedLayer(in: store)
    }

    /// A podcast layer with one Margin that carries only the sender's clock time, so it has podcast work to place but
    /// asks for no transcript.
    func seedLayer(in store: SQLiteSessionStore, id: String = "layer-1") throws {
        try store.saveImportedCommentaryLayer(ImportedCommentaryLayer(
            id: id, itemId: itemId, packageDigest: "digest-\(id)", packageId: "package-\(id)",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode"),
            importedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceResolutionStatus: .contextOnly, isEnabled: true
        ))
        try store.saveImportedCommentaryInterjection(ImportedCommentaryInterjection(
            id: "margin-\(id)", layerId: id, packageScopedId: "margin-\(id)",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 134_000),
            approvedTranscript: "A thought"
        ))
    }

    /// Schedules a matching pass of the test's own for the item and returns its context. It replaces whatever pass was
    /// running (the request differs from any real one), and runs until it is cancelled.
    func installProbePass(url: URL) async throws -> PodcastPlacementPassCoordinator.Context {
        try await startedContext(of: scheduleProbePass(url: url))
    }

    private func scheduleProbePass(url: URL) throws -> PlacementPassProbe {
        let probe = PlacementPassProbe()
        let request = PodcastPlacementPassCoordinator.Request(
            itemId: itemId, file: try PodcastPlacementFile(url: url), layers: [])
        _ = coordinator.matching.schedule(request) { context in
            await probe.started(context)
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        return probe
    }

    private func startedContext(of probe: PlacementPassProbe) async throws -> PodcastPlacementPassCoordinator.Context {
        for _ in 0..<500 {
            if let context = await probe.context { return context }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PlacementTestFailure()
    }

    /// `resolveAndWait`, with the pass it starts joined and then replaced by a probe pass of the test's own.
    ///
    /// `resolve`'s pass runs on a detached task and needs the main actor to finish, so once `resolveAndWait` returns it
    /// may already have ended, with its `.matching` display, before the test's next line runs; a test that wanted to
    /// join or replace it then found nothing running (#2951, #2952). `resolve` records its "scheduled" diagnostic
    /// right after it schedules the pass with nothing awaited in between, so acting there happens before the pass can
    /// take its first step. `realPass` is the real pass's completion handle, cancelled by the probe.
    func resolveReplacingThePass(url: URL) async throws -> (
        outcome: ImportedPodcastPlacementCoordinator.ResolveOutcome,
        probe: PodcastPlacementPassCoordinator.Context,
        realPass: Task<Void, Never>
    ) {
        let hook = PlacementPassHook()
        spies.onDiagnostic = { [unowned self] key, value in
            guard key == "importedPodcastAnchorResolution:\(self.itemId)", value.hasPrefix("scheduled:") else { return }
            do {
                let submission = self.coordinator.matching.schedule(try self.identicalRequest(url: url)) { _ in }
                // An identical request is kept, not replaced: this must be the pass `resolve` just started.
                guard submission.joined else { throw PlacementTestFailure() }
                hook.realPass = submission.completion
                hook.probe = try self.scheduleProbePass(url: url)
            } catch {
                hook.failure = error
            }
        }
        defer { spies.onDiagnostic = nil }
        let outcome = await coordinator.resolveAndWait(itemId: itemId, localURL: url)
        if let failure = hook.failure { throw failure }
        guard let realPass = hook.realPass, let probe = hook.probe else { throw PlacementTestFailure() }
        return (outcome, try await startedContext(of: probe), realPass)
    }

    /// The request `resolve` makes for the item's current layers.
    private func identicalRequest(url: URL) throws -> PodcastPlacementPassCoordinator.Request {
        guard let store = spies.store else { throw PlacementTestFailure() }
        let layers = try store.loadImportedCommentaryLayers(itemId: itemId)
        let work = ImportedPodcastPlacement.podcastLayerRecords(layers: layers) { layer in
            try? store.loadImportedCommentaryInterjections(layerId: layer.id)
        }
        return PodcastPlacementPassCoordinator.Request(
            itemId: itemId,
            file: try PodcastPlacementFile(url: url),
            layers: work.map { PodcastPlacementPassCoordinator.LayerInput(layer: $0.0, records: $0.1) }
        )
    }

    /// What `passes` holds when exactly this work is displayed for the item and no Margin had an earlier position.
    func expectedPasses(_ works: SharedMarginPlacementPasses.Work...) -> SharedMarginPlacementPasses {
        var passes = SharedMarginPlacementPasses()
        for work in works { passes.begin(work, itemId: itemId) }
        return passes
    }

    /// Waits for the transient transcript to record its last diagnostic (consumed or failed, which come after the slot
    /// is released and the caches are purged), then for the placement request a finished transcript queued. Returns
    /// whether the diagnostic arrived in time.
    func waitForTransientPassToFinish() async throws -> Bool {
        let finished = try await waitUntil {
            guard let last = self.spies.transientDiagnostics(self.itemId).last else { return false }
            return last == "consumed_and_deleted" || last.hasPrefix("failed_and_deleted")
        }
        await coordinator.waitForQueuedResolves()
        return finished
    }

    /// Polls for up to five seconds. The coordinator's tasks run on the main actor, so the condition is read between
    /// their steps and never mid-way through one.
    func waitUntil(_ condition: () -> Bool) async throws -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
