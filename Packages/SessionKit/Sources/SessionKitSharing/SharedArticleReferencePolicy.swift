import Foundation
import SessionKit

/// When a packet's item is a web article the recipient doesn't have, the app can fetch it from the packet's
/// link (#916). Only an article qualifies: a podcast has its own acquisition, and a PDF or EPUB link isn't a page.
public enum SharedArticleReferencePolicy {
    /// The HTTPS page to read, or nil when the item isn't an article with a usable link.
    public static func articleURL(for item: SharedItemIdentity) -> URL? {
        guard item.itemType == .text,
              let normalized = SharedItemIdentityBuilder.normalizedSharingURL(item.canonicalURL),
              let url = URL(string: normalized),
              url.host?.isEmpty == false else { return nil }
        return url
    }

    /// Whether the page the reader landed on is the packet's article. A redirect to a consent wall, a sign-in
    /// page or another site returns text with no error, and Margins attached to it would never play (#916).
    /// The page is judged the way the import will judge it afterwards: as the item the import would store (its
    /// cleaned text and the address it would keep), through `ImportedItemResolver.canRepresentSameWork`. A
    /// separate rule here let a page through that the import then marked as the wrong source (#1259).
    /// `fetchedText` is what the import is handed, after the app's HTML stripping.
    public static func fetchedPageIsTheSharedArticle(
        _ item: SharedItemIdentity,
        fetchedURL: String,
        fetchedText: String,
        contentFormat: BrowserTextContentFormat?
    ) -> Bool {
        guard let imported = importedIdentity(fetchedURL: fetchedURL, fetchedText: fetchedText, contentFormat: contentFormat) else {
            return false
        }
        return ImportedItemResolver.canRepresentSameWork(item, imported)
    }

    /// The identity the import gives a fetched page: its cleaned text, hashed as the sender's was, and the
    /// address it keeps (a front-matter `source:` line wins over the address the reader ended on). Mirrors the
    /// text and reference steps of `SessionEngine.browserTextImportOutcome`; a test imports the same page and
    /// compares, so the two cannot drift apart. Nil when the page has no text.
    static func importedIdentity(
        fetchedURL: String,
        fetchedText: String,
        contentFormat: BrowserTextContentFormat?
    ) -> SharedItemIdentity? {
        let rawText = fetchedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else { return nil }
        let parsed = contentFormat == .markdown
            ? try? ObsidianMarkdownParser.parse(fileName: "Article", contents: rawText, fallbackTitle: "Article")
            : nil
        let text = (parsed?.text ?? rawText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let stored = Item(
            id: "fetched-shared-article",
            title: "Article",
            mediaType: "text",
            text: text,
            externalReference: parsed?.source ?? fetchedURL,
            status: "ready",
            externalReferenceType: "url"
        )
        return SharedItemIdentityBuilder.localIdentity(for: stored)
    }
}
