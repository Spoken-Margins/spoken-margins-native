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

    func prepareAllIncludedShareDrafts() {
        guard !sharingState.isBulkPreparing else { return }
        let draftIDs = sharingState.drafts
            .filter(BulkShareDraftPreparation.isEligible)
            .map(\.id)
        guard !draftIDs.isEmpty else { return }

        sharingState.isBulkPreparing = true
        sharingState.bulkPreparationCompleted = 0
        sharingState.bulkPreparationTotal = draftIDs.count
        sharingState.bulkPreparationFailureCount = 0
        sharingState.errorMessage = nil
        diagnostics["bulkSharePreparation"] = "started:total=\(draftIDs.count)"

        bulkSharePreparation.start(ids: draftIDs, host: self)
    }

    func cancelBulkSharePreparation() {
        guard sharingState.isBulkPreparing || bulkSharePreparation.hasTask else { return }
        bulkSharePreparation.invalidateAndCancel()
        sharingState.isBulkPreparing = false
        BulkShareDraftPreparation.rollBackInFlightDrafts(host: self)
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

    /// One Margin's steps, with the model's two handlers. Built per Margin: it holds nothing between Margins.
    private var bulkShareDraftPreparation: BulkShareDraftPreparation {
        BulkShareDraftPreparation(analyze: shareMarginSilenceAnalysisHandler, render: shareMarginAudioCleanupHandler)
    }
}

/// The model is the bulk run's host (#969). The run holds it weakly until a run starts and strongly for the length of
/// one run, as the model's own task did before, so a model can't be released under a Margin that is being prepared.
extension Gate1AppModel: BulkPreparationHost {
    func prepareForBulkRun(itemID: String, ticket: BulkPreparationTicket) async -> Bool {
        await bulkShareDraftPreparation.prepare(itemID, ticket: ticket, host: self)
    }

    func bulkRunDidFinishOne(prepared: Bool) {
        sharingState.bulkPreparationCompleted += 1
        if !prepared {
            sharingState.bulkPreparationFailureCount += 1
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
