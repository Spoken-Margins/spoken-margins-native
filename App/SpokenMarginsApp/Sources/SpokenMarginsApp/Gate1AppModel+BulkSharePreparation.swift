import Combine
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

extension Gate1AppModel {
    /// "Prepare All Included" (#969): the run and its stale-work rule live in `BulkPreparationRun`, and what happens to
    /// one Margin in `BulkShareDraftPreparation` (SessionKitSharing). What stays here is the state the sheet shows and
    /// the diagnostics. The counters are on `sharingState` because the sheet and the Build23 preview fingerprint read
    /// them there.
    var bulkSharePreparationEligibleCount: Int {
        sharingState.drafts.filter(BulkShareDraftPreparation.isEligible).count
    }

    /// Whether a packet can be built now, or must wait for voices it needs (#4647).
    var shareSendReadiness: ShareSendReadiness {
        ShareSendReadiness(sharingState.drafts.map { draft in
            ShareVoiceWait.Margin(
                draft, hasRecording: originalAudioURL(forShareDraft: draft.id) != nil,
                isQueued: sharingState.queuedVoiceIDs.contains(draft.id))
        })
    }

    /// The switch turned on, or the list opened with it stored on (#4647): every eligible Margin's words are cleaned at
    /// once, here, in the model action, never in a view body. Their voices go into the run one at a time behind that:
    /// joining a live run, or starting one. Nothing on the screen waits for them.
    func prepareAllIncludedShareDrafts() {
        sharingState.errorMessage = nil
        let voices = BulkShareDraftPreparation.startPass(host: self)
        guard !voices.isEmpty else { return }
        if bulkSharePreparation.hasTask {
            voices.forEach { bulkSharePreparation.append(id: $0) }
        } else {
            startShareVoiceRun(ids: voices)
        }
    }

    /// Every voice the sheet asks for goes through here (#4647): the switch, an include, arriving words, a card's "Remove
    /// ums and pauses" and a "Without ums" pick. It joins a live run, or starts a run of one, so each voice gets its pause
    /// analysis. Nothing happens when the Margin is already queued, or its voice without ums is already made.
    func queueShareVoice(id: String) {
        guard BulkShareDraftPreparation.needsVoice(id, pending: sharingState.queuedVoiceIDs, host: self) else { return }
        if !bulkSharePreparation.append(id: id) {
            startShareVoiceRun(ids: [id])
        }
    }

    private func startShareVoiceRun(ids: [String]) {
        sharingState.isBulkPreparing = true
        sharingState.bulkPreparationCompleted = 0
        sharingState.bulkPreparationTotal = ids.count
        sharingState.bulkPreparationFailureCount = 0
        diagnostics["bulkSharePreparation"] = "started:total=\(ids.count)"
        bulkSharePreparation.start(ids: ids, host: self)
    }

    /// The progress line's Cancel: stops the run. Every Margin still queued or in progress has its automatic cleanup
    /// undone (words back as recorded), including one its card's button started; Margins already finished keep theirs.
    func cancelBulkSharePreparation() {
        guard sharingState.isBulkPreparing || bulkSharePreparation.hasTask else { return }
        let pending = sharingState.queuedVoiceIDs
        bulkSharePreparation.invalidateAndCancel()
        sharingState.isBulkPreparing = false
        sharingState.queuedVoiceIDs = []
        BulkShareDraftPreparation.rollBackInFlightDrafts(host: self, pending: pending)
        diagnostics["bulkSharePreparation"] = [
            "cancelled",
            "prepared=\(sharingState.bulkPreparationCompleted)",
            "total=\(sharingState.bulkPreparationTotal)"
        ].joined(separator: ";")
    }

    func setShareAutoCleanSelectedEnabled(_ enabled: Bool) {
        ShareAutoCleanPreference.record(enabled: enabled)
        sharingState.needsAutoCleanDecision = false
        sharingState.autoCleanSelectedEnabled = enabled
        if enabled {
            prepareAllIncludedShareDrafts()
        } else {
            cancelBulkSharePreparation()
            BulkShareDraftPreparation.undoAutomaticCleanup(host: self)
            sharingState.bulkPreparationCompleted = 0
            sharingState.bulkPreparationTotal = 0
            sharingState.bulkPreparationFailureCount = 0
        }
    }

