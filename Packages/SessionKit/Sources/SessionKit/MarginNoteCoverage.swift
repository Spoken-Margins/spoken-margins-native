import Foundation

/// What Settings tells a listener about which Margins leave the app as notes (#5034). The words live next to the
/// rules they describe, so a host test can hold them to `SessionExportMarkdownRenderer.writesMarginNote` (the
/// notes folder) and `ReadwiseHighlight(export:createdAt:)` (Readwise). Settings and the first-run "My notes"
/// step (#4672) read the same sentences.
public enum MarginNoteCoverage {
    /// The first sentences of the Notes Folder footer. Every spoken Margin gets a note, even before its transcript
    /// arrives (#171); a written Margin gets one when it has words.
    public static let notesFolderLead = "Writes each Margin, spoken or written, as a Markdown note in a folder you choose, such as an Obsidian vault. A spoken Margin’s note gets its words once it’s transcribed."

    /// The first words of the Readwise footer. A Margin is sent once it has words, so a spoken Margin goes when its
    /// transcript arrives and never as an empty note.
    public static let readwiseLead = "Each Margin, spoken or written, becomes a Readwise highlight once it has words"

    /// A spoken Margin always gets a note, even before or without a transcript (#171); a written one needs words.
    public static func writesNotesFolderNote(captureKind: InterjectionCaptureKind?, text: String?) -> Bool {
        SessionExportMarkdownRenderer.writesMarginNote(captureKind: captureKind, text: text)
    }

    /// Readwise gets a Margin once it has words, spoken or written.
    public static func sendsReadwiseHighlight(text: String?) -> Bool {
        ReadwiseHighlight.hasWords(text)
    }
}
