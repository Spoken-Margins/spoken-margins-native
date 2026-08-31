import XCTest
@testable import SessionKit

final class WatchCaptureOutboxTests: XCTestCase {
    func testDuplicateEnqueuePreservesOneStableCapture() {
        let event = makeEvent()
        var outbox = WatchCaptureOutbox()

        let first = outbox.enqueue(event, at: date(1))
        let duplicate = outbox.enqueue(event, at: date(2))

        XCTAssertEqual(outbox.records.count, 1)
        XCTAssertEqual(first, duplicate)
        XCTAssertEqual(outbox.record(id: event.id)?.state, .savedLocally)
    }

    func testCaptureRemainsUnacknowledgedUntilIdempotentPhoneAcknowledgement() throws {
        let event = makeEvent()
        var outbox = WatchCaptureOutbox()
        outbox.enqueue(event, at: date(1))

        try outbox.markQueued(eventId: event.id, at: date(2))
        try outbox.markTransferStarted(eventId: event.id, at: date(3))
        try outbox.markAwaitingImport(eventId: event.id, at: date(4))

        XCTAssertEqual(outbox.unacknowledgedRecords.map(\.id), [event.id])
        XCTAssertEqual(outbox.record(id: event.id)?.attemptCount, 1)
        XCTAssertEqual(outbox.record(id: event.id)?.retainsAudio, true)

        try outbox.acknowledge(eventId: event.id, at: date(5))
        let acknowledged = outbox.record(id: event.id)
        try outbox.acknowledge(eventId: event.id, at: date(6))

        XCTAssertEqual(outbox.record(id: event.id), acknowledged)
        XCTAssertEqual(outbox.unacknowledgedRecords, [])
        XCTAssertEqual(acknowledged?.retainsAudio, false)
    }

    func testFailedTransferIsRetryableAndRetainsRecording() throws {
        let event = makeEvent()
        var outbox = WatchCaptureOutbox()
        outbox.enqueue(event, at: date(1))
        try outbox.markQueued(eventId: event.id, at: date(2))
        try outbox.markTransferStarted(eventId: event.id, at: date(3))
        try outbox.markFailed(eventId: event.id, error: "phone_unreachable", at: date(4))

        XCTAssertEqual(outbox.retryableRecords.map(\.id), [event.id])
        XCTAssertEqual(outbox.record(id: event.id)?.retainsAudio, true)

        try outbox.markTransferStarted(eventId: event.id, at: date(5))
        XCTAssertEqual(outbox.record(id: event.id)?.attemptCount, 2)
        XCTAssertNil(outbox.record(id: event.id)?.lastError)
    }

    func testInvalidTransitionCannotSkipDurableQueueState() {
        let event = makeEvent()
        var outbox = WatchCaptureOutbox()
        outbox.enqueue(event, at: date(1))

        XCTAssertThrowsError(try outbox.markAwaitingImport(eventId: event.id, at: date(2))) { error in
            XCTAssertEqual(
                error as? WatchCaptureOutboxError,
                .invalidTransition(
                    eventId: event.id,
                    from: .savedLocally,
                    to: .awaitingImport
                )
            )
        }
    }

    func testOutboxRoundTripPreservesUnsyncedCapture() throws {
        let event = makeEvent()
        var original = WatchCaptureOutbox()
        original.enqueue(event, at: date(1))
        try original.markQueued(eventId: event.id, at: date(2))

        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(WatchCaptureOutbox.self, from: data)

        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.unacknowledgedRecords.map(\.id), [event.id])
    }

    func testAnchorReceiptMustMatchCanonicalSessionItemAndRevision() {
        let receipt = makeEvent().anchorReceipt

        XCTAssertEqual(
            WatchCaptureAnchorValidator.evaluate(
                receipt,
                expectedSessionId: "session-walk-001",
                expectedItemId: "item-podcast-001",
                expectedSourceRevision: "episode-revision-001"
            ),
            .ready
        )
        XCTAssertEqual(
            WatchCaptureAnchorValidator.evaluate(
                receipt,
                expectedSessionId: "other-session",
                expectedItemId: "item-podcast-001",
                expectedSourceRevision: "episode-revision-001"
            ),
            .sessionMismatch
        )
        XCTAssertEqual(
            WatchCaptureAnchorValidator.evaluate(
                receipt,
                expectedSessionId: "session-walk-001",
                expectedItemId: "other-item",
                expectedSourceRevision: "episode-revision-001"
            ),
            .itemMismatch
        )
        XCTAssertEqual(
            WatchCaptureAnchorValidator.evaluate(
                receipt,
                expectedSessionId: "session-walk-001",
                expectedItemId: "item-podcast-001",
                expectedSourceRevision: "different-revision"
            ),
            .sourceRevisionMismatch
        )
        XCTAssertEqual(
            WatchCaptureAnchorValidator.evaluate(
                nil,
                expectedSessionId: "session-walk-001",
                expectedItemId: "item-podcast-001",
                expectedSourceRevision: nil
            ),
            .missingReceipt
        )
    }

    func testImportLedgerAcceptsEventExactlyOnceAndEncodesDeterministically() throws {
        var ledger = WatchCaptureImportLedger(importedEventIds: ["watch-capture-b"])

        XCTAssertTrue(ledger.markImported(eventId: "watch-capture-a"))
        XCTAssertFalse(ledger.markImported(eventId: "watch-capture-a"))
        XCTAssertEqual(ledger.importedEventIds, ["watch-capture-a", "watch-capture-b"])

        let restored = try JSONDecoder().decode(
            WatchCaptureImportLedger.self,
            from: JSONEncoder().encode(ledger)
        )
        XCTAssertEqual(restored, ledger)
    }

    func testUnacknowledgedWatchRecordingIsNotAutomaticallyEvictable() {
        let asset = OwnedOfflineAsset(
            id: "watch-capture-001",
            itemId: "item-podcast-001",
            category: .recording,
            relativePath: "WatchCaptures/watch-capture-001.m4a",
            byteCount: 48_000,
            isReproducible: false,
            protections: [.recording],
            lastAccessedAt: date(1),
            createdAt: date(1)
        )

        XCTAssertFalse(asset.isAutomaticallyEvictable)
        XCTAssertEqual(
            OfflineStoragePlanner.evictionPlan(requiredBytes: 1, assets: [asset]).selectedAssetIds,
            []
        )
    }

    private func makeEvent() -> WatchCaptureEvent {
        WatchCaptureEvent(
            id: "watch-capture-001",
            createdAt: date(1),
            audioFileName: "watch-capture-001.m4a",
            audioDurationMs: 4_800,
            anchorReceipt: WatchCaptureAnchorReceipt(
                sessionId: "session-walk-001",
                itemId: "item-podcast-001",
                targetType: .transcriptBackedMedia,
                targetId: "media-podcast-001",
                sourceRevision: "episode-revision-001",
                snapshotRevision: "snapshot-001",
                mediaTimeMs: 42_000,
                chapterId: "chapter-001",
                transcriptSegmentId: "segment-003",
                playbackRateObserved: 1.25,
                observedAt: date(0)
            )
        )
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }
}
