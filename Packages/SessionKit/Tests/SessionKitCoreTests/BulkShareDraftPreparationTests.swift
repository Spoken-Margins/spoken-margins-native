import Foundation
import XCTest
import SessionKit
import SessionKitSharing

/// #969: one Margin's steps in "Prepare All Included", driven through the real `BulkPreparationRun`, with real files
/// for the recording and the cleaned copy. A step that must wait (the pause analysis, the render) parks on a gate the
/// test opens, so "Cancel lands while the render is out" is exact; waits are on state, with a deadline as a ceiling.
@MainActor
final class BulkShareDraftPreparationTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("bulk-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("recording".utf8).write(to: folder.appendingPathComponent("margin.m4a"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: One Margin, start to end

    func testAMarginWithItsRecordingIsCleanedAndCounted() async throws {
        let host = Host(folder: folder, drafts: [draft("a")])
        let renders = Recorder()
        let preparation = BulkShareDraftPreparation(
            analyze: { _, _ in [pause] },
            render: { _, destination, decisions in
                renders.add(decisions.map(\.id).joined(separator: ","))
                try Data("cleaned".utf8).write(to: destination)
                return 1_234
            },
            discardStaleCopy: { _ in XCTFail("nothing is stale") }
        )
        host.preparation = preparation
        host.run.start(ids: ["a"], host: host)
        try await waitUntil("the run completes") { host.log.contains(.completed) }

        let result = try XCTUnwrap(host.bulkShareDrafts.first)
        XCTAssertEqual(host.log, [.finishedOne(prepared: true), .completed])
        XCTAssertTrue(result.currentEditState.automaticCleanupEnabled)
        XCTAssertEqual(result.editHistoryIndex, 1, "turning cleanup on is one edit the sender can undo")
        XCTAssertEqual(result.acousticPauseDecisions, [pause])
        XCTAssertEqual(result.representationChoice, .cleaned)
        XCTAssertEqual(result.cleanedAudioDurationMs, 1_234)
        let cleaned = try XCTUnwrap(result.cleanedAudioURL)
        XCTAssertEqual(cleaned.lastPathComponent, "cleaned-a.m4a")
        XCTAssertTrue(cleaned.path.hasPrefix(folder.path), "the copy goes in the folder the host gave")
        XCTAssertEqual(try String(contentsOf: cleaned, encoding: .utf8), "cleaned")
        XCTAssertFalse(result.isAnalyzingPauses)
        XCTAssertFalse(result.isPreparingCleanup)
        XCTAssertNil(result.preparationMessage)
        XCTAssertEqual(result.renderGeneration, 1)
        XCTAssertEqual(host.bulkAutomaticallyCleanedDraftIDs, ["a"])
        XCTAssertEqual(renders.values.count, 1)
        XCTAssertTrue(try XCTUnwrap(renders.values.first).contains("acoustic"), "the render gets the pauses the analysis found")
        XCTAssertTrue(host.failures.isEmpty)
    }

    /// Each way one Margin falls back: what the row says, what goes instead, and what the support report keeps.
    /// The reason never reaches the row (#3853).
    func testEachFallbackSaysOneThingOnTheRowAndKeepsItsReasonOffIt() async throws {
        struct Row {
            let name: String
            var recordingGone = false
            var analysisFails = false
            var renderFails = false
            var noStorage = false
            let message: String
            let choice: ShareMarginRepresentationChoice
            let failure: String?
        }
        let gone = ShareCleanupWords.Failure.recordingMissing.message
        let pause = ShareCleanupWords.Failure.pauseAnalysisUnavailable.message
        let voice = ShareCleanupWords.Failure.voiceNotPrepared.message
        let rows = [
            Row(name: "recording gone", recordingGone: true, message: gone, choice: .textOnly, failure: nil),
            Row(name: "pause analysis fails", analysisFails: true, message: pause, choice: .cleaned, failure: "pause_analysis:"),
            Row(name: "render fails", renderFails: true, message: voice, choice: .original, failure: "render:"),
            Row(name: "analysis and render fail", analysisFails: true, renderFails: true,
                message: "\(voice) \(pause)", choice: .original, failure: "render:"),
            Row(name: "no storage", noStorage: true, message: voice, choice: .original, failure: "render_storage_unavailable"),
        ]
        for row in rows {
            var margin = draft("a")
            if row.recordingGone { margin.interjection.audioPath = "gone.m4a" }
            let host = Host(folder: folder, drafts: [margin])
            host.noStorage = row.noStorage
            let analysisFails = row.analysisFails, renderFails = row.renderFails
            host.preparation = BulkShareDraftPreparation(
                analyze: { _, _ in
                    if analysisFails { throw NSError(domain: "secret-reason", code: 7) }
                    return []
                },
                render: { _, destination, _ in
                    if renderFails { throw NSError(domain: "secret-reason", code: 8) }
                    try Data("cleaned".utf8).write(to: destination)
                    return 10
                },
                discardStaleCopy: { _ in XCTFail("nothing is stale") }
            )
            host.run.start(ids: ["a"], host: host)
            try await waitUntil(row.name) { host.log.contains(.completed) }

            let result = try XCTUnwrap(host.bulkShareDrafts.first, row.name)
            XCTAssertEqual(host.log, [.finishedOne(prepared: false), .completed], row.name)
            XCTAssertEqual(result.preparationMessage, row.message, row.name)
            XCTAssertFalse(result.preparationMessage?.contains("secret-reason") ?? false, row.name)
            XCTAssertEqual(result.representationChoice, row.choice, row.name)
            XCTAssertFalse(result.isAnalyzingPauses, row.name)
            XCTAssertFalse(result.isPreparingCleanup, row.name)
            if let failure = row.failure {
                XCTAssertTrue(host.failures.contains { $0.hasPrefix(failure) }, "\(row.name): \(host.failures)")
            } else {
                XCTAssertTrue(host.failures.isEmpty, row.name)
            }
            XCTAssertTrue(host.failureInterjections.allSatisfy { $0 == "a" }, row.name)
        }
    }

    /// A Margin that is no longer in the sheet when its turn comes is a fallback, and nothing else happens.
    func testAMarginThatLeftTheSheetIsAFallback() async throws {
        let host = Host(folder: folder, drafts: [draft("a")])
        host.preparation = BulkShareDraftPreparation(
            analyze: { _, _ in XCTFail("no analysis"); return [] },
            render: { _, _, _ in XCTFail("no render"); return 0 }
        )
        host.run.start(ids: ["missing"], host: host)
        try await waitUntil("the run completes") { host.log.contains(.completed) }
        XCTAssertEqual(host.log, [.finishedOne(prepared: false), .completed])
        XCTAssertTrue(host.bulkAutomaticallyCleanedDraftIDs.isEmpty)
    }

    // MARK: The stale-work rule

    /// Cancel while the cleaned copy is being written: the copy is deleted, the draft never points at it, the
    /// Margin is not counted, and the automatic edit is taken back so the Margin can be prepared again.
    func testCancelDuringTheRenderDeletesTheCopyAndRollsTheMarginBack() async throws {
        let host = Host(folder: folder, drafts: [draft("a")])
        let gate = RenderGate()
        let discarded = Recorder()
        host.preparation = BulkShareDraftPreparation(
            analyze: { _, _ in [] },
            render: { _, destination, _ in
                try Data("cleaned".utf8).write(to: destination)
                await gate.park()
                return 10
            },
            discardStaleCopy: { url in
                discarded.add(url.path)
                try? FileManager.default.removeItem(at: url)
            }
        )
        host.run.start(ids: ["a"], host: host)
        try await waitUntil("the render is out") { await gate.isParked }
        XCTAssertTrue(try XCTUnwrap(host.bulkShareDrafts.first).isPreparingCleanup)

        host.run.invalidateAndCancel()
        BulkShareDraftPreparation.rollBackInFlightDrafts(host: host)
        let rolledBack = try XCTUnwrap(host.bulkShareDrafts.first)
        XCTAssertFalse(rolledBack.isPreparingCleanup)
        XCTAssertFalse(rolledBack.currentEditState.automaticCleanupEnabled, "the automatic edit is taken back at once")
        XCTAssertTrue(BulkShareDraftPreparation.isEligible(rolledBack), "the Margin can be prepared again")

        await gate.open()
        try await waitUntil("the stale copy is deleted") { !discarded.values.isEmpty }
        let copy = try XCTUnwrap(discarded.values.first)
        XCTAssertTrue(copy.hasSuffix("cleaned-a.m4a"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy))
        XCTAssertNil(try XCTUnwrap(host.bulkShareDrafts.first).cleanedAudioURL)
        XCTAssertTrue(host.log.isEmpty, "a cancelled run counts nothing and never completes")
    }

    /// The draft was rendered again on its own (a manual edit) while the bulk copy was out: the bulk copy is stale
    /// even though the run is still live, so it is deleted and the draft keeps what the newer render gives it.
    func testANewerRenderOfTheSameDraftMakesTheBulkCopyStale() async throws {
        let host = Host(folder: folder, drafts: [draft("a")])
        let gate = RenderGate()
        let discarded = Recorder()
        host.preparation = BulkShareDraftPreparation(
            analyze: { _, _ in [] },
            render: { _, destination, _ in
                try Data("cleaned".utf8).write(to: destination)
                await gate.park()
                return 10
            },
            discardStaleCopy: { url in
                discarded.add(url.path)
                try? FileManager.default.removeItem(at: url)
            }
        )
        host.run.start(ids: ["a"], host: host)
        try await waitUntil("the render is out") { await gate.isParked }
        host.bulkShareDrafts[0].renderGeneration += 1

        await gate.open()
        try await waitUntil("the run completes") { host.log.contains(.completed) }
        XCTAssertEqual(host.log, [.finishedOne(prepared: false), .completed])
        XCTAssertEqual(discarded.values.count, 1)
        XCTAssertNil(try XCTUnwrap(host.bulkShareDrafts.first).cleanedAudioURL)
        XCTAssertTrue(try XCTUnwrap(host.bulkShareDrafts.first).isPreparingCleanup,
                      "the newer render owns the busy flag, so the stale one leaves it alone")
    }

    /// Cancel while the pause analysis is out: it can't be stopped, so its result is dropped when it lands, and no
    /// render starts for that Margin.
    func testCancelDuringThePauseAnalysisDropsItsResultAndRendersNothing() async throws {
        let host = Host(folder: folder, drafts: [draft("a")])
        let gate = AnalysisGate()
        defer { gate.open() }
        let renders = Recorder()
        host.preparation = BulkShareDraftPreparation(
            analyze: { _, _ in
                gate.parkUntilOpened()
                return [pause]
            },
            render: { _, _, _ in renders.add("render"); return 10 },
            discardStaleCopy: { _ in XCTFail("no copy was written") }
        )
        host.run.start(ids: ["a"], host: host)
        try await waitUntil("the analysis is out") { gate.isParked }
        XCTAssertTrue(try XCTUnwrap(host.bulkShareDrafts.first).isAnalyzingPauses)

        host.run.invalidateAndCancel()
        BulkShareDraftPreparation.rollBackInFlightDrafts(host: host)
        gate.open()
        try await waitUntil("the late result has come back to the host") { host.returned == ["a"] }

        let result = try XCTUnwrap(host.bulkShareDrafts.first)
        XCTAssertTrue(result.acousticPauseDecisions.isEmpty, "the late analysis is not applied")
        XCTAssertFalse(result.isAnalyzingPauses)
        XCTAssertFalse(result.currentEditState.automaticCleanupEnabled)
        XCTAssertTrue(renders.values.isEmpty)
        XCTAssertTrue(host.log.isEmpty)
    }

    // MARK: Cancel and the switch

    func testRollBackTakesBackOnlyTheAutomaticEditOfMarginsInFlight() {
        var inFlight = draft("a")
        _ = inFlight.recordEdit(hasOriginalAudio: true, renderCleanedAudio: false) { $0.automaticCleanupEnabled = true }
        inFlight.isAnalyzingPauses = true
        var done = draft("b")
        _ = done.recordEdit(hasOriginalAudio: true, renderCleanedAudio: false) { $0.automaticCleanupEnabled = true }
        var manualOnly = draft("c")
        _ = manualOnly.recordEdit(hasOriginalAudio: true, renderCleanedAudio: false) { $0.manuallyDeletedSegmentIds = ["keep"] }
        manualOnly.isPreparingCleanup = true
        let host = Host(folder: folder, drafts: [inFlight, done, manualOnly])

        BulkShareDraftPreparation.rollBackInFlightDrafts(host: host)

        let drafts = host.bulkShareDrafts
        XCTAssertFalse(drafts[0].currentEditState.automaticCleanupEnabled)
        XCTAssertEqual(drafts[0].editHistoryIndex, 0)
        XCTAssertTrue(drafts[0].canRedoEdit, "taken back as an undo, so redo still has it")
        XCTAssertTrue(drafts[1].currentEditState.automaticCleanupEnabled, "a Margin already done keeps its cleanup")
        XCTAssertEqual(drafts[2].currentEditState.manuallyDeletedSegmentIds, ["keep"], "a manual edit is not an automatic one")
        XCTAssertTrue(drafts.allSatisfy { !$0.isAnalyzingPauses && !$0.isPreparingCleanup })
    }

    func testTurningTheSwitchOffTakesCleanupOffEveryMarginTheRunCleaned() {
        var cleaned = draft("a")
        _ = cleaned.recordEdit(hasOriginalAudio: true, renderCleanedAudio: false) { $0.automaticCleanupEnabled = true }
        var byHand = draft("b")
        _ = byHand.recordEdit(hasOriginalAudio: true, renderCleanedAudio: false) { $0.automaticCleanupEnabled = true }
        let host = Host(folder: folder, drafts: [cleaned, byHand])
        host.bulkAutomaticallyCleanedDraftIDs = ["a", "gone"]

        BulkShareDraftPreparation.undoAutomaticCleanup(host: host)

        XCTAssertFalse(host.bulkShareDrafts[0].currentEditState.automaticCleanupEnabled)
        XCTAssertEqual(host.bulkShareDrafts[0].editHistoryIndex, 2, "a new edit, so the sender can undo it")
        XCTAssertTrue(host.bulkShareDrafts[1].currentEditState.automaticCleanupEnabled, "one cleaned by hand stays")
        XCTAssertTrue(host.bulkAutomaticallyCleanedDraftIDs.isEmpty)
    }

    func testEligibility() {
        var excluded = draft("a"); excluded.isIncluded = false
        var noWords = draft("b"); noWords.interjection.alignedTranscript = nil
        var alreadyCleaned = draft("c")
        _ = alreadyCleaned.recordEdit(hasOriginalAudio: true, renderCleanedAudio: false) { $0.automaticCleanupEnabled = true }
        XCTAssertTrue(BulkShareDraftPreparation.isEligible(draft("d")))
        XCTAssertFalse(BulkShareDraftPreparation.isEligible(excluded))
        XCTAssertFalse(BulkShareDraftPreparation.isEligible(noWords))
        XCTAssertFalse(BulkShareDraftPreparation.isEligible(alreadyCleaned))
    }

    // MARK: Helpers

    private func draft(_ id: String) -> ShareInterjectionDraft {
        let text = "um Keep going."
        var interjection = Interjection(
            id: id, itemId: "item", sessionId: "session", targetType: .item, targetId: "item",
            createdAt: Date(timeIntervalSince1970: 1_790_000_000), roughPercent: 10,
            anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0,
                           anchorBefore: "Before", anchorAfter: "After", mediaTimeMs: 1_000),
            audioPath: "margin.m4a", audioStatus: "saved", transcriptionStatus: "complete", transcript: text,
            cleanedTranscript: "Keep going.", displayText: "Display", status: "active"
        )
        interjection.alignedTranscript = AlignedInterjectionTranscript(text: text, segments: [
            .init(id: "filler", text: "um", startMs: 0, endMs: 200),
            .init(id: "keep", text: "Keep", startMs: 300, endMs: 500),
            .init(id: "last", text: "going.", startMs: 1_600, endMs: 2_000)
        ])
        return ShareInterjectionDraft(interjection: interjection, approvedTranscript: text,
                                      representationChoice: .original, anchorBefore: "Before", anchorAfter: "After")
    }

    /// The deadline is only a ceiling for work that never gets there.
    private func waitUntil(
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !(await condition()) {
            if Date() > deadline {
                XCTFail("timed out waiting for \(what)", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}

private let pause = InterjectionCleanupDecision(id: "acoustic", kind: .longPause, startMs: 700, endMs: 1_500)

/// The model's part, as the app plays it: drafts in one array, recordings in a folder.
@MainActor
private final class Host: BulkShareDraftHost, BulkPreparationHost {
    enum Event: Equatable {
        case finishedOne(prepared: Bool)
        case completed
    }

    let folder: URL
    let run = BulkPreparationRun()
    var preparation: BulkShareDraftPreparation?
    var bulkShareDrafts: [ShareInterjectionDraft]
    var bulkAutomaticallyCleanedDraftIDs: Set<String> = []
    var noStorage = false
    private(set) var log: [Event] = []
    private(set) var failures: [String] = []
    private(set) var failureInterjections: [String] = []
    /// The items whose preparation has come back, stale or not.
    private(set) var returned: [String] = []

    init(folder: URL, drafts: [ShareInterjectionDraft]) {
        self.folder = folder
        self.bulkShareDrafts = drafts
    }

    func bulkShareAudioURL(forAudioPath path: String) -> URL? {
        let url = folder.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func bulkShareRevisionFolder() -> URL? {
        guard !noStorage else { return nil }
        let revision = folder.appendingPathComponent("ShareRevisions/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: revision, withIntermediateDirectories: true)
        return revision
    }

    func recordBulkShareCleanupFailure(_ reason: String, for interjection: Interjection) {
        failures.append(reason)
        failureInterjections.append(interjection.id)
    }

    func prepareForBulkRun(itemID: String, ticket: BulkPreparationTicket) async -> Bool {
        guard let preparation else { return false }
        let prepared = await preparation.prepare(itemID, ticket: ticket, host: self)
        returned.append(itemID)
        return prepared
    }

    func bulkRunDidFinishOne(prepared: Bool) { log.append(.finishedOne(prepared: prepared)) }

    func bulkRunDidComplete() { log.append(.completed) }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func add(_ value: String) {
        lock.lock(); stored.append(value); lock.unlock()
    }

    var values: [String] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

/// Holds an async render until the test opens it.
private actor RenderGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    var isParked: Bool { continuation != nil }

    func park() async {
        guard !opened else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

/// Holds the synchronous pause analysis (it runs on a detached task's thread) until the test opens it.
private final class AnalysisGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var parked = false
    private var returned = false

    var isParked: Bool { lock.lock(); defer { lock.unlock() }; return parked }
    var hasReturned: Bool { lock.lock(); defer { lock.unlock() }; return returned }

    func parkUntilOpened() {
        lock.lock(); parked = true; lock.unlock()
        semaphore.wait()
        lock.lock(); returned = true; lock.unlock()
    }

    func open() { semaphore.signal() }
}
