import AVFoundation
import Foundation
import XCTest
import SessionKit
import SessionKitPersistence
@testable import SpokenMarginsApp

private actor PlanningSuspension {
    private var blocked: CheckedContinuation<Void, Never>?
    private var entered = false
    func wait() async {
        entered = true
        await withCheckedContinuation { blocked = $0 }
    }
    func hasEntered() -> Bool { entered && blocked != nil }
    func resume() { blocked?.resume(); blocked = nil }
}

final class PDFReimportLifetimeTests: XCTestCase {
    private weak var lastExerciseStore: SQLiteSessionStore?
    enum Mode: String, Sendable { case noUpgrade, staleAfterUpgrade, staleAfterCleanup, freshAfterUpgrade }
    struct Evidence {
        var pdfId: String
        var otherId: String
        var marginId: String
        var sessionId: String
        var retiredPath: String
        var selected: [String]
        var staleManifestId: String
        var recording: Data
        var otherAudio: Data
        var otherRecording: Data
    }
    private func signature() -> TTSRenderSignature {
        TTSRenderSignature(engine: "supertonic", modelRevision: "3", assetManifestHash: "a", voiceStyleHash: "v", synthesisParametersHash: "p", normalizationVersion: "n", chunkingVersion: "c", digest: "experiment-signature")
    }
    private func writeWAV(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
        buffer.frameLength = 4_410
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for i in 0..<4_410 { samples[i] = Float(sin(Double(i) * 2 * .pi * 440 / 44_100)) * 0.1 }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
    private func addAsset(_ store: SQLiteSessionStore, root: URL, url: URL, id: String, itemId: String, category: OfflineAssetCategory) throws {
        let relative = String(url.path.dropFirst(root.path.count + 1))
        let bytes = try Data(contentsOf: url)
        try store.saveOwnedOfflineAsset(OwnedOfflineAsset(id: id, itemId: itemId, category: category, relativePath: relative, byteCount: Int64(bytes.count), checksumSHA256: SupertonicRenderIdentity.sha256(bytes), isReproducible: category != .recording))
    }

    // Regression for PDF re-import: actual queue comparator and coordinator/ledger boundary, not
    // Gate1AppModel's complete background pass or the speech renderer. It intentionally uses
    // generated PCM WAV input; no model/speech output or physical-device audibility is claimed.
    private func exercise(_ mode: Mode, root: URL) async throws -> Evidence {
        let support = root.appending(path: "Support")
        let prepared = support.appending(path: "PreparedAudio")
        let store = try SQLiteSessionStore(path: root.appending(path: "store.sqlite").path)
        lastExerciseStore = store
        let engine = SessionEngine(profile: RuntimeCapabilityProfile(id: "pdf", displayName: "PDF", capabilities: ["sync": ["canonical_persistence"]]), repository: store)
        let url = "shared-file://share-sheet/Paper.pdf"
        var pdf = try engine.importBrowserTextInBackground(BrowserTextHandoff(captureMode: .markdownFile, source: BrowserTextSource(url: url, title: "Paper"), text: "# Paper\n\n## Methods\n\nWe measured sleep in adults.\nThe effect held across cohorts.", contentFormat: .markdown))
        pdf.createdAt = Date(timeIntervalSince1970: 20)
        try store.saveItem(pdf)
        let oldText = try XCTUnwrap(pdf.text)
        let oldPlan = PreparedChunkPlan.articlePlan(oldText)
        let coordinator = PreparedAudioCoordinator(repository: store, rootDirectory: prepared)
        let ledger = OfflineStorageLedger(repository: store, rootDirectory: support)
        let manifest = try await coordinator.begin(itemId: pdf.id, sourceText: oldText, signature: signature(), plan: oldPlan)
        let input = root.appending(path: "input.wav")
        try writeWAV(input)
        for plan in oldPlan {
            try await coordinator.commit(itemId: pdf.id, signature: signature(), plan: plan, sourceText: oldText, audioURL: input, durationMs: 100)
        }
        let oldManifest = try XCTUnwrap(store.loadPreparedAudioManifest(id: manifest.id))
        let retiredPath = "PreparedAudio/" + (try XCTUnwrap(oldManifest.chunks.first)).relativePath
        for chunk in oldManifest.chunks {
            try addAsset(store, root: support, url: prepared.appending(path: chunk.relativePath), id: chunk.id, itemId: pdf.id, category: .preparedChunk)
        }
        let narration = prepared.appending(path: "assembled.wav")
        try writeWAV(narration)
        let complete = try await coordinator.complete(itemId: pdf.id, signature: signature(), prepared: PreparedTextAudio(normalizedText: oldText, media: ItemMedia(sourceType: .generatedTTSPrerendered, url: narration.absoluteString, durationMs: 100), timeline: TranscriptTimeline(segments: [], chapters: [], durationMs: 100)))
        XCTAssertTrue(complete)
        pdf.media = ItemMedia(sourceType: .generatedTTSPrerendered, url: narration.absoluteString, durationMs: 100)
        try store.saveItem(pdf)
        try addAsset(store, root: support, url: narration, id: "old-narration", itemId: pdf.id, category: .preparedAudio)
        let start = oldText.distance(from: oldText.startIndex, to: try XCTUnwrap(oldText.range(of: "measured sleep")).lowerBound)
        let sessionId = "session-experiment"
        try store.saveSession(Session(id: sessionId, itemId: pdf.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .transcriptBackedMedia, currentTargetId: narration.absoluteString, position: Position(charOffset: start, mediaTimeMs: 10), completionPercent: 20, playbackRate: 1))
        let recordingURL = support.appending(path: "Recordings/margin.wav")
        try writeWAV(recordingURL)
        try addAsset(store, root: support, url: recordingURL, id: "margin-recording", itemId: pdf.id, category: .recording)
        try store.saveInterjection(Interjection(id: "margin-experiment", itemId: pdf.id, sessionId: sessionId, targetType: .item, targetId: pdf.id, createdAt: Date(timeIntervalSince1970: 1), roughPercent: 20, anchor: Anchor(anchorType: .text, startChar: start, endChar: start + "measured sleep".count, anchorBefore: "", anchorAfter: ""), audioPath: recordingURL.path, audioStatus: "available", transcriptionStatus: "complete", transcript: "Observation", cleanedTranscript: nil, displayText: "Margin", status: "active"))
        let other = Item(id: "unrelated", title: "Other", mediaType: "article", text: "Another item is waiting to prepare.", externalReference: nil, status: "ready", createdAt: Date(timeIntervalSince1970: 10))
        try store.saveItem(other)
        let otherAudioURL = support.appending(path: "PodcastAudio/unrelated.wav")
        try writeWAV(otherAudioURL)
        try addAsset(store, root: support, url: otherAudioURL, id: "other-audio", itemId: other.id, category: .podcast)
        let otherRecordingURL = support.appending(path: "Recordings/unrelated.wav")
        try writeWAV(otherRecordingURL)
        try addAsset(store, root: support, url: otherRecordingURL, id: "other-recording", itemId: other.id, category: .recording)
        try store.saveInterjection(Interjection(id: "other-margin", itemId: other.id, sessionId: "other-session", targetType: .item, targetId: other.id, createdAt: Date(timeIntervalSince1970: 1), roughPercent: 0, anchor: Anchor(anchorType: .text, startChar: 0, endChar: 12, anchorBefore: "", anchorAfter: ""), audioPath: otherRecordingURL.path, audioStatus: "available", transcriptionStatus: "complete", transcript: "Unrelated observation", cleanedTranscript: nil, displayText: "Other Margin", status: "active"))
        _ = try await coordinator.begin(itemId: other.id, sourceText: other.text!, signature: signature(), plan: PreparedChunkPlan.articlePlan(other.text!))
        var otherJob = try XCTUnwrap(store.loadAudioPreparationJobs().first { $0.itemId == other.id })
        otherJob.policy = .whileCharging
        otherJob.requestedAt = other.createdAt!
        try store.saveAudioPreparationJob(otherJob)
        let suspension = PlanningSuspension()
        let capturedPDF = pdf
        let sig = signature()
        let enqueue = Task {
            await suspension.wait()
            let text = mode == .freshAfterUpgrade ? try XCTUnwrap(store.loadItem(id: capturedPDF.id).text) : oldText
            let result: PreparedAudioManifest
            do {
                result = try await coordinator.begin(itemId: capturedPDF.id, sourceText: text, signature: sig, plan: PreparedChunkPlan.articlePlan(text))
            } catch PreparedAudioEnqueue.Rejection.staleSource where mode != .noUpgrade {
                // This branch does not admit structured-document narration. A stale or
                // currently ineligible enqueue must leave no preparation records behind.
                return "prepared-\(capturedPDF.id)-\(sig.digest.prefix(16))"
            }
            if result.state != .readyOffline {
                var job = try XCTUnwrap(store.loadAudioPreparationJobs().first { $0.manifestId == result.id })
                job.policy = .whileCharging
                job.requestedAt = capturedPDF.createdAt!
                try store.saveAudioPreparationJob(job)
            }
            return result.id
        }
        while !(await suspension.hasEntered()) { await Task.yield() }
        if mode != .noUpgrade {
            let document = StructuredDocumentBuilder.build(lines: [StructuredDocumentLine(text: "Paper", role: .title, pageIndex: 0), StructuredDocumentLine(text: "J Biol 12 (2020) 1-9", role: .pageHeader, pageIndex: 0), StructuredDocumentLine(text: "Methods", role: .heading, pageIndex: 0, level: 2), StructuredDocumentLine(text: "We measured sleep in adults.", role: .body, pageIndex: 0), StructuredDocumentLine(text: "The effect held across cohorts.", role: .body, pageIndex: 0)], engine: "pdfkit_baseline", version: 2, pageCount: 1)
            let upgraded = try engine.importBrowserTextInBackground(BrowserTextHandoff(captureMode: .markdownFile, source: BrowserTextSource(url: url, title: "Paper"), text: document.text, contentFormat: .plainText), structuredDocument: document)
            XCTAssertEqual(upgraded.id, pdf.id)
            XCTAssertTrue(try store.loadPreparedAudioManifests(itemId: pdf.id).isEmpty)
            XCTAssertNil(try store.loadItem(id: pdf.id).media)
        }
        // Feasible actor scheduling: resumed begin wins before the separate asynchronous ledger
        // cleanup. The store is real; no repository callback fakes the upgrade.
        if mode == .staleAfterCleanup {
            let removedBeforeResume = await ledger.removeRetiredPreparedAudio(itemId: pdf.id)
            XCTAssertGreaterThan(removedBeforeResume, 0)
            print("A1 cleanup-before-resume removed=\(removedBeforeResume)")
        }
        await suspension.resume()
        let staleManifestId = try await enqueue.value
        let removed = await ledger.removeRetiredPreparedAudio(itemId: pdf.id)
        print("A1 mode=\(mode.rawValue) cleanupRemoved=\(removed) pdfManifests=\(try store.loadPreparedAudioManifests(itemId: pdf.id).count)")
        var selected: [String] = []
        // The exact extracted comparator repeatedly selects from the actual stored jobs. This
        // fragment models three passes at commit/ledger boundary; it doesn't claim a full app run.
        for _ in 0..<3 {
            let jobs = try store.loadAudioPreparationJobs().filter { !$0.isCancelled }.sorted { Gate1AppModel.audioPreparationJobPrecedes($0, $1) }
            guard let job = jobs.first else { break }
            let item = try store.loadItem(id: job.itemId)
            let text = try XCTUnwrap(item.text)
            let plan = PreparedChunkPlan.articlePlan(text)
            let before = try XCTUnwrap(store.loadPreparedAudioManifest(id: job.manifestId))
            let done = PreparedAudioCoordinator.completedIndexes(before, plan: plan, sourceText: text, retryingStandInsFor: job)
            guard let next = plan.first(where: { !done.contains($0.index) }) else { try store.deleteAudioPreparationJob(id: job.id); continue }
            selected.append(item.id)
            let reservation = try await ledger.reserve(ownerId: "pass", byteCount: 1_000_000)
            try await coordinator.commit(itemId: item.id, signature: sig, plan: next, sourceText: text, audioURL: input, durationMs: 100)
            let after = try XCTUnwrap(store.loadPreparedAudioManifest(id: job.manifestId))
            if let chunk = after.chunks.first(where: { $0.index == next.index }) {
                try await ledger.commit(reservationId: reservation.id, asset: OwnedOfflineAsset(id: chunk.id, itemId: item.id, category: .preparedChunk, relativePath: "PreparedAudio/" + chunk.relativePath, byteCount: chunk.byteCount, checksumSHA256: chunk.checksumSHA256, isReproducible: true))
                if PreparedAudioCoordinator.isPrepared(plan, in: after, sourceText: text) { try store.deleteAudioPreparationJob(id: job.id) }
            } else { try await ledger.release(reservationId: reservation.id) }
        }
        print("A1 mode=\(mode.rawValue) selected=\(selected) jobs=\(try store.loadAudioPreparationJobs().map(\.itemId))")
        return Evidence(pdfId: pdf.id, otherId: other.id, marginId: "margin-experiment", sessionId: sessionId, retiredPath: retiredPath, selected: selected, staleManifestId: staleManifestId, recording: try Data(contentsOf: recordingURL), otherAudio: try Data(contentsOf: otherAudioURL), otherRecording: try Data(contentsOf: otherRecordingURL))
    }

    private func run(_ mode: Mode) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "pdf-lifetime-\(mode.rawValue)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await exercise(mode, root: root)
        // exercise returned and released every engine/store/coordinator/ledger before reopening.
        XCTAssertNil(lastExerciseStore, "The first SQLite connection must close before reopening")
        let reopened = try SQLiteSessionStore(path: root.appending(path: "store.sqlite").path)
        let support = root.appending(path: "Support")
        let item = try reopened.loadItem(id: result.pdfId)
        let margin = try XCTUnwrap(reopened.loadInterjections(sessionId: result.sessionId).first)
        XCTAssertEqual(margin.id, result.marginId)
        XCTAssertEqual(String(Array(item.text!)[margin.anchor.startChar..<margin.anchor.endChar]), "measured sleep")
        XCTAssertEqual(try Data(contentsOf: support.appending(path: "Recordings/margin.wav")), result.recording)
        XCTAssertEqual(try Data(contentsOf: support.appending(path: "PodcastAudio/unrelated.wav")), result.otherAudio)
        XCTAssertEqual(try Data(contentsOf: support.appending(path: "Recordings/unrelated.wav")), result.otherRecording)
        XCTAssertEqual(try reopened.loadInterjections(sessionId: "other-session").first?.audioPath, support.appending(path: "Recordings/unrelated.wav").path)
        for path in ["Recordings/margin.wav", "PodcastAudio/unrelated.wav", "Recordings/unrelated.wav"] {
            XCTAssertEqual(try AVAudioFile(forReading: support.appending(path: path)).length, 4_410)
        }
        let assets = try reopened.loadOwnedOfflineAssets()
        XCTAssertTrue(assets.allSatisfy { FileManager.default.fileExists(atPath: support.appending(path: $0.relativePath).path) }, "No ledger row may name a deleted file")
        XCTAssertTrue(try reopened.loadOfflineStorageReservations().isEmpty)
        if mode != .noUpgrade {
            XCTAssertNil(item.media)
            let stale = try reopened.loadPreparedAudioManifest(id: result.staleManifestId)
            print("A1 reopen staleManifestState=\(String(describing: stale?.state)) chunks=\(stale?.chunks.count ?? -1) ledgerRows=\(assets.count) retiredExists=\(FileManager.default.fileExists(atPath: support.appending(path: result.retiredPath).path))")
            XCTAssertNil(stale, "Old-text enqueue must not recreate a retired manifest after upgrade")
            XCTAssertFalse(try reopened.loadAudioPreparationJobs().contains { $0.itemId == result.pdfId }, "Retired preparation must not persist an unproductive queued job")
            if mode == .staleAfterUpgrade {
                XCTAssertFalse(FileManager.default.fileExists(atPath: support.appending(path: result.retiredPath).path), "Async cleanup must remove retired audio")
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: support.appending(path: result.retiredPath).path), "Retired audio was removed before stale resume")
            }
        }
        let otherManifest = try XCTUnwrap(reopened.loadPreparedAudioManifests(itemId: result.otherId).first)
        XCTAssertGreaterThan(otherManifest.committedChunkCount, 0, "The unrelated queued item must progress")
    }
    func testNoUpgradeNegativeControl() async throws { try await run(.noUpgrade) }
    func testCurrentStructuredTextIsRejectedWithoutBlockingOtherPreparation() async throws { try await run(.freshAfterUpgrade) }
    func testStaleEnqueueAfterLedgerCleanupAndRealStoreReopen() async throws { try await run(.staleAfterCleanup) }
    func testStaleEnqueueAcrossUpgradeAndRealStoreReopen() async throws { try await run(.staleAfterUpgrade) }
}
