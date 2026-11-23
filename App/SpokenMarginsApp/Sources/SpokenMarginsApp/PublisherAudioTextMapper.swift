import AVFoundation
import Foundation
import Speech
import SessionKit
import SessionKitAudio
import SessionKitFeeds
import SessionKitPersistence

/// Makes the text-to-time map for an article's publisher audio, once per item, after import
/// (#546, slice 2 of #239). It downloads the recording to Caches, transcribes it with the same
/// on-device client as podcast transcripts, lines the transcript up with the article
/// (`PublisherAudioAligner`), deletes the download, and saves the result in the item's
/// `publisher_audio` record. A map is kept only when enough of the article was placed; otherwise
/// the article keeps on-device speech, and the record and diagnostics say why.
///
/// A try that never finished (Speech Recognition not yet allowed, or the app was closed during
/// it) leaves the record without a status, and opening the item tries again.
@MainActor
enum PublisherAudioTextMapper {
    private static var running = Set<String>()

    /// Called with the item id after a map was saved, so an article being read aloud meanwhile can hand over to
    /// the publisher's recording (#2789). Set by the app model whenever the listener opens or starts an item.
    static var mapSaved: (@MainActor (String) -> Void)?

    /// Tries again for an item whose record has no map status yet.
    static func resume(
        itemId: String,
        store: SQLiteSessionStore,
        transcriber: any SourceTranscriptionClient,
        report: @escaping @MainActor (String) -> Void
    ) {
        // Opening an item asks this every time, so the keyed read leaves the main actor (#2506).
        Task {
            guard let audio = try? await StoreReader(store).read({ try $0.loadPublisherAudio(itemId: itemId) }) else { return }
            start(audio, store: store, transcriber: transcriber, report: report)
        }
    }

    static func start(
        _ audio: PublisherAudio,
        store: SQLiteSessionStore,
        transcriber: any SourceTranscriptionClient,
        report: @escaping @MainActor (String) -> Void
    ) {
        guard audio.textMapStatus == nil, !running.contains(audio.itemId) else { return }
        // Never prompt for Speech Recognition from an import: wait until the listener has allowed it.
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            return report("waiting_for_speech_recognition")
        }
        guard let remoteURL = URL(string: audio.audioURL) else {
            return report("skipped: no article text or audio URL")
        }
        // Claimed before the first await, so a second open of the item can't start a second try while the text loads.
        running.insert(audio.itemId)
        Task {
            // The article text can be a whole book: it is read off the main actor (#2506).
            let reader = StoreReader(store)
            let articleText = try? await reader.read { try $0.loadItem(id: audio.itemId).text }
            guard let articleText, !articleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                running.remove(audio.itemId)
                return report("skipped: no article text or audio URL")
            }
            report("transcribing")
            var updated: PublisherAudio
            do {
                let wordCount = PublisherAudioDetector.wordCount(articleText)
                let transcript = try await transcribe(remoteURL, durationMs: audio.durationMs, wordCount: wordCount, transcriber: transcriber)
                let alignment = await Task.detached(priority: .utility) {
                    PublisherAudioAligner.align(articleText: articleText, recognised: transcript)
                }.value
                updated = audio.recordingTextMap(alignment)
            } catch let skip as PublisherAudioMapSkip {
                // Not this article's narration, or too big: a verdict on the recording, so it isn't fetched again (#4640).
                updated = audio.recordingTextMapFailure(skip.status)
            } catch {
                // No connection, or only cellular or Low Data Mode (the download is Wi-Fi only, #4640), is not a verdict
                // on the recording: leave the record without a status, so opening the item tries again.
                if OfflineFailure.isConnectivity(error) || PublisherAudioCappedDownload.isWaitingForWiFi(error) {
                    running.remove(audio.itemId)
                    return report("waiting_for_network")
                }
                updated = audio.recordingTextMapFailure("failed: \(SafeErrorText.describe(error))")
            }
            do {
                // The item may have been deleted meanwhile; its record went with it. A reimport may have replaced
                // the recording meanwhile, so this map (for the old one) is dropped and the new one mapped instead.
                // Read, compare and save run in one closure off the main actor, so nothing slips in between.
                let mapped = updated
                enum Saved: Sendable { case removed, replaced(PublisherAudio), saved(String) }
                let outcome = try await reader.read { store -> Saved in
                    try store.withSessionTransaction {
                        guard let current = try store.loadPublisherAudio(itemId: audio.itemId) else { return .removed }
                        guard current.isSameRecording(as: audio) else { return .replaced(current) }
                        let saved = current.keepingTextMap(of: mapped)
                        try store.savePublisherAudio(saved)
                        return .saved(saved.textMapStatus ?? "unknown")
                    }
                }
                running.remove(audio.itemId)
                switch outcome {
                case .removed: report("item removed")
                case .replaced(let current):
                    report("recording replaced during mapping")
                    start(current, store: store, transcriber: transcriber, report: report)
                case .saved(let status):
                    report(status)
                    mapSaved?(audio.itemId)
                }
            } catch {
                running.remove(audio.itemId)
                report("save failed: \(SafeErrorText.describe(error))")
            }
        }
    }

    private nonisolated static func transcribe(
        _ remoteURL: URL,
        durationMs: Int?,
        wordCount: Int,
        transcriber: any SourceTranscriptionClient
    ) async throws -> TranscriptTimeline {
        let pathExtension = remoteURL.pathExtension.isEmpty ? "mp3" : remoteURL.pathExtension
        let directory = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "PublisherAudioTextMaps", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let localURL = directory.appending(path: "\(UUID().uuidString).\(pathExtension)")
        defer { try? FileManager.default.removeItem(at: localURL) }
        // Wi-Fi only and at most 150 MB, for every source (#4640).
        let byteCount = try await PublisherAudioCappedDownload.download(remoteURL, to: localURL)
        // A file far longer or shorter than the article takes to read is not its narration: it isn't transcribed.
        let seconds = try? await AVURLAsset(url: localURL).load(.duration).seconds
        let fileDurationMs = seconds.flatMap { $0.isFinite && $0 > 0 ? Int($0 * 1_000) : nil }
        if let status = PublisherAudioMapDownload.statusAfterDownload(durationMs: fileDurationMs, byteCount: byteCount, wordCount: wordCount) {
            throw PublisherAudioMapSkip(status: status)
        }
        // The transcriber caches the chunks it cuts from a recording under the id it is given and
        // reuses them. A key per try stops a replacement recording from being transcribed from the
        // old one's chunks; the chunks are removed afterwards.
        let cacheKey = "publisher-audio-\(UUID().uuidString)"
        defer { removeTranscriptionCaches(cacheKey) }
        return try await transcriber.transcribeSourceAudio(url: localURL, itemId: cacheKey, durationMs: durationMs)
    }

    /// Clear each transcriber cache independently, even if another folder cannot be removed.
    private nonisolated static func removeTranscriptionCaches(_ key: String) {
        guard let caches = try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else { return }
        for folder in SourceTranscriptionCaches.Folder.allCases {
            try? SourceTranscriptionCaches.remove(folder, itemId: key, cachesDirectory: caches)
        }
    }
}

