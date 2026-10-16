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
        guard !pendingSourceContextInterjectionIds.contains(Self.marginIdentity(interjection)) else { return }
        if !scheduleSourceWindowContextIfNeeded(for: interjection, reportsResult: true) {
            reportWarning("Context needs a source timestamp and completed Margin transcription. Retry when transcription finishes.")
        }
    }

    func retryInterjectionTranscription(_ interjection: Interjection) {
        guard interjection.captureKind != .written, interjection.audioPath != nil else {
            reportFailure("The saved Margin audio is unavailable.")
            return
        }
        guard retryingInterjectionTranscriptionIds.insert(Self.marginIdentity(interjection)).inserted else { return }
        scheduleRetriedTranscription(for: interjection)
        reportConfirmation("Retranscribing the saved Margin audio.")
    }

    /// A transcription failure is about the Margin's own listen, so on the Now screen it is the tag under the
    /// title, with Retry, and the full message stays on the item (#430).
    func presentTranscriptionFailure(_ notice: TranscriptionFailureWording.Notice, for interjection: Interjection) {
        let origin = FeedbackOrigin(itemId: interjection.itemId, sessionId: interjection.sessionId, work: .marginTranscription)
        notice.present(
            warning: { reportWarning($0, origin: origin) },
            failure: {
                reportFailure(
                    $0,
                    itemId: interjection.itemId,
                    retry: .init(key: "transcription:\(interjection.id)") { [weak self] in self?.retryInterjectionTranscription(interjection) },
                    origin: origin
                )
            }
        )
    }

    func deleteTranscript(interjection: Interjection) {
        run { engine in
            snapshot = try engine.deleteRepresentation(interjectionId: interjection.id, sessionId: interjection.sessionId, representation: "transcript")
            refreshSelectedItem()
            reportSuccess("Deleted transcript.")
        }
        refreshMarginRows()
    }

    func deleteInterjection(_ interjection: Interjection) {
        run { engine in
            snapshot = try engine.deleteInterjection(interjectionId: interjection.id, sessionId: interjection.sessionId)
            refreshSelectedItem()
            reportSuccess("Deleted Margin.")
        }
        refreshMarginRows()
    }

    func setInterjectionStarredForSharing(_ interjectionID: String, sessionId: String? = nil, starred: Bool) {
        do {
            let store = try requireStore()
            let candidates = try sessionId.map { try store.loadInterjections(sessionId: $0) } ?? selectedItem.interjections
            guard var interjection = candidates.first(where: { $0.id == interjectionID && (sessionId == nil || $0.sessionId == sessionId) }) else {
                throw SessionKitError.persistenceFailed("share_curation_interjection_missing")
            }
            interjection.isStarredForSharing = starred ? true : nil
            try store.saveInterjection(interjection)
            refreshSelectedItem()
            refreshMarginRows()
            diagnostics["shareCuration:\(interjectionID)"] = starred ? "starred" : "unstarred"
        } catch {
            reportFailure(error, context: "Margin sharing star could not be saved")
        }
    }

    func setMarginStarred(_ row: MarginRow, starred: Bool) {
        guard !rejectNavigationOrSessionMutationWhileRecording("star_margin") else { return }
        do {
            let store = try requireStore()
            guard var interjection = try store.loadInterjections(sessionId: row.interjection.sessionId).first(where: {
                $0.id == row.interjection.id
                    && $0.sessionId == row.interjection.sessionId
                    && $0.itemId == row.interjection.itemId
            }) else {
                throw SessionKitError.persistenceFailed("margin_curation_interjection_missing")
            }
            interjection.isStarredForSharing = starred ? true : nil
            try store.saveInterjection(interjection)
            refreshMarginRows()
            if snapshot.sessionId == row.interjection.sessionId { refreshSelectedItem() }
            diagnostics["marginCuration:\(row.id)"] = starred ? "starred" : "unstarred"
        } catch {
            reportFailure(error, context: "Margin star could not be saved")
        }
    }

    func setInterjectionPrivateSharingNote(_ interjectionID: String, sessionId: String? = nil, note: String) {
        do {
            let store = try requireStore()
            let candidates = try sessionId.map { try store.loadInterjections(sessionId: $0) } ?? selectedItem.interjections
            guard var interjection = candidates.first(where: { $0.id == interjectionID && (sessionId == nil || $0.sessionId == sessionId) }) else {
                throw SessionKitError.persistenceFailed("share_curation_interjection_missing")
            }
            let bounded = String(note.prefix(Self.privateSharingNoteCharacterLimit))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            interjection.privateSharingNote = bounded.isEmpty ? nil : bounded
            try store.saveInterjection(interjection)
            refreshSelectedItem()
            refreshMarginRows()
            diagnostics["shareCurationNote:\(interjectionID)"] = bounded.isEmpty ? "empty" : "saved"
        } catch {
            reportFailure(error, context: "Private sharing note could not be saved")
        }
    }
}
