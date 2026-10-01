import Foundation
import Speech
import SessionKit
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

    /// Tries again for an item whose record has no map status yet.
    static func resume(
        itemId: String,
        store: SQLiteSessionStore,
        transcriber: any SourceTranscriptionClient,
        report: @escaping @MainActor (String) -> Void
    ) {
        guard let audio = try? store.loadPublisherAudio(itemId: itemId) else { return }
        start(audio, store: store, transcriber: transcriber, report: report)
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
        guard let articleText = try? store.loadItem(id: audio.itemId).text,
              !articleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let remoteURL = URL(string: audio.audioURL) else {
            return report("skipped: no article text or audio URL")
        }
        report("transcribing")
        running.insert(audio.itemId)
        Task {
            defer { running.remove(audio.itemId) }
            var updated: PublisherAudio
            do {
                let transcript = try await transcribe(
                    remoteURL,
                    itemId: audio.itemId,
                    durationMs: audio.durationMs,
                    transcriber: transcriber
                )
                let alignment = await Task.detached(priority: .utility) {
                    PublisherAudioAligner.align(articleText: articleText, recognised: transcript)
                }.value
                updated = audio.recordingTextMap(alignment)
            } catch {
                updated = audio.recordingTextMapFailure("failed: \(String(describing: error))")
            }
            do {
                // The item may have been deleted meanwhile; its record went with it.
                guard try store.loadPublisherAudio(itemId: audio.itemId) != nil else { return report("item removed") }
                try store.savePublisherAudio(updated)
                report(updated.textMapStatus ?? "unknown")
            } catch {
                report("save failed: \(String(describing: error))")
            }
        }
    }

    private nonisolated static func transcribe(
        _ remoteURL: URL,
        itemId: String,
        durationMs: Int?,
        transcriber: any SourceTranscriptionClient
    ) async throws -> TranscriptTimeline {
        let (downloadedURL, response) = try await URLSession.shared.download(from: remoteURL)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else {
            try? FileManager.default.removeItem(at: downloadedURL)
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(status)"])
        }
        let pathExtension = remoteURL.pathExtension.isEmpty ? "mp3" : remoteURL.pathExtension
        let localURL: URL
        do {
            let directory = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appending(path: "PublisherAudioTextMaps", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            localURL = directory.appending(path: "\(UUID().uuidString).\(pathExtension)")
            try FileManager.default.moveItem(at: downloadedURL, to: localURL)
        } catch {
            try? FileManager.default.removeItem(at: downloadedURL)
            throw error
        }
        defer { try? FileManager.default.removeItem(at: localURL) }
        return try await transcriber.transcribeSourceAudio(url: localURL, itemId: itemId, durationMs: durationMs)
    }
}
