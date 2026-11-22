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

/// Margin identity, retry, delete, star and private notes (#990), moved unchanged out of the central model.
extension Gate1AppModel {
    static func marginIdentity(_ interjection: Interjection) -> String {
        "\(interjection.sessionId)::\(interjection.id)"
    }

    /// Names a failed transcription's Retry offer, so retrying or transcribing the Margin another way withdraws it.
    static func transcriptionRetryKey(_ interjection: Interjection) -> String {
        "transcription:\(marginIdentity(interjection))"
    }

    /// Margin IDs repeat per session, so per-Margin diagnostics carry a hashed session token.
    static func marginDiagnosticKey(_ name: String, sessionId: String, interjectionId: String) -> String {
        PodcastAnchorCaptureDiagnostics.marginKey(name, sessionId: sessionId, interjectionId: interjectionId)
    }

    static func marginDiagnosticKey(_ name: String, _ interjection: Interjection) -> String {
        marginDiagnosticKey(name, sessionId: interjection.sessionId, interjectionId: interjection.id)
    }

    static func marginDiagnosticKey(_ name: String, _ request: PostResumeAudioSampleRequest) -> String {
        marginDiagnosticKey(name, sessionId: request.sessionId, interjectionId: request.interjectionId)
    }

    func isRetryingInterjectionTranscription(_ interjection: Interjection) -> Bool {
        retryingInterjectionTranscriptionIds.contains(Self.marginIdentity(interjection))
    }

    func isRetryingAnchorContext(_ interjection: Interjection) -> Bool {
        pendingSourceContextInterjectionIds.contains(Self.marginIdentity(interjection))
    }

    func retryAnchorContext(_ interjection: Interjection) {
        guard interjection.captureKind != .written else { return }
        guard currentMargin(matching: interjection).verdict != .gone else {
            reportFailure("That Margin was deleted, so its context can't be retried.")
            return
        }
        guard !pendingSourceContextInterjectionIds.contains(Self.marginIdentity(interjection)) else { return }
        if !scheduleSourceWindowContextIfNeeded(for: interjection, reportsResult: true) {
            reportWarning("Context needs a source timestamp and completed Margin transcription. Retry when transcription finishes.")
        }
    }

    /// The Margin as stored now, with the verdict on retranscribing it. A Retry offer holds the Margin as it
    /// was when the failure was posted, so deleting the Margin or its item must not leave that copy usable (#430).
    func currentMargin(matching interjection: Interjection) -> (margin: Interjection?, verdict: MarginTranscriptionRetry.Verdict) {
        let store = try? requireStore()
        let current = (try? store?.loadInterjections(sessionId: interjection.sessionId))?.first { $0.id == interjection.id }
        let itemDeletedAt = (try? store?.loadItemSummary(id: interjection.itemId))?.deletedAt
        return (current, MarginTranscriptionRetry.verdict(current: current, itemDeletedAt: itemDeletedAt))
    }

    func retryInterjectionTranscription(_ interjection: Interjection) {
        withdrawRetryOffer(Self.transcriptionRetryKey(interjection))
        let (current, verdict) = currentMargin(matching: interjection)
        guard verdict != .gone, let current else {
            reportFailure("That Margin was deleted, so there is nothing to retranscribe.")
            return
        }
        guard verdict == .retry else {
            reportFailure("The saved Margin audio is unavailable.")
            return
        }
        guard retryingInterjectionTranscriptionIds.insert(Self.marginIdentity(current)).inserted else { return }
        scheduleRetriedTranscription(for: current)
        reportConfirmation("Retranscribing the saved Margin audio.")
    }

    /// A transcription failure is about the Margin's own listen, so on the Now screen it is the tag under the
    /// title, with Retry, and the full message stays on the item (#430). A Margin deleted while it was
    /// transcribing gets no notice at all: there is nothing left to retry or to tell the listener about.
    func presentTranscriptionFailure(_ notice: TranscriptionFailureWording.Notice?, for interjection: Interjection) {
        // No notice: the Margin only waits for the listener's answer to the Speech Recognition card (#4715).
        guard let notice, currentMargin(matching: interjection).verdict != .gone else { return }
        let origin = FeedbackOrigin(itemId: interjection.itemId, sessionId: interjection.sessionId, work: .marginTranscription)
        notice.present(
            warning: { reportWarning($0, origin: origin) },
            failure: {
                reportFailure(
                    $0,
                    itemId: interjection.itemId,
                    retry: .init(key: Self.transcriptionRetryKey(interjection)) { [weak self] in self?.retryInterjectionTranscription(interjection) },
                    origin: origin
                )
            }
        )
    }

