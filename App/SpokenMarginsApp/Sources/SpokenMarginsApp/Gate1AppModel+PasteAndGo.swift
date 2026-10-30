import Foundation
import SessionKit

/// Paste & go (#145): one tap adds whatever the clipboard holds, and an article the app can't read
/// offers Safari, whose share sheet hands the rendered page back to the share extension.
extension Gate1AppModel {
    enum PasteAndGoOutcome: Equatable {
        /// A link went to the source-link import; its progress shows in `sourceLinkImportState`.
        case resolvingLink
        case addedText
        /// Nothing was created; the message says why.
        case notAdded(String)
    }

    /// Routes pasted content: a link through the podcast-first link import with its article fallback,
    /// text through the text import, and anything else to an inline message. Starts playback only for a link and
    /// only when `startSession` says so; the Library's copied-link card (#2944) and Paste & go never do.
    @discardableResult
    func pasteAndGo(_ content: String?, html: String? = nil, startSession: Bool = false) -> PasteAndGoOutcome {
        switch ClipboardIntakeClassifier.classify(content) {
        case .link(let url):
            sourceLinkURL = url.absoluteString
            guard beginSourceLinkImportFromForm(startSession: startSession) else {
                return .notAdded(isResolvingSourceLink
                    ? "Still adding the last link. Try again in a moment."
                    : sourceLinkImportMessage ?? "This link could not be added.")
            }
            return .resolvingLink
        case .text(let title, let body):
            // Leave whatever the listener was typing on the Text route as it was.
            let draft = (title: importTitle, text: importText)
            defer { (importTitle, importText) = draft }
            importTitle = title
            importText = Self.pastedSourceText(plainText: body, html: html)
            lastError = nil
            importTextItem(startListening: false)
            if let lastError { return .notAdded(lastError) }
            return .addedText
        case .unusable(let reason):
            return .notAdded(reason.message)
        }
    }

    /// The Link field's article fallback (#144, #223) for a page with no audio. When the page can't be read,
    /// offers Safari and returns nil, so the caller still shows the resolver's own "no audio" result.
    func readLinkAsArticleOrOfferSafari(_ url: URL, after result: LinkResolutionResult, startSession: Bool) async -> BrowserTextHandoff? {
        do {
            return try await LinkArticleFallback.article(for: url, after: result, startSession: startSession, using: readablePageExtractor) {
                diagnostics["lastSourceLinkArticleFallback"] = $0
            }
        } catch {
            offerSafariIfUnreadable(url, error: (error as? LinkArticleFallbackError)?.extractorError ?? error)
            return nil
        }
    }

    /// Offers Safari when an https page refused the app or couldn't be read as an article. Offline and
    /// timeout failures don't get the offer: Safari wouldn't do better, and the retry banner covers them.
    func offerSafariIfUnreadable(_ url: URL, error: Error) {
        guard url.scheme?.lowercased() == "https", let reason = Self.safariOfferReason(for: error) else { return }
        sourceLinkSafariOffer = OpenInSafariOffer(url: url, reason: reason)
    }

    nonisolated static func safariOfferReason(for error: Error) -> String? {
        switch error {
        case ReadablePageExtractionError.httpStatus(let status):
            return OpenInSafariOffer.reason(forHTTPStatus: status)
        case ReadablePageExtractionError.oversizedHTML:
            return "the page is larger than the 1 MB the app reads itself."
        case ReadablePageExtractionError.tooManyRedirects:
            return "the page redirected too many times."
        case ReadablePageExtractionError.pageLeftHTTPS:
            return "the page moved to an address that isn't secure."
        case ReadablePageExtractionError.invalidResult:
            return "no article text was found. It may need JavaScript or a sign-in."
        case ReadablePageExtractionError.invalidURL, ReadablePageExtractionError.missingExtractor:
            return nil
        case let urlError as URLError where urlError.code == .badServerResponse:
            return "the site refused the request or sent an error page."
        default:
            return nil
        }
    }

    /// Restores heading levels that a plain-text paste loses, from the HTML copy of the same selection.
    nonisolated static func pastedSourceText(plainText: String, html: String?) -> String {
        guard let html, let regex = try? NSRegularExpression(pattern: #"(?is)<h([1-6])\b[^>]*>(.*?)</h\1\s*>"#) else { return plainText }
        var headings: [String: Int] = [:]
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let levelRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html),
                  let level = Int(html[levelRange]) else { continue }
            var title = String(html[titleRange]).replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            for (entity, value) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")] {
                title = title.replacingOccurrences(of: entity, with: value)
            }
            headings[title.trimmingCharacters(in: .whitespacesAndNewlines)] = level
        }
        return plainText.components(separatedBy: .newlines).map { line in
            guard let level = headings[line.trimmingCharacters(in: .whitespaces)] else { return line }
            return String(repeating: "#", count: level) + " " + line
        }.joined(separator: "\n")
    }
}
