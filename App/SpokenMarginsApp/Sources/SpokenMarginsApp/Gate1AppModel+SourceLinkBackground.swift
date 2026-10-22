import Foundation
import Security
import SessionKit
import SessionKitAI
import SessionKitAudio
import SessionKitSharing
import SessionKitSupertonic
import SessionKitPersistence
import SessionKitFeeds
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(PDFKit)
import PDFKit
#endif

/// Background source-link import and its persistence (#979), moved unchanged out of the central model.
extension Gate1AppModel {
    func persistResolvedSourceLinkInBackground(
        request: LinkResolutionRequest,
        result: LinkResolutionResult
    ) throws -> Item? {
        let store = try requireStore()
        if engine == nil {
            installEngine(try makeEngine(store: store))
        }
        guard let engine,
              let item = try engine.importResolvedSourceLinkInBackground(request, result: result) else {
            return nil
        }
        libraryItems = try loadLibraryRows(store: store)
        diagnostics["lastBackgroundSourceLinkImport"] = item.id
        markOnboardingSteps([.addedOwnSource, .addedPodcast])
        schedulePodcastDownloadIfNeeded(itemId: item.id)
        scheduleSourceTranscriptImportIfAvailable(
            result.selectedCandidate?.transcriptLinks ?? result.candidates.flatMap(\.transcriptLinks),
            itemId: item.id
        )
        return item
    }

    @discardableResult
    func importSourceLinkInBackground(_ handoff: SourceLinkHandoff, feedEntry: FeedEntry? = nil, subscription: FeedSubscription? = nil) async throws -> String? {
        let trimmed = handoff.inputURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if handoff.sourceSurface == "share_sheet_pdf_file",
           let fileURL = URL(string: trimmed),
           fileURL.isFileURL {
            let handoffStore = try SourceLinkHandoffStore.appGroup()
            guard handoffStore.isManagedPDFURL(fileURL) else {
                throw SessionKitError.persistenceFailed("The shared PDF is no longer available to import.")
            }
            let itemId = try await importLocalSharedPDFInBackground(url: fileURL)
            handoffStore.deleteManagedPDF(at: fileURL)
            return itemId
        }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            throw SessionKitError.persistenceFailed("This share does not contain a valid podcast, RSS, or audio URL.")
        }
        if Self.isRemotePDFHandoff(handoff) {
            return try await importRemotePDFInBackground(url: url)
        }
        let request = LinkResolutionRequest(
            id: handoff.id,
            inputURL: url.absoluteString,
            sourceSurface: handoff.sourceSurface,
            createdAt: Date()
        )
        let fetched = FetchedPageMemo() // the voiceover lookup reads the post page from here (#810)
        let resolution = try await LinkArticleFallback.resolve(
            request, url: url, resolver: sourceLinkResolver, remembering: fetched, allowsArticle: feedEntry == nil,
            using: readablePageExtractor, record: { diagnostics["lastSourceLinkArticleFallback"] = $0 }
        )
        guard case .podcast(let result) = resolution else {
            if case .article(let article) = resolution {
                let itemId = try importBrowserTextInBackground(article)
                rememberSharedLinkVoiceover(sharedURL: url, article: article, itemId: itemId, fetched: fetched)
                return itemId
            }
            return nil
        }
        guard result.status == .playable else {
            if feedEntry == nil, result.isPDFDocument { return try await importRemotePDFInBackground(url: url) } // #758
            let provider = result.originalLink.provider ?? result.candidates.first?.sourceLink.provider
            diagnostics["lastSourceLinkFailureCategory"] = result.failureReason
                ?? result.status.rawValue
            throw SourceLinkNotPlayableError(SourceLinkFailureMessage.text(
                status: result.status.rawValue,
                reason: result.failureReason,
                provider: provider
            ))
        }

        let store = try requireStore()
        if engine == nil {
            installEngine(try makeEngine(store: store))
        }
        guard let engine,
              let item = try engine.importResolvedSourceLinkInBackground(
                request,
                result: result,
                sourceIdentity: feedEntry.map { "\($0.subscriptionId):\($0.id)" }
              ) else {
            throw SessionKitError.persistenceFailed("The shared podcast did not expose playable audio.")
        }
        if let feedEntry {
            var identified = item
            let title = feedEntry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { identified.title = title }
            identified.sourceTitle = subscription?.source.title ?? identified.sourceTitle
            identified.sourceURL = subscription?.source.canonicalURL ?? identified.sourceURL
            identified.externalReference = feedEntry.canonicalURL
            identified.author = feedEntry.author ?? identified.author
            feedEntry.fillEpisodeIdentity(of: &identified, showTitle: subscription?.source.title)
            try store.saveItem(identified)
            if item.media?.url == result.selectedCandidate?.audioURL,
               try store.loadListeningMap(itemId: item.id) == nil,
               let summary = feedEntry.summary,
               let chapters = TimestampedDescriptionChapterParser.parse(summary) {
                _ = try engine.attachPublisherChapters(itemId: item.id, collection: chapters)
            }
            diagnostics["sourceEntryImport:\(feedEntry.id)"] = "item:\(item.id),subscription:\(feedEntry.subscriptionId),title:feed_entry"
        }
        libraryItems = try loadLibraryRows(store: store)
        diagnostics["lastBackgroundSourceLinkImport"] = item.id
        markOnboardingSteps([.addedOwnSource, .addedPodcast])
        schedulePodcastDownloadIfNeeded(itemId: item.id)
        if item.media?.url == result.selectedCandidate?.audioURL, item.transcriptId == nil {
            scheduleSourceTranscriptImportIfAvailable(
                result.selectedCandidate?.transcriptLinks ?? result.candidates.flatMap(\.transcriptLinks),
                itemId: item.id
            )
        }
        return item.id
    }

    static func isRemotePDFHandoff(_ handoff: SourceLinkHandoff) -> Bool { handoff.isRemotePDF }

    /// A shared or pasted Substack post keeps its voiceover beside the article (#810). Runs after the import,
    /// so a slow page never holds up the share.
    func rememberSharedLinkVoiceover(sharedURL: URL, article: BrowserTextHandoff, itemId: String, fetched: FetchedPageMemo) {
        let voiceover = sharedLinkVoiceover
        guard let store = try? requireStore(), voiceover.claim(itemId: itemId) else { return }
        let transcriber = sourceTranscriptionClient
        Task { [weak self] in
            await voiceover.remember(sharedURL: sharedURL, article: article, itemId: itemId, fetched: fetched, store: store, transcriber: transcriber) {
                self?.diagnostics["sharedLinkVoiceover"] = $0
            }
        }
    }
}
