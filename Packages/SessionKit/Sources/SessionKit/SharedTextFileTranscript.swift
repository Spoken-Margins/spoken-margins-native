import Foundation

/// A `.txt` file the share extension sent as text (#2997, PR 5b).
///
/// The extension reads a shared `.txt` as UTF-8 and hands it off as a `plain_text_file` payload whose source is
/// `shared-file://share-sheet/<percent-encoded file name>`. It can't tell a Zoom or Teams transcript from any other
/// text file, so the app asks when it drains the payload: this names the file, and `TranscriptLibraryImport.importText`
/// decides. Shared text strings (`shared-text://`) and pages never come here.
public enum SharedTextFileTranscript {
    /// What the share extension writes before the file's name (`SourceLinkShareViewController.browserPayloadFromFile`).
    public static let sourcePrefix = "shared-file://share-sheet/"

    /// The shared file's name when `handoff` is a `.txt` file from the share sheet, else nil. Markdown files are not
    /// asked: they keep today's import. A file over `TranscriptImport.maximumBytes` is never sniffed either, as in a
    /// pick from Files, so it keeps today's import.
    public static func fileName(for handoff: BrowserTextHandoff) -> String? {
        guard handoff.captureMode == .plainTextFile, handoff.source.url.hasPrefix(sourcePrefix),
              handoff.text.utf8.count <= TranscriptImport.maximumBytes else { return nil }
        let encoded = String(handoff.source.url.dropFirst(sourcePrefix.count))
        let decoded = encoded.removingPercentEncoding ?? encoded
        let name = (decoded as NSString).lastPathComponent
        return (name as NSString).pathExtension.lowercased() == "txt" ? name : nil
    }
}
