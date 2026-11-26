import Foundation

/// The line under Source Text on the Export screen for a spoken note (#4782): what the file holds of the note's words
/// when they are not all there. Nil when every recording has words, with Source Text off, and before a preview exists
/// ("No export yet." already covers loading).
public enum SpokenNoteExportFootnote {
    public static let noWords = "This note has no words written down yet."
    public static let unreadable = "This note's words couldn't be read."
    public static let fromLastPlayback = "Some of this note's details couldn't be read. The file has the words from its last playback."

    public static func someMissing(_ missing: Int, of total: Int) -> String {
        "\(missing) of \(total) recordings \(missing == 1 ? "has" : "have") no words yet. The file says which."
    }

    /// - Parameters:
    ///   - transcript: the note's transcript in the export being previewed; nil when there is none (not a note, or no
    ///     preview yet).
    ///   - includesText: the note's Source Text switch.
    public static func text(for transcript: ExportNoteTranscript?, includesText: Bool) -> String? {
        guard includesText, let transcript else { return nil }
        if transcript.isFallback {
            let hasWords = transcript.recordings?.contains { $0.hasWords && !$0.sentences.isEmpty } ?? false
            return hasWords ? fromLastPlayback : unreadable
        }
        let total = transcript.recordingCount ?? 0
        let withWords = transcript.recordingsWithWords ?? 0
        if withWords == 0 { return noWords }
        if withWords < total { return someMissing(total - withWords, of: total) }
        return nil
    }
}
