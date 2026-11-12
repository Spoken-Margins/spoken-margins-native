import Foundation
import SessionKit

// Kept out of Gate1AppModel.swift, which may not grow (hot-file ratchet).
extension Gate1AppModel {
    private nonisolated static var applicationSupportForRecordings: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    }

    /// A voice Margin's recording as a plain file on this phone, or nil when it is not there (#3211).
    private nonisolated static func recordingFile(of margin: Interjection) -> URL? {
        guard margin.captureKind != .written, let path = margin.audioPath,
              let url = resolvedInterjectionAudioURL(for: path, applicationSupportDirectory: applicationSupportForRecordings),
              (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeRegular
        else { return nil }
        return url
    }

    /// What "Export this Margin" does for this Margin: straight to the note, ask text or audio, straight to the audio,
    /// or nothing to export. The file check runs off the main actor.
    func marginExportOffer(for margin: Interjection) async -> MarginExportOffer {
        await Task.detached(priority: .userInitiated) {
            MarginExportOffer.offer(
                hasNote: MarginMarkdownShare.hasNote(margin),
                recordingIsOnThisPhone: Self.recordingFile(of: margin) != nil)
        }.value
    }

    /// The Margin's recording and its Markdown note (when it has one) as copies for the share sheet. Nil, after saying
    /// why, when there is nothing to hand over. `recordingLeftOut` on the result says the recording could not be read and
    /// only the words are there. The store reads and the file copies run off the main actor, as for the Markdown export.
    func prepareMarginAudioAndTextExport(for margin: Interjection, itemTitle: String) async -> MarginExportFiles? {
        _ = run { _ in }
        guard let store, let profile = engine?.profile else {
            reportFailure("Margins can't be exported right now.")
            return nil
        }
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<MarginExportFiles, Error> in
            Result {
                try MarginExport.prepare(
                    markdown: try MarginMarkdownShare.file(for: margin, engine: SessionEngine(profile: profile, repository: store)),
                    recording: Self.recordingFile(of: margin),
                    audioBaseName: MarginExport.audioBaseName(itemTitle: itemTitle, margin: margin),
                    into: MarginMarkdownShare.shareDirectory)
            }
        }.value
        switch outcome {
        case .success(let files):
            return files
        case .failure(let error as MarginExportError) where error == .nothingToExport:
            reportFailure("This Margin has no words or recording on this phone to export yet.")
            return nil
        case .failure(let error):
            reportFailure(error)
            return nil
        }
    }
}
