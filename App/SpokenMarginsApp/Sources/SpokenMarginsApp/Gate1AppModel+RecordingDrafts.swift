import Foundation
import SessionKit
import SessionKitAudio
import SessionKitPersistence

/// A spoken Margin the app was killed in the middle of (#951). While a Margin records, the engine keeps a small note
/// of its source, place and file. Launch settles each note before anything can record again.
extension Gate1AppModel {
    func makeRecordingDraftJournal() -> RecordingDraftJournal? {
        guard let support = try? applicationSupportDirectory() else { return nil }
        return RecordingDraftJournal(directory: RecordingDraftJournal.standardDirectory(applicationSupport: support))
    }

    /// Stores one Margin for each unsaved recording that still opens, and keeps the rest. It plays nothing and
    /// guesses no place. A failure here leaves the notes where they are for the next launch. Returns what to tell
    /// the listener, or nil when there is nothing to say.
    /// The cut-short marks, pointed at their file the first time anything sets or reads one (#1976).
    func cutShortMarks() -> CutShortMargins {
        if !CutShortMargins.shared.isConfigured, let support = try? applicationSupportDirectory() {
            CutShortMargins.shared.use(fileURL: CutShortMargins.standardFileURL(applicationSupport: support))
        }
        return CutShortMargins.shared
    }

    func reconcileRecordingDrafts(store: SQLiteSessionStore) -> String? {
        let marks = cutShortMarks()
        guard let journal = makeRecordingDraftJournal(), let support = try? applicationSupportDirectory() else { return nil }
        do {
            let reports = try RecordingDraftReconciler(
                journal: journal,
                repository: store,
                applicationSupport: support,
                isDecodable: RecordingDraftProbe.isDecodable,
                onRecovered: { marks.set(.recovered, sessionId: $0, interjectionId: $1) }
            ).reconcile(savedAudioPaths: { try store.allMarginAudioPaths() })
            var recovered = 0
            var unreadable = 0
            for report in reports {
                switch report.outcome {
                case .recovered:
                    recovered += 1
                case .unreadable(let firstTime):
                    if firstTime { unreadable += 1 }
                case .sourceMissing:
                    recordDeveloperDiagnostic("recording.draft_source_missing", ["draft": report.draftId])
                case .alreadySaved, .noRecording, .fileMissing:
                    break
                }
            }
            if recovered > 0 { diagnostics["recordingDraftsRecovered"] = "\(recovered)" }
            if unreadable > 0 {
                diagnostics["recordingDraftsUnrecovered"] = "\(unreadable)"
                recordDeveloperDiagnostic("recording.draft_unrecovered", ["count": "\(unreadable)"])
                return "A Margin you were recording when the app closed could not be recovered. Its recording file is kept."
            }
            if recovered > 0 {
                return "A Margin you were recording when the app closed was recovered. Open it to retry its transcript."
            }
        } catch {
            diagnostics["recordingDraftReconcile"] = "failed:\(error.localizedDescription)"
        }
        return nil
    }
}
