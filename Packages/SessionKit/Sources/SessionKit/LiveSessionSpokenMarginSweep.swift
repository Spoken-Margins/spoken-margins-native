import Foundation

/// Gives words to every spoken Margin in an unsaved live session that has none yet (#2487, #4715). A live-session, Watch
/// or Shortcut Margin whose transcription met the Speech Recognition hold is saved with no words; this is how it gets
/// them after Allow (`HeldTranscription.Retry.liveSessionSweep`), and how a session screen catches up on open.
public enum LiveSessionSpokenMarginSweep {
    /// Transcribes each waiting Margin in turn with `transcribe` (nil: no words, it stays waiting) and files the words in.
    /// Returns the ids of the Margins that got words. The file work runs on `files`' actor, never on the main thread.
    @discardableResult
    public static func fillMissingWords(
        files: LiveSessionFileWorker, transcribe: @Sendable (_ audioPath: String) async -> String?
    ) async -> [String] {
        var filled: [String] = []
        for margin in await files.spokenWithoutWords() {
            guard let text = await transcribe(margin.audioPath) else { continue }
            let id = margin.marginId
            if await files.update(marginId: id, { $0.setTranscript(text, forMarginId: id) }) != nil { filled.append(id) }
        }
        return filled
    }
}