    func deleteTranscript(interjection: Interjection) {
        run { engine in
            snapshot = try engine.deleteRepresentation(interjectionId: interjection.id, sessionId: interjection.sessionId, representation: "transcript")
            refreshSelectedItemInBackground()
            reportSuccess("Deleted transcript.")
        }
        refreshMarginRow(sessionId: interjection.sessionId, interjectionId: interjection.id)
    }

    func deleteInterjection(_ interjection: Interjection) {
        run { engine in
            snapshot = try engine.deleteInterjection(interjectionId: interjection.id, sessionId: interjection.sessionId)
            refreshSelectedItemInBackground()
            cutShortMarks().clear(sessionId: interjection.sessionId, interjectionId: interjection.id)
            // Its failed-transcription Retry would otherwise outlive it (#430).
            withdrawRetryOffer(Self.transcriptionRetryKey(interjection))
            reportSuccess("Deleted Margin.")
            presentMarginDeleteUndo(interjection)
        }
        refreshMarginRow(sessionId: interjection.sessionId, interjectionId: interjection.id)
    }

    /// Puts the sharing star on or off for a Margin of any session of any item (#4173). One setter for every place a Margin
    /// can be starred, so they all write the same way and the Share sheet, which starts from the stars, reads the same thing.
    func setStarredForSharing(_ interjection: Interjection, starred: Bool, place: ShareStarPlace) {
        writeStar(interjection, place: place) { $0.isStarredForSharing = starred ? true : nil }
    }

    /// Flips the star. The flip happens inside the store's own write, on the saved Margin, so two quick taps leave it off
    /// and three leave it on whatever the screen last showed.
    func toggleStarredForSharing(_ interjection: Interjection, place: ShareStarPlace) {
        writeStar(interjection, place: place) { $0.isStarredForSharing = $0.isStarredForSharing == true ? nil : true }
    }

    private func writeStar(_ interjection: Interjection, place: ShareStarPlace, _ edit: (inout Interjection) -> Void) {
        do {
            let store = try requireStore()
            var wasStarred = false
            guard let updated = try store.updateInterjection(
                id: interjection.id, sessionId: interjection.sessionId, itemId: interjection.itemId, { margin in
                    wasStarred = margin.isStarredForSharing == true
                    edit(&margin)
                }
            ) else {
                throw SessionKitError.persistenceFailed("share_curation_interjection_missing")
            }
            // Share reads the selected item's Margins, so the star shows there at once. Only the star is copied from the
            // Margin the write returned: the item loader resolves other fields of a podcast Margin's anchor, and the
            // background read below brings the rest. No item is read from the store here (#2505).
            if updated.itemId == selectedItem.id,
               let index = selectedItem.interjections.firstIndex(where: { $0.id == updated.id && $0.sessionId == updated.sessionId }) {
                selectedItem.interjections[index].isStarredForSharing = updated.isStarredForSharing
            }
            refreshMarginRow(sessionId: updated.sessionId, interjectionId: updated.id)
            refreshSelectedItemInBackground()
            diagnostics["shareCuration:\(updated.id)"] = updated.isStarredForSharing == true ? "starred" : "unstarred"
            // Counted on a change only, so a menu item that sets what is already set adds nothing (#4173).
            let isStarred = updated.isStarredForSharing == true
            if isStarred != wasStarred { shareStarTally.record(place, turnedOn: isStarred) }
        } catch {
            reportFailure(error, context: "Margin sharing star could not be saved")
        }
    }

    func setInterjectionPrivateSharingNote(_ interjectionID: String, sessionId: String? = nil, note: String) {
        do {
            let store = try requireStore()
            let bounded = String(note.prefix(Self.privateSharingNoteCharacterLimit))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let owningSessionId = sessionId ?? selectedItem.interjections.first(where: { $0.id == interjectionID })?.sessionId,
                  let interjection = try store.updateInterjection(id: interjectionID, sessionId: owningSessionId, { $0.privateSharingNote = bounded.isEmpty ? nil : bounded }) else {
                throw SessionKitError.persistenceFailed("share_curation_interjection_missing")
            }
            refreshSelectedItemInBackground()
            refreshMarginRow(sessionId: interjection.sessionId, interjectionId: interjection.id)
            diagnostics["shareCurationNote:\(interjectionID)"] = bounded.isEmpty ? "empty" : "saved"
        } catch {
            reportFailure(error, context: "Private sharing note could not be saved")
        }
    }
}
