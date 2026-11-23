import Foundation

/// Which Margins reach the listener's notes folder and Readwise, and the sentences Settings uses to say so (#5034).
/// The rules are the writers' own, so a footer cannot drift from what is written.
public enum MarginNoteCoverage {
    /// A spoken Margin always gets a note, even before or without a transcript (#171); a written one needs words.
    public static func writesNotesFolderNote(captureKind: InterjectionCaptureKind?, text: String?) -> Bool {
        SessionExportMarkdownRenderer.writesMarginNote(captureKind: captureKind, text: text)
    }

    /// Readwise gets a Margin once it has words, spoken or written (`ReadwiseHighlightClient.init(export:createdAt:)`).
    public static func sendsReadwiseHighlight(text: String?) -> Bool {
        ReadwiseHighlight.hasWords(text)
    }

    public static let notesFolderSentence =
        "Writes each Margin, spoken or written, as a Markdown note in a folder you choose, such as an Obsidian vault. A spoken Margin\u{2019}s note gets its words once it\u{2019}s transcribed."

    public static let readwiseSentence =
        "Each Margin, spoken or written, becomes a Readwise highlight once it has words:"
}
