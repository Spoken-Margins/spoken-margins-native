import Foundation

/// Text another app hands to the share extension (#662), such as a whole response shared from the
/// ChatGPT app. The share sheet offers it as ordinary plain text with no file name and no link.
///
/// The share extension doesn't link SessionKit. It compiles this file and
/// `ClipboardIntakeClassifier.swift` directly (project.yml), so this file stays Foundation-only and
/// uses nothing else from SessionKit.
public enum SharedTextIntake {
    /// File name extensions read as a text file when a share names its file.
    public static let textFileExtensions: Set<String> = ["md", "markdown", "txt"]

    /// The plain-text types an app shares a string as. Rich text, HTML, JSON and source code also
    /// conform to `public.text`, but their bytes are markup, so they aren't read as text. UTF-16 text
    /// is left out too: the extension decodes bytes as UTF-8, which would garble it.
    public static let plainTextIdentifiers: Set<String> = [
        "public.text",
        "public.plain-text",
        "public.utf8-plain-text",
    ]

    /// The source address recorded for shared text, which has no address of its own.
    public static let sourceURL = "shared-text://share-sheet"

    public enum Route: Equatable, Sendable {
        /// The text is only a link: import it as a link, as Paste & go does.
        case link(URL)
        /// Anything else: import the text itself as a Library item.
        case text(title: String, body: String)
    }

    /// Whether the share extension should try a text representation it doesn't list among its
    /// preferred identifiers: a named Markdown or text file, or a plain-text string. Before #662 only
    /// named files passed, so a response shared as plain text offered nothing to load.
    public static func acceptsTextRepresentation(identifier: String, suggestedName: String?) -> Bool {
        namesTextFile(suggestedName) || isPlainText(identifier)
    }

    /// Whether the share names a Markdown or text file, which the extension reads as a file.
    public static func namesTextFile(_ suggestedName: String?) -> Bool {
        textFileExtensions.contains(((suggestedName ?? "") as NSString).pathExtension.lowercased())
    }

    /// Whether the identifier is one of the plain-text types a shared string arrives as.
    public static func isPlainText(_ identifier: String) -> Bool {
        plainTextIdentifiers.contains(identifier)
    }

    /// What shared text becomes, decided as Paste & go decides for the clipboard: a lone link is
    /// that link, and anything else is text whose title is its first words. Nil for empty text or
    /// for a link the share extension can't hand off (only https links go to the app).
    public static func route(_ text: String) -> Route? {
        switch ClipboardIntakeClassifier.classify(text) {
        case .link(let url):
            return url.scheme?.lowercased() == "https" ? .link(url) : nil
        case .text(let title, let body):
            return .text(title: title, body: body)
        case .unusable:
            return nil
        }
    }

    /// A Library id of its own for each share. Ids made from the title and source would collide for
    /// two responses that start with the same words, and the second import would replace the first.
    public static func newItemID() -> String {
        "item-shared-text-\(UUID().uuidString.lowercased())"
    }
}
