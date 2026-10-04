import Foundation
import XCTest
@testable import SessionKit

/// The Watch's durable Margin outbox and the phone's inbox, on real temporary folders (#788).
final class WatchMarginOutboxTests: XCTestCase {
    private var root: URL!
    private let recordedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private let anchor = WatchCaptureAnchorOutcome.anchored(WatchCaptureAnchor(
        source: WatchCaptureSource(itemId: "episode-1", revision: "r1"),
        positionMs: 61_000,
        precision: .exact
    ))

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("WatchMarginOutboxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var watchFolder: URL { root.appendingPathComponent("watch-outbox", isDirectory: true) }
    private var phoneFolder: URL { root.appendingPathComponent("phone-inbox", isDirectory: true) }

    /// A stand-in recording: real bytes in a real file, as the Watch recorder leaves them.
    private func recording(_ name: String = "rec", bytes: Int = 48_000) throws -> URL {
        let url = root.appendingPathComponent("\(name).m4a")
        let data = Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        try data.write(to: url)
        return url
    }

    /// What WatchConnectivity hands the phone: a copy of the file in its own inbox folder.
    private func deliveredCopy(of url: URL, keepingBytes: Int? = nil) throws -> URL {
        var data = try Data(contentsOf: url)
        if let keepingBytes { data = data.prefix(keepingBytes) }
        let copy = root.appendingPathComponent("wc-inbox-\(UUID().uuidString).m4a")
        try data.write(to: copy)
        return copy
    }

    func testSaveIsOnDiskWhenItReturnsAndSurvivesARestart() throws {
        let source = try recording()
        let outbox = try WatchMarginOutbox(directory: watchFolder)
        let saved = try outbox.save(captureId: "cap-1", recording: source, durationMs: 3_000, recordedAt: recordedAt, anchor: anchor)
        XCTAssertEqual(saved.state, .saved)
        XCTAssertEqual(saved.metadata.byteCount, 48_000)

        // The recorder's temporary file goes away; the outbox's copy must not.
        try FileManager.default.removeItem(at: source)
        let reopened = try WatchMarginOutbox(directory: watchFolder)
        XCTAssertEqual(reopened.entry("cap-1"), saved)
        XCTAssertEqual(reopened.undelivered.map(\.captureId), ["cap-1"])
        let (audio, metadata) = try reopened.beginTransfer("cap-1")
        XCTAssertEqual(try Data(contentsOf: audio).count, 48_000)
        XCTAssertEqual(metadata.anchor, anchor)
    }

    func testACrashMidSaveLeavesNoHalfCaptureAndIsCleanedOnOpen() throws {
        _ = try WatchMarginOutbox(directory: watchFolder)
        // What a crash between copying the audio and the rename leaves behind.
        let staging = watchFolder.appendingPathComponent(".staging-cap-9-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: staging.appendingPathComponent("audio.m4a"))
        let crashTime = Date().addingTimeInterval(-120)
        try FileManager.default.setAttributes([.modificationDate: crashTime], ofItemAtPath: staging.path)

        let reopened = try WatchMarginOutbox(directory: watchFolder)
        XCTAssertNil(reopened.entry("cap-9"))
        XCTAssertTrue(reopened.undelivered.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testAnUnreachablePhoneKeepsTheMarginForRetriesAcrossRestarts() throws {
        let outbox = try WatchMarginOutbox(directory: watchFolder)
        try outbox.save(captureId: "cap-1", recording: try recording(), durationMs: 3_000, recordedAt: recordedAt, anchor: nil)
        for attempt in 1...3 {
            _ = try outbox.beginTransfer("cap-1")
            try outbox.transferFailed("cap-1", error: "phone_unreachable")
            XCTAssertEqual(outbox.entry("cap-1")?.transferAttempts, attempt)
        }
        let reopened = try WatchMarginOutbox(directory: watchFolder)
        XCTAssertEqual(reopened.entry("cap-1")?.state, .saved)
        XCTAssertEqual(reopened.entry("cap-1")?.lastError, "phone_unreachable")
        XCTAssertEqual(reopened.undelivered.count, 1)
        // A transfer still queued by WatchConnectivity when the Watch restarted stays undelivered too.
        _ = try reopened.beginTransfer("cap-1")
        XCTAssertEqual(try WatchMarginOutbox(directory: watchFolder).undelivered.map(\.state), [.transferring])
    }

    func testAPartialTransferIsRejectedAndTheRetryDelivers() throws {
        let outbox = try WatchMarginOutbox(directory: watchFolder)
        let inbox = try WatchMarginInbox(directory: phoneFolder)
        try outbox.save(captureId: "cap-1", recording: try recording(), durationMs: 3_000, recordedAt: recordedAt, anchor: anchor)

        let (audio, metadata) = try outbox.beginTransfer("cap-1")
        let cutShort = try inbox.receive(file: try deliveredCopy(of: audio, keepingBytes: 20_000), metadata: metadata)
        XCTAssertEqual(cutShort.status, .incomplete)
        XCTAssertNil(inbox.entry("cap-1"))
        XCTAssertFalse(try outbox.apply(cutShort))
        XCTAssertEqual(outbox.entry("cap-1")?.state, .saved)

        var corrupted = try Data(contentsOf: audio)
        corrupted[100] ^= 0xFF
        let corruptedURL = root.appendingPathComponent("corrupted.m4a")
        try corrupted.write(to: corruptedURL)
        XCTAssertEqual(try inbox.receive(file: corruptedURL, metadata: metadata).status, .checksumMismatch)
        XCTAssertNil(inbox.entry("cap-1"))

        let (retryAudio, retryMetadata) = try outbox.beginTransfer("cap-1")
        let receipt = try inbox.receive(file: try deliveredCopy(of: retryAudio), metadata: retryMetadata)
        XCTAssertEqual(receipt.status, .stored)
        XCTAssertTrue(try outbox.apply(receipt))
        XCTAssertEqual(outbox.entry("cap-1")?.state, .delivered)
        XCTAssertEqual(outbox.entry("cap-1")?.transferAttempts, 2)
        XCTAssertTrue(outbox.undelivered.isEmpty)
        XCTAssertEqual(inbox.entry("cap-1")?.metadata.anchor, anchor)
    }

    func testDuplicateDeliveryImportsOneMargin() throws {
        let outbox = try WatchMarginOutbox(directory: watchFolder)
        try outbox.save(captureId: "cap-1", recording: try recording(), durationMs: 3_000, recordedAt: recordedAt, anchor: anchor)
        let (audio, metadata) = try outbox.beginTransfer("cap-1")

        let inbox = try WatchMarginInbox(directory: phoneFolder)
        XCTAssertEqual(try inbox.receive(file: try deliveredCopy(of: audio), metadata: metadata).status, .stored)
        // The Watch never got the receipt and sent it again; it also arrives after a phone restart.
        XCTAssertEqual(try inbox.receive(file: try deliveredCopy(of: audio), metadata: metadata).status, .duplicate)
        let restarted = try WatchMarginInbox(directory: phoneFolder)
        let again = try restarted.receive(file: try deliveredCopy(of: audio), metadata: metadata)
        XCTAssertEqual(again.status, .duplicate)
        XCTAssertEqual(restarted.needingTranscription.map(\.captureId), ["cap-1"])

        XCTAssertTrue(try restarted.markIncorporated("cap-1"))
        XCTAssertFalse(try restarted.markIncorporated("cap-1"), "a second Margin is never made")
        XCTAssertEqual(try restarted.receive(file: try deliveredCopy(of: audio), metadata: metadata).status, .duplicate)
        XCTAssertTrue(restarted.needingTranscription.isEmpty)
        XCTAssertEqual(try WatchMarginInbox(directory: phoneFolder).entry("cap-1")?.marginId, "watch-margin-cap-1")

        // A duplicate receipt still confirms delivery to the Watch.
        XCTAssertTrue(try outbox.apply(again))
    }

    func testUnsyncedAudioCannotBeEvicted() throws {
        let outbox = try WatchMarginOutbox(directory: watchFolder)
        try outbox.save(captureId: "cap-1", recording: try recording(), durationMs: 3_000, recordedAt: recordedAt, anchor: anchor)
        XCTAssertThrowsError(try outbox.evict("cap-1")) { error in
            XCTAssertEqual(error as? WatchMarginStoreError, .unsyncedAudio("cap-1"))
        }
        _ = try outbox.beginTransfer("cap-1")
        XCTAssertThrowsError(try outbox.evict("cap-1"))
        // A receipt for different bytes doesn't count either.
        XCTAssertFalse(try outbox.apply(WatchMarginReceipt(captureId: "cap-1", sha256: "not-these-bytes", status: .stored)))
        XCTAssertThrowsError(try outbox.evict("cap-1"))
        XCTAssertNotNil(try WatchMarginOutbox(directory: watchFolder).entry("cap-1"))

        let sha = try XCTUnwrap(outbox.entry("cap-1")?.metadata.sha256)
        XCTAssertTrue(try outbox.apply(WatchMarginReceipt(captureId: "cap-1", sha256: sha, status: .stored)))
        try outbox.evict("cap-1")
        XCTAssertNil(try WatchMarginOutbox(directory: watchFolder).entry("cap-1"))
    }

    func testFailedTranscriptionKeepsTheOriginalAudioForARetry() throws {
        let outbox = try WatchMarginOutbox(directory: watchFolder)
        try outbox.save(captureId: "cap-1", recording: try recording(), durationMs: 3_000, recordedAt: recordedAt, anchor: anchor)
        let (audio, metadata) = try outbox.beginTransfer("cap-1")
        let inbox = try WatchMarginInbox(directory: phoneFolder)
        let copy = try deliveredCopy(of: audio)
        _ = try inbox.receive(file: copy, metadata: metadata)
        // WatchConnectivity deletes its inbox copy once the delegate returns.
        try FileManager.default.removeItem(at: copy)

        try inbox.markTranscriptionFailed("cap-1", reason: "speech_recognizer_unavailable")
        let restarted = try WatchMarginInbox(directory: phoneFolder)
        XCTAssertEqual(restarted.entry("cap-1")?.state, .transcriptionFailed)
        XCTAssertEqual(restarted.needingTranscription.map(\.captureId), ["cap-1"])
        let stored = try XCTUnwrap(restarted.audioURL("cap-1"))
        XCTAssertEqual(try Data(contentsOf: stored), try Data(contentsOf: audio))

        XCTAssertTrue(try restarted.markIncorporated("cap-1"))
        XCTAssertEqual(restarted.entry("cap-1")?.transcriptionAttempts, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.path), "the original stays after incorporation too")
    }

    func testAStopBetweenSavingTheMarginAndMarkingItReusesTheSameMarginId() throws {
        let outbox = try WatchMarginOutbox(directory: watchFolder)
        try outbox.save(captureId: "cap-1", recording: try recording(), durationMs: 3_000, recordedAt: recordedAt, anchor: anchor)
        let (audio, metadata) = try outbox.beginTransfer("cap-1")
        let inbox = try WatchMarginInbox(directory: phoneFolder)
        _ = try inbox.receive(file: try deliveredCopy(of: audio), metadata: metadata)
        let firstTry = try XCTUnwrap(inbox.entry("cap-1")?.marginIdToUse)
        // The phone saved the Margin under firstTry, then stopped before markIncorporated.
        let restarted = try WatchMarginInbox(directory: phoneFolder)
        XCTAssertEqual(restarted.needingTranscription.map(\.marginIdToUse), [firstTry], "the retry saves over the same Margin")
    }

    func testAnotherStoreOpeningTheFolderLeavesARecentSaveInProgressAlone() throws {
        _ = try WatchMarginOutbox(directory: watchFolder)
        let inProgress = watchFolder.appendingPathComponent(".staging-cap-5-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: inProgress, withIntermediateDirectories: true)
        _ = try WatchMarginOutbox(directory: watchFolder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: inProgress.path))
    }

    func testSavingTheSameCaptureTwiceKeepsTheFirstRecording() throws {
        let outbox = try WatchMarginOutbox(directory: watchFolder)
        let first = try outbox.save(captureId: "cap-1", recording: try recording("a", bytes: 1_000), durationMs: 1_000, recordedAt: recordedAt, anchor: anchor)
        let second = try outbox.save(captureId: "cap-1", recording: try recording("b", bytes: 2_000), durationMs: 2_000, recordedAt: recordedAt, anchor: nil)
        XCTAssertEqual(second, first)
        XCTAssertEqual(try WatchMarginOutbox(directory: watchFolder).entry("cap-1")?.metadata.byteCount, 1_000)
    }

    func testTheAnchorCanArriveAfterTheSave() throws {
        let outbox = try WatchMarginOutbox(directory: watchFolder)
        try outbox.save(captureId: "cap-1", recording: try recording(), durationMs: 3_000, recordedAt: recordedAt, anchor: nil)
        try outbox.setAnchor(anchor, for: "cap-1")
        XCTAssertEqual(try WatchMarginOutbox(directory: watchFolder).entry("cap-1")?.metadata.anchor, anchor)
    }

    func testCaptureIdsThatCouldEscapeTheFolderAreRefused() throws {
        let outbox = try WatchMarginOutbox(directory: watchFolder)
        let inbox = try WatchMarginInbox(directory: phoneFolder)
        let file = try recording()
        for bad in ["", "../escape", "a/b", ".hidden", "naïve"] {
            XCTAssertThrowsError(try outbox.save(captureId: bad, recording: file, durationMs: 1, recordedAt: recordedAt, anchor: nil), bad)
            let metadata = WatchMarginTransferMetadata(captureId: bad, audioFileExtension: "m4a", byteCount: 1, sha256: "x", durationMs: 1, recordedAt: recordedAt, anchor: nil)
            XCTAssertThrowsError(try inbox.receive(file: file, metadata: metadata), bad)
        }
        let sneaky = WatchMarginTransferMetadata(captureId: "cap-1", audioFileExtension: "/../../escape", byteCount: 1, sha256: "x", durationMs: 1, recordedAt: recordedAt, anchor: nil)
        XCTAssertThrowsError(try inbox.receive(file: file, metadata: sneaky))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escape").path))
    }
}
