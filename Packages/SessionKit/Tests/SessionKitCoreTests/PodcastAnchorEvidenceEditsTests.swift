import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// A Margin's anchor-evidence edits run off the main actor, one transaction each (#2509).
final class PodcastAnchorEvidenceEditsTests: XCTestCase {
    private func makeStore() throws -> SQLiteSessionStore {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("anchor-edits-\(UUID().uuidString).sqlite").path
        return try SQLiteSessionStore(path: path)
    }

    private func margin(_ id: String = "m1", item: String = "ep", session: String = "s1") -> Interjection {
        Interjection(
            id: id, itemId: item, sessionId: session, targetType: .item, targetId: item,
            createdAt: Date(timeIntervalSince1970: 1), roughPercent: 10,
            anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 61_000),
            audioPath: "/tmp/m.m4a", audioStatus: "ready", transcriptionStatus: "complete",
            transcript: "kept words", cleanedTranscript: nil, displayText: nil, status: "active"
        )
    }

    private func evidence(_ id: String, role: PodcastAnchorEvidenceWindowRole) -> CapturedPodcastAnchorEvidence {
        CapturedPodcastAnchorEvidence(id: id, localPath: "/tmp/\(id)", durationMs: 8_000, anchorOffsetMs: 4_000,
                                      provenance: .exactLocalPlaybackEdition, windowRole: role)
    }

    private func apply(_ change: PodcastAnchorEvidenceEdits.Change, _ store: SQLiteSessionStore, id: String = "m1", item: String = "ep") throws -> Interjection? {
        try PodcastAnchorEvidenceEdits.apply(change, interjectionId: id, itemId: item, sessionId: "s1", in: store)
    }

    /// Each change saves exactly what the pure record function returns, and leaves the rest of the Margin alone.
    func testEachChangeSavesTheRecordResultAndKeepsOtherFields() throws {
        let store = try makeStore()
        let original = margin()
        try store.saveInterjection(original)

        let pending = try XCTUnwrap(apply(.markPendingLocalCapture, store))
        XCTAssertEqual(pending, PodcastAnchorEvidenceRecord.markingPendingLocalCapture(original))

        let failed = try XCTUnwrap(apply(.recordFailureReason("stream_failed:x"), store))
        XCTAssertEqual(failed.podcastAnchorEvidenceCaptureStatus, .pendingExactLocalCapture, "a failure note keeps the capture status")
        XCTAssertEqual(failed.podcastAnchorEvidenceFailureReason, "stream_failed:x")

        let pieces = [evidence("anchor-pre", role: .preInterjection), evidence("anchor-post", role: .postResume)]
        let merged = try XCTUnwrap(apply(.merge(pieces, sourceExactEditionSHA256: "abc"), store))
        XCTAssertEqual(merged.podcastAnchorEvidenceCaptureStatus, .ready)
        XCTAssertEqual(merged.sourceExactEditionSHA256, "abc")
        XCTAssertEqual(merged.podcastAnchorEvidence?.map(\.id), ["anchor-post", "anchor-pre"])

        let unavailable = try XCTUnwrap(apply(.markUnavailable(reason: "storage_unavailable"), store))
        XCTAssertEqual(unavailable.podcastAnchorEvidenceCaptureStatus, .unavailable)
        XCTAssertEqual(unavailable.podcastAnchorEvidenceFailureReason, "stream_failed:x | storage_unavailable")

        let stored = try XCTUnwrap(store.loadInterjection(id: "m1", sessionId: "s1"))
        XCTAssertEqual(stored, unavailable, "the returned Margin is the saved one")
        XCTAssertEqual(stored.transcript, "kept words")
        XCTAssertEqual(stored.anchor, original.anchor)
        XCTAssertEqual(stored.audioPath, original.audioPath)
    }

    /// No such Margin, or one that belongs to another item: nil, and nothing is written or created.
    func testAMissingOrForeignMarginWritesNothing() throws {
        let store = try makeStore()
        try store.saveInterjection(margin())
        XCTAssertNil(try apply(.markUnavailable(reason: "r"), store, id: "nope"))
        XCTAssertNil(try apply(.markUnavailable(reason: "r"), store, item: "another-episode"))
        XCTAssertNil(try PodcastAnchorEvidenceEdits.apply(.markUnavailable(reason: "r"), interjectionId: "m1", itemId: "ep", sessionId: "other-session", in: store))
        XCTAssertEqual(try store.loadInterjections(sessionId: "s1"), [margin()])
        XCTAssertTrue(try store.loadInterjections(sessionId: "other-session").isEmpty)
    }

    /// Five edits that start at once each read the Margin and save it. In one transaction each, none is lost.
    func testEditsThatStartTogetherAreAllKept() async throws {
        let store = try makeStore()
        try store.saveInterjection(margin())
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<5 {
                group.addTask {
                    _ = try? await StoreReader(store).read { store in
                        try PodcastAnchorEvidenceEdits.apply(
                            .recordFailureReason("reason-\(index)"),
                            interjectionId: "m1", itemId: "ep", sessionId: "s1", in: store
                        )
                    }
                }
            }
        }
        let reasons = try XCTUnwrap(store.loadInterjection(id: "m1", sessionId: "s1")?.podcastAnchorEvidenceFailureReason)
            .components(separatedBy: PodcastAnchorCaptureDiagnostics.reasonSeparator)
        XCTAssertEqual(Set(reasons), Set((0..<5).map { "reason-\($0)" }))
    }

    /// Through `readInOrder`, "pending" asked first can't be overwritten by evidence asked later, however fast it ends.
    func testOrderedEditsLandInTheOrderAsked() async throws {
        let store = try makeStore()
        try store.saveInterjection(margin())
        let reader = StoreReader(store)
        let changes: [PodcastAnchorEvidenceEdits.Change] = [
            .markPendingLocalCapture,
            .merge([evidence("anchor-pre", role: .preInterjection)], sourceExactEditionSHA256: nil),
        ]
        var tasks: [Task<Interjection?, Error>] = []
        for change in changes {
            tasks.append(Task {
                try await reader.readInOrder(PodcastAnchorEvidenceEdits.orderKey) { store in
                    try PodcastAnchorEvidenceEdits.apply(change, interjectionId: "m1", itemId: "ep", sessionId: "s1", in: store)
                }
            })
            try await Task.sleep(nanoseconds: 5_000_000) // the order they were asked in
        }
        for task in tasks { _ = try await task.value }
        XCTAssertEqual(try store.loadInterjection(id: "m1", sessionId: "s1")?.podcastAnchorEvidenceCaptureStatus, .ready)
    }
}
