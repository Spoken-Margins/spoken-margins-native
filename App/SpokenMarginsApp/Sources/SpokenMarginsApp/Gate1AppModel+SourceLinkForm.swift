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

/// The source-link form: paste, candidate review and reset (#979), moved unchanged out of the central model.
extension Gate1AppModel {
    var isResolvingSourceLink: Bool { sourceLinkGate.isBusy }

    @discardableResult
    func beginSourceLinkImportFromForm(startSession: Bool = true) -> Bool {
        guard !sourceLinkGate.isBusy else { return false }
        let submittedURL = sourceLinkURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsedURL = URL(string: submittedURL),
              let scheme = parsedURL.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              parsedURL.host != nil else {
            sourceLinkImportState = "failure"
            sourceLinkImportMessage = submittedURL.isEmpty
                ? "Paste or enter a link to an article, podcast, feed or audio file first."
                : "Enter a valid web link (http or https) to an article, podcast, feed or audio file."
            reportFailure(sourceLinkImportMessage ?? "Enter a valid source URL.")
            return false
        }
        sourceLinkGate.begin()
        sourceLinkSafariOffer = nil
        sourceLinkImportState = "resolving"
        sourceLinkImportMessage = "Resolving source link…"
        statusMessage = "Resolving source link..."
        lastError = nil
        diagnostics["lastSourceLinkButtonTap"] = "registered"
        Task { @MainActor in
            defer { sourceLinkGate.end() }
            await Task.yield()
            let imported = await importSourceLinkAsync(
                urlString: parsedURL.absoluteString,
                sourceSurface: "paste",
                startSession: startSession && !hasActiveSession
            )
            hangTelemetry.labels.scoped("sourceLinkFormFinish") {
                if imported, sourceLinkURL.trimmingCharacters(in: .whitespacesAndNewlines) == submittedURL {
                    sourceLinkURL = ""
                }
                let awaitsCandidateReview = sourceLinkCandidateReview?.request.inputURL == parsedURL.absoluteString
                if awaitsCandidateReview {
                    sourceLinkImportState = "review"
                    sourceLinkImportMessage = "Choose the matching podcast episode."
                } else {
                    sourceLinkImportState = imported ? "success" : "failure"
                    sourceLinkImportMessage = imported ? "Source added." : (sourceLinkSafariOffer?.message ?? lastError ?? "This source could not be added.")
                }
            }
        }
        return true
    }

    func pasteSourceLinkFromClipboard() {
        #if canImport(UIKit)
        guard let clipboardText = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clipboardText.isEmpty else {
            reportFailure("Clipboard does not contain a URL.")
            return
        }
        let pasted = Self.firstURL(in: clipboardText)?.absoluteString ?? clipboardText
        sourceLinkURL = pasted
        sourceLinkImportState = "idle"
        sourceLinkImportMessage = nil
        reportSuccess("Pasted link from Clipboard.")
        diagnostics["lastSourceLinkClipboardPaste"] = pasted
        #else
        reportFailure("Clipboard paste is unavailable on this platform.")
        #endif
    }

    /// Fills the Following feed field from the clipboard (#153). Returns false when the clipboard has no link.
    @discardableResult
    func pasteFollowedSourceFromClipboard() -> Bool {
        #if canImport(UIKit)
        guard let text = UIPasteboard.general.string, let url = Self.firstURL(in: text) else { return false }
        followedSourceURL = url.absoluteString
        return true
        #else
        return false
        #endif
    }

    func resetSourceLinkImportState() {
        guard !sourceLinkGate.isBusy else { return }
        sourceLinkImportState = "idle"
        sourceLinkImportMessage = nil
        sourceLinkSafariOffer = nil
    }

    func presentSourceLinkCandidateReviewIfAvailable(
        request: LinkResolutionRequest,
        result: LinkResolutionResult,
        startSession: Bool
    ) -> Bool {
        let playableCandidates = result.candidates.filter { candidate in
            guard let audioURL = candidate.audioURL,
                  let url = URL(string: audioURL) else { return false }
            return url.scheme?.lowercased() == "https"
        }
        guard result.status == .needsReview, playableCandidates.count > 1 else { return false }
        var reviewResult = result
        reviewResult.candidates = playableCandidates
        sourceLinkCandidateReview = SourceLinkCandidateReviewState(
            request: request,
            result: reviewResult,
            startSession: startSession
        )
        diagnostics["lastSourceLinkReviewCandidates"] = "\(playableCandidates.count)"
        reportSuccess("Choose the matching podcast episode. Nothing has been imported yet.")
        return true
    }

    func selectSourceLinkCandidate(_ candidate: LinkResolutionCandidate) {
        guard let review = sourceLinkCandidateReview,
              review.result.candidates.contains(candidate) else { return }
        sourceLinkCandidateReview = nil
        var selected = review.result
        selected.status = .playable
        selected.selectedCandidate = candidate
        selected.candidates = [candidate]
        selected.failureReason = nil
        let imported = importResolvedSourceLink(request: review.request, result: selected, startSession: review.startSession)
        sourceLinkImportState = imported ? "success" : "failure"
        sourceLinkImportMessage = imported ? "Source added." : (lastError ?? "This source could not be added.")
        if imported, sourceLinkURL.trimmingCharacters(in: .whitespacesAndNewlines) == review.request.inputURL {
            sourceLinkURL = ""
        }
    }

    func cancelSourceLinkCandidateReview() {
        sourceLinkCandidateReview = nil
        sourceLinkImportState = "idle"
        sourceLinkImportMessage = "Podcast import cancelled."
        reportSuccess("Podcast import cancelled. Nothing was added.")
    }
}