    func prepareAutomaticallyCleanedShareDraftsIfEnabled() {
        guard sharingState.autoCleanSelectedEnabled else { return }
        prepareAllIncludedShareDrafts()
    }

    /// One Margin switched in, or whose words arrived, with the switch on (#4647): only that Margin's words are cleaned,
    /// and only it joins the run. Other Margins are never swept up.
    func prepareIncludedShareDraftIfEnabled(_ id: String) {
        guard sharingState.autoCleanSelectedEnabled else { return }
        if BulkShareDraftPreparation.includePass(id: id, host: self) {
            queueShareVoice(id: id)
        }
    }

    /// A Margin switched out, or set to As recorded or Words only, leaves the run at once if it is still queued. The one
    /// in progress checks for itself and is skipped when its work comes back.
    func dropShareVoice(id: String) {
        bulkSharePreparation.skip(id: id)
    }

    /// One Margin's steps, with the model's two handlers. Built per Margin: it holds nothing between Margins.
    private var bulkShareDraftPreparation: BulkShareDraftPreparation {
        BulkShareDraftPreparation(analyze: shareMarginSilenceAnalysisHandler, render: shareMarginAudioCleanupHandler)
    }
}

/// The model is the bulk run's host (#969). The run holds it weakly until a run starts and strongly for the length of
/// one run, as the model's own task did before, so a model can't be released under a Margin that is being prepared.
extension Gate1AppModel: BulkPreparationHost {
    func prepareForBulkRun(itemID: String, ticket: BulkPreparationTicket) async -> BulkPreparationOutcome {
        await bulkShareDraftPreparation.prepare(itemID, ticket: ticket, host: self)
    }

    /// The counts the progress and result lines read: a fallback is finished and failed; a skipped Margin leaves the
    /// total and is neither (#4647).
    func bulkRunDidFinishOne(_ outcome: BulkPreparationOutcome) {
        switch outcome {
        case .prepared:
            sharingState.bulkPreparationCompleted += 1
        case .fellBack:
            sharingState.bulkPreparationCompleted += 1
            sharingState.bulkPreparationFailureCount += 1
        case .skipped:
            sharingState.bulkPreparationTotal = max(sharingState.bulkPreparationCompleted, sharingState.bulkPreparationTotal - 1)
        case .requeued:
            break
        }
    }

    func bulkRunDidAppend(itemID: String) {
        sharingState.bulkPreparationTotal += 1
        sharingState.isBulkPreparing = true
    }

    func bulkRunPendingDidChange(_ pending: Set<String>) {
        if sharingState.queuedVoiceIDs != pending {
            sharingState.queuedVoiceIDs = pending
        }
    }

    func bulkRunDidComplete() {
        sharingState.isBulkPreparing = false
        diagnostics["bulkSharePreparation"] = [
            "complete",
            "prepared=\(sharingState.bulkPreparationCompleted)",
            "fallbacks=\(sharingState.bulkPreparationFailureCount)"
        ].joined(separator: ";")
    }
}

/// What one Margin's bulk steps read and write on the model (#969). Each write to `bulkShareDrafts` is one publish of
/// `sharingState`, as each write to `sharingState.drafts` was when the steps lived here.
extension Gate1AppModel: BulkShareDraftHost {
    var bulkShareDrafts: [ShareInterjectionDraft] {
        get { sharingState.drafts }
        set { sharingState.drafts = newValue }
    }

    var bulkAutomaticallyCleanedDraftIDs: Set<String> {
        get { sharingState.automaticallyCleanedDraftIDs }
        set { sharingState.automaticallyCleanedDraftIDs = newValue }
    }

    func bulkShareAudioURL(forAudioPath path: String) -> URL? {
        resolvedInterjectionAudioURL(for: path)
    }

    func bulkShareRevisionFolder() -> URL? {
        try? applicationSupportDirectory()
            .appending(path: "SpokenMargins/ShareRevisions/\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    func recordBulkShareCleanupFailure(_ reason: String, for interjection: Interjection) {
        // The reason is for a support report, not the screen (#3853).
        diagnostics[Self.marginDiagnosticKey("shareCleanupFailure", interjection)] = reason
    }
}
