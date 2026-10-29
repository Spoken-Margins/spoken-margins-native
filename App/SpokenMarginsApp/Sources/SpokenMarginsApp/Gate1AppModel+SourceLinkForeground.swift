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

/// Foreground source-link import (#979), moved unchanged out of the central model.
extension Gate1AppModel {
    @discardableResult
    func importSourceLink(_ handoff: SourceLinkHandoff) -> Bool {
        importSourceLink(
            urlString: handoff.inputURL,
            sourceSurface: handoff.sourceSurface,
            startSession: handoff.startSession && !hasActiveSession
        )
    }

    @discardableResult
    func importSourceLinkAsync(_ handoff: SourceLinkHandoff) async -> Bool {
        await importSourceLinkAsync(
            urlString: handoff.inputURL,
            sourceSurface: handoff.sourceSurface,
            startSession: handoff.startSession && !hasActiveSession
        )
    }

    @discardableResult
    func importSourceLinkAsync(urlString: String, sourceSurface: String, startSession: Bool = true) async -> Bool {
        withdrawRetryOffer("sourceLink")
        let shouldStartSession = startSession && !hasActiveSession
        guard sourceLinkResolver == nil else {
            return importSourceLink(urlString: urlString, sourceSurface: sourceSurface, startSession: shouldStartSession)
        }
        sourceLinkGate.begin()
        statusMessage = "Resolving source link..."
        defer { sourceLinkGate.end() }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            reportFailure("Enter a valid podcast, RSS, or audio URL.")
            return false
        }
        let request = LinkResolutionRequest(
            id: "source-link-\(Int(Date().timeIntervalSince1970))",
            inputURL: url.absoluteString,
            sourceSurface: sourceSurface,
            createdAt: Date()
        )
        do {
            let fetched = FetchedPageMemo() // the voiceover lookup reads the post page from here (#810)
            let result = try await PublicPodcastLinkResolver().remembering(fetched).resolveAsync(request)
            // Resolving took seconds: a start that began meanwhile keeps the audio, and this item is only added (#2135).
            let startNow = SourceLinkImportGate.mayStartPlayback(
                requested: shouldStartSession, anotherSessionIsActive: hasActiveSession)
            if result.isPDFDocument { return try await importPDFFromLinkField(url) }
            if let article = await readLinkAsArticleOrOfferSafari(url, after: result, startSession: startNow) {
                guard let itemId = importBrowserTextItem(article, opensItem: false) else { return false }
                rememberSharedLinkVoiceover(sharedURL: url, article: article, itemId: itemId, fetched: fetched)
                return true
            }
            return importResolvedSourceLink(request: request, result: result, startSession: startNow)
        } catch {
            offerSafariIfUnreadable(url, error: error)
            reportFailure(error, context: "Source link import failed", retry: .init(key: "sourceLink") { [weak self] in
                self?.sourceLinkURL = urlString
                _ = self?.beginSourceLinkImportFromForm(startSession: startSession)
            })
            return false
        }
    }

    @discardableResult
    func importSourceLink(urlString: String, sourceSurface: String, startSession: Bool = true) -> Bool {
        let shouldStartSession = startSession && !hasActiveSession
        if hasActiveSession, sourceLinkResolver == nil {
            Task { @MainActor in
                _ = await importSourceLinkAsync(
                    urlString: urlString,
                    sourceSurface: sourceSurface,
                    startSession: false
                )
            }
            return true
        }
        sourceLinkGate.begin()
        defer { sourceLinkGate.end() }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            reportFailure("Enter a valid podcast, RSS, or audio URL.")
            return false
        }
        do {
            if !shouldStartSession, let sourceLinkResolver {
                let request = LinkResolutionRequest(
                    id: "source-link-\(Int(Date().timeIntervalSince1970))",
                    inputURL: url.absoluteString,
                    sourceSurface: sourceSurface,
                    createdAt: Date()
                )
                return importResolvedSourceLink(
                    request: request,
                    result: try sourceLinkResolver.resolve(request),
                    startSession: false
                )
            }
            let store = try requireStore()
            if engine == nil {
                installEngine(try makeEngine(store: store))
            }
            guard let engine else { return false }
            statusMessage = "Resolving source link..."
            let request = LinkResolutionRequest(
                id: "source-link-\(Int(Date().timeIntervalSince1970))",
                inputURL: url.absoluteString,
                sourceSurface: sourceSurface,
                createdAt: Date()
            )
            let imported = try engine.importSourceLink(request, startSessionWhenPlayable: shouldStartSession)
            snapshot = shouldStartSession && imported.linkResolutionStatus == LinkResolutionStatus.playable.rawValue
                ? try applyPreferredPlaybackRate(to: imported, engine: engine)
                : imported
            refreshLibraryRowsInBackground(mustPublish: true) // the new row; a whole-Library read on main hung each add (#2505)
            if let itemId = snapshot.itemId {
                activeItemId = itemId
                selectedItem = try loadItemDetail(id: itemId, store: store)
            }
            diagnostics["lastSourceLinkImport"] = snapshot.itemId ?? "none"
            diagnostics["lastSourceLinkStatus"] = snapshot.linkResolutionStatus ?? "unknown"
            diagnostics["lastSourceLinkFailureReason"] = snapshot.linkResolutionFailureReason ?? "none"
            let sourceLinkProvider = engine.lastLinkResolutionResult?.originalLink.provider
                ?? engine.lastLinkResolutionResult?.candidates.first?.sourceLink.provider
            diagnostics["lastSourceLinkProvider"] = sourceLinkProvider ?? "unknown"
            if snapshot.linkResolutionStatus == LinkResolutionStatus.needsReview.rawValue,
               let result = engine.lastLinkResolutionResult,
               presentSourceLinkCandidateReviewIfAvailable(request: request, result: result, startSession: shouldStartSession) {
                return false
            }
            if snapshot.linkResolutionStatus == LinkResolutionStatus.playable.rawValue, let title = snapshot.title {
                markOnboardingSteps([.addedOwnSource, .addedPodcast])
                screen = shouldStartSession ? .playback : .item
                sourceTranscriptStatus = snapshot.sourceTranscriptStatus ?? "not_started"
                diagnostics["sourceTranscriptionStatus"] = sourceTranscriptStatus
                if let itemId = snapshot.itemId {
                    schedulePodcastDownloadIfNeeded(itemId: itemId)
                    let resolved = engine.lastLinkResolutionResult
                    scheduleSourceTranscriptImportIfAvailable(
                        resolved?.selectedCandidate?.transcriptLinks ?? resolved?.candidates.flatMap(\.transcriptLinks) ?? [],
                        itemId: itemId
                    )
                }
                reportConfirmation(shouldStartSession ? "Imported and started \(title)." : "Imported \(title).")
                return true
            }
            screen = .home
            reportFailure(SourceLinkFailureMessage.text(
                status: snapshot.linkResolutionStatus,
                reason: snapshot.linkResolutionFailureReason,
                provider: sourceLinkProvider
            ))
            return false
        } catch {
            reportFailure(error, context: "Source link import failed")
            return false
        }
    }

    @discardableResult
    func importResolvedSourceLink(request: LinkResolutionRequest, result: LinkResolutionResult, startSession requestedStart: Bool = true) -> Bool {
        // Asked again here, as the last step: a review pick or a slow resolve can finish after playback began (#2135).
        let startSession = SourceLinkImportGate.mayStartPlayback(
            requested: requestedStart, anotherSessionIsActive: hasActiveSession)
        do {
            if presentSourceLinkCandidateReviewIfAvailable(request: request, result: result, startSession: startSession) {
                return false
            }
            if !startSession {
                guard let item = try persistResolvedSourceLinkInBackground(request: request, result: result) else {
                    reportFailure(SourceLinkFailureMessage.text(
                        status: result.status.rawValue,
                        reason: result.failureReason,
                        provider: result.originalLink.provider ?? result.candidates.first?.sourceLink.provider
                    ))
                    return false
                }
                reportAddedToLibrary(title: item.title, itemId: item.id)
                return true
            }
            let store = try requireStore()
            if engine == nil {
                installEngine(try makeEngine(store: store))
            }
            guard let engine else { return false }
            let imported = try engine.importResolvedSourceLink(request, result: result, startSessionWhenPlayable: startSession)
            snapshot = startSession && imported.linkResolutionStatus == LinkResolutionStatus.playable.rawValue
                ? try applyPreferredPlaybackRate(to: imported, engine: engine)
                : imported
            refreshLibraryRowsInBackground(mustPublish: true) // the new row; a whole-Library read on main hung each add (#2505)
            if let itemId = snapshot.itemId {
                activeItemId = itemId
                selectedItem = try loadItemDetail(id: itemId, store: store)
            }
            diagnostics["lastSourceLinkImport"] = snapshot.itemId ?? "none"
            diagnostics["lastSourceLinkStatus"] = snapshot.linkResolutionStatus ?? "unknown"
            diagnostics["lastSourceLinkFailureReason"] = snapshot.linkResolutionFailureReason ?? "none"
            let sourceLinkProvider = result.originalLink.provider ?? result.candidates.first?.sourceLink.provider
            diagnostics["lastSourceLinkProvider"] = sourceLinkProvider ?? "unknown"
            if snapshot.linkResolutionStatus == LinkResolutionStatus.playable.rawValue, let title = snapshot.title {
                markOnboardingSteps([.addedOwnSource, .addedPodcast])
                screen = startSession ? .playback : .item
                sourceTranscriptStatus = snapshot.sourceTranscriptStatus ?? "not_started"
                diagnostics["sourceTranscriptionStatus"] = sourceTranscriptStatus
                if let itemId = snapshot.itemId {
                    schedulePodcastDownloadIfNeeded(itemId: itemId)
                    scheduleSourceTranscriptImportIfAvailable(
                        result.selectedCandidate?.transcriptLinks ?? result.candidates.flatMap(\.transcriptLinks),
                        itemId: itemId
                    )
                }
                reportConfirmation(startSession ? "Imported and started \(title)." : "Imported \(title).")
                return true
            }
            screen = .home
            reportFailure(SourceLinkFailureMessage.text(
                status: snapshot.linkResolutionStatus,
                reason: snapshot.linkResolutionFailureReason,
                provider: sourceLinkProvider
            ))
            return false
        } catch {
            reportFailure(error, context: "Source link import failed")
            return false
        }
    }
}