/// The mapper's download was refused for its length or size (#4640); `status` is saved on the record.
struct PublisherAudioMapSkip: Error {
    let status: String
}

/// One download of a publisher recording for its text map (#4640): on a session that never uses cellular or Low
/// Data Mode, cancelled once it passes 150 MB or the server says it is bigger, and moved to `destination` when done.
final class PublisherAudioCappedDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int, Error>?
    private var moved: Result<Int, Error>?
    private var cancelledForSize = false

    private init(destination: URL) {
        self.destination = destination
    }

    /// Downloads `url` to `destination` and returns its size in bytes.
    static func download(_ url: URL, to destination: URL) async throws -> Int {
        let delegate = PublisherAudioCappedDownload(destination: destination)
        let session = URLSession(configuration: PublisherAudioMapDownload.configuration(), delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.lock.withLock { delegate.continuation = continuation }
                session.downloadTask(with: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    /// A refusal because only cellular or Low Data Mode was available: the next open on Wi-Fi tries again.
    static func isWaitingForWiFi(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return urlError.networkUnavailableReason == .expensive || urlError.networkUnavailableReason == .constrained
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard PublisherAudioMapDownload.shouldCancel(bytesWritten: totalBytesWritten, expectedBytes: totalBytesExpectedToWrite) else { return }
        lock.withLock { cancelledForSize = true }
        downloadTask.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file at `location` is removed when this returns, so it is moved now.
        let result: Result<Int, Error>
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        if !(200..<300).contains(status) {
            result = .failure(URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(status)"]))
        } else {
            do {
                try FileManager.default.moveItem(at: location, to: destination)
                let size = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.intValue ?? 0
                result = .success(size)
            } catch {
                result = .failure(error)
            }
        }
        lock.withLock { moved = result }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, moved, tooLarge) = lock.withLock { () -> (CheckedContinuation<Int, Error>?, Result<Int, Error>?, Bool) in
            defer { self.continuation = nil }
            return (self.continuation, self.moved, cancelledForSize)
        }
        guard let continuation else { return }
        if tooLarge { return continuation.resume(throwing: PublisherAudioMapSkip(status: PublisherAudioMapDownload.tooLargeStatus)) }
        if let error { return continuation.resume(throwing: error) }
        continuation.resume(with: moved ?? .failure(URLError(.cannotCreateFile)))
    }
}
