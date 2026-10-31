import Foundation
import SessionKit
import SessionKitAudio

/// #2966: the recording screen's "Just heard" card for a podcast with no transcript. Text items and podcasts with a
/// transcript already hold the words before the anchor (#1491). A podcast without one doesn't until its heard minute
/// is transcribed, which waits for the Margin to finish and a minute of playback after it. So when recording starts,
/// the last few seconds the player decoded before the tap are transcribed on their own, and the card fills in when
/// the words are ready, a second or two later. Nothing waits for it: the recorder starts as before, and a peek that
/// fails or finds no speech leaves the card empty, as it was.
extension Gate1AppModel {
    /// How much audio before the tap is transcribed: about two sentences of speech.
    nonisolated static let justHeardPeekWindowMs = 12_000

    var isMediaPlaybackSnapshot: Bool {
        snapshot.targetType == TargetType.transcriptBackedMedia.rawValue ||
            snapshot.targetType == TargetType.browserOwnedMedia.rawValue
    }

    /// Called once a Margin is recording, from the screen or a compact control.
    func startJustHeardPeek() {
        let ticket = justHeardPeek.begin()
        let source: HeardAudioSource? = (audioPlaybackClientOverride as? HeardAudioSource) ?? mediaPlaybackClient
        guard snapshot.isRecording, isMediaPlaybackSnapshot,
              JustHeardCue.excerpt(from: engine?.recordingContextBefore) == nil, // the anchor already has the words
              let itemId = snapshot.itemId,
              let sessionId = snapshot.sessionId,
              let anchorMs = snapshot.currentMediaTimeMs,
              let reader = source?.heardAudioReader(itemId: itemId) else { return }
        let transcriber = sourceTranscriptionClient
        let root = heardSourceWindows.rootDirectory
        diagnostics["justHeardPeek"] = "started"
        Task { [weak self] in
            let outcome = await Self.transcribeJustHeard(
                reader: reader, transcriber: transcriber, root: root,
                itemId: itemId, sessionId: sessionId, anchorMs: anchorMs
            )
            guard let self else { return }
            self.diagnostics["justHeardPeek"] = outcome.diagnostic
            self.justHeardPeek.deliver(outcome.words, ticket: ticket)
        }
    }

    /// A recording screen's context is gone: the Margin was saved, cancelled, cut short, switched to writing or failed to
    /// start. The words still on their way, or already shown, are for nobody. Every path that ends a recording clears
    /// through here, so a path added later can't leave the last Margin's words behind (Lock Screen and Live Activity
    /// finish, an interruption and the switch to writing did before this).
    func clearRecordingPresentation() {
        marginCapture.clearPresentationContext()
        justHeardPeek.end()
    }

    nonisolated private static func transcribeJustHeard(
        reader: @escaping HeardAudioReader,
        transcriber: SourceTranscriptionClient,
        root: URL,
        itemId: String,
        sessionId: String,
        anchorMs: Int
    ) async -> (words: String?, diagnostic: String) {
        // The reader waits for the tap's queued buffers, and the file write is a few hundred kilobytes: both off main.
        let written = await Task.detached(priority: .userInitiated) { () -> Result<[HeardSourceWindowFiles.Segment], Error>? in
            guard let heard = reader(anchorMs, justHeardPeekWindowMs) else { return nil }
            let window = HeardAudioWindow(
                request: PostResumeAudioSampleRequest(
                    interjectionId: "just-heard-\(UUID().uuidString)", sessionId: sessionId, itemId: itemId,
                    anchorMediaTimeMs: anchorMs, targetDurationMs: justHeardPeekWindowMs
                ),
                sampleRate: heard.sampleRate,
                segments: [heard.segment],
                endReason: "just_heard"
            )
            return Result { try HeardSourceWindowFiles.write(window, in: root) }
        }.value
        guard let written else { return (nil, "no_heard_audio") }
        guard case .success(let files) = written else { return (nil, "write_failed") }
        defer { HeardSourceWindowFiles.deleteInBackground(files) }
        guard let file = files.last else { return (nil, "too_short") }
        // A unique folder per peek: the transcriber reuses an existing export in the same folder.
        let scratchID = "just-heard-\(UUID().uuidString)"
        defer {
            Task.detached(priority: .utility) {
                if let caches = try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
                    try? SourceTranscriptionCaches.remove(.windows, itemId: scratchID, cachesDirectory: caches)
                }
            }
        }
        do {
            let analysis = try await transcriber.transcribeSourceAudioWindowWithEvidence(
                url: file.url, itemId: scratchID, anchorMediaTimeMs: 0, durationMs: file.durationMs,
                windowBeforeMs: 0, windowAfterMs: file.durationMs
            )
            let cue = JustHeardCue.excerpt(from: analysis.timeline.segments.map(\.text).joined(separator: " "))
            return (cue, cue == nil ? "no_speech" : "shown:\(file.durationMs)ms")
        } catch {
            return (nil, "transcription_failed")
        }
    }
}
