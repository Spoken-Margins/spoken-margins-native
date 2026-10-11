import Foundation

/// #942: a saved voice Margin says "Transcribing…" only while this process is really transcribing it.
///
/// The stored `transcriptionStatus` "pending" is written when a recording is saved, but the work
/// behind it is an in-memory task. Nothing resumes that task after the app is killed, so on the next
/// launch a "pending" row has no worker and would say "pending" forever. At launch no transcription
/// of this process can be running yet, so every voice Margin still "pending" is an orphan. It is
/// settled as "failed", which Build 29 already reads and which the app words as a retry, and which
/// offers Retry (`ExperienceModels.canRetryTranscription`). The recording and anything already
/// transcribed are untouched.
public enum OrphanedTranscription {
    /// The Margin as it should be stored, or nil when it is not an orphan: not pending, deleted, written
    /// (nothing to transcribe) or without a recording (Retry would have nothing to read).
    public static func settled(_ margin: Interjection) -> Interjection? {
        guard margin.transcriptionStatus == "pending",
              margin.status != "deleted",
              margin.captureKind != .written,
              margin.audioPath != nil else { return nil }
        var settled = margin
        settled.transcriptionStatus = "failed"
        return settled
    }
}
