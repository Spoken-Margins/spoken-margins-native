import Foundation

/// A link with no audio can still be an article to listen to. The Link field reads such a page with the app's
/// readable-page extractor (#144), and so does a link shared from another app, such as a Substack post shared
/// from the Substack app (#223). Podcast resolution always runs first, so a podcast link stays a podcast.
public enum LinkArticleFallback {
    /// The page as an article to import, or nil when the fallback doesn't apply: the resolver found audio or
    /// something to review, or the link isn't HTTPS (the extractor loads HTTPS only). Throws
    /// `LinkArticleFallbackError` when the page should be read but the extractor failed. `record` receives the
    /// diagnostic: the extractor's name, or "failed:<reason>".
    @MainActor
    public static func article(
        for url: URL,
        after result: LinkResolutionResult,
        startSession: Bool,
        using extractor: any ReadablePageExtracting,
        record: (String) -> Void
    ) async throws -> BrowserTextHandoff? {
        guard result.foundNoAudio, url.scheme?.lowercased() == "https" else { return nil }
        do {
            var handoff = try await extractor.extract(url: url)
            handoff.requestedContinuation.startSession = startSession
            record(extractor.lastExtractor ?? "extracted")
            return handoff
        } catch {
            record("failed:\(error.localizedDescription)")
            throw LinkArticleFallbackError(extractorFailure: error.localizedDescription)
        }
    }
}

public struct LinkArticleFallbackError: LocalizedError, Equatable, Sendable {
    public let extractorFailure: String

    public init(extractorFailure: String) {
        self.extractorFailure = extractorFailure
    }

    public var errorDescription: String? {
        "This link has no podcast audio, and its article text could not be read. \(extractorFailure)"
    }
}
