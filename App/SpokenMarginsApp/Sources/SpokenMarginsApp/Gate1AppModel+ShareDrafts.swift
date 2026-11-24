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
    /// The Share Margins sheet for an item, from the item screen, the player and the Margins tab (#147, #4688). It holds
    /// the listener's own Margins from every listening pass of the item, so "Replay" on a finished episode doesn't leave
    /// the first listen's Margins out of reach. `exportSessionId` is still the newest pass with a sendable Margin, so the
    /// Export screen and `recordSessionExported` read what they always did.
    func openMarginItemExport(itemID: String, entry: ShareSheetEntry = .chooseMargins) {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_export") else { return }
        do {
            let store = try requireStore()
            selectedItem = try loadItemDetail(id: itemID, store: store)
            let sessionIds = selectedItem.sessionRows.map(\.id)
            var marginsBySession: [String: [Interjection]] = [:]
            for id in sessionIds { marginsBySession[id] = try store.loadInterjections(sessionId: id) }
            let picked = ItemShareCandidates.make(
                sessionIdsNewestFirst: sessionIds,
                marginsBySession: marginsBySession,
                // A summary row, not the item: its media says how Margins order, and the article text isn't read (#2506).
                mediaSourceType: try store.loadItemSummary(id: itemID)?.media?.sourceType.rawValue)
            guard let sessionId = picked.sessionId, !picked.margins.isEmpty else {
                return reportFailure("Record at least one Margin on it before sharing.")
            }
            exportSessionId = sessionId
            // #147: straight to the Share Margins sheet, not the Share/Export screen.
            prepareShareInterjections(candidates: picked.margins)
            if isSharingInterjectionsPresented {
                sharingState.draftsPreparedForExport = true
                sharingState.entry = entry
            }
        } catch { reportFailure(error, context: "Open export failed") }
    }

    /// "Share this Margin" on Margin details (#3211): the friend sheet with only that Margin, starting on the review.
    /// Share always means another listener, so this makes a packet and never a Markdown file. Like the Margins tab's
    /// Share it keeps the session and the current screen; only `selectedItem` follows the Margin's item, and playback
    /// pauses as it does for every share (#5050).
    func openMarginShare(_ margin: Interjection) {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_margin_share") else { return }
        guard ShareableMargins.canShare(margin) else { return reportFailure(ShareableMargins.singleMarginRefusal) }
        guard ItemShareSessionSelection.isShareable(margin) else {
            return reportFailure("This Margin can't be shared with a friend yet.")
        }
        do {
            selectedItem = try loadItemDetail(id: margin.itemId, store: requireStore())
            prepareShareInterjections(candidates: [margin], isSingleMargin: true)
            if isSharingInterjectionsPresented {
                sharingState.draftsPreparedForExport = true
                sharingState.entry = .reviewDefaults
            }
        } catch { reportFailure(error, context: "Share this Margin failed") }
    }

    func prepareShareInterjections() {
        prepareShareInterjections(candidates: selectedItem.interjections)
    }

    /// `replyBack` turns the sheet into "Share replies with <friend>" (#3221): `source` is the offer's own list, the
    /// replies start included and the listener's other new Margins start out, and nothing else is listed.
    func prepareShareInterjections(candidates source: [Interjection], replyBack: ReplyBackOffer? = nil, isSingleMargin: Bool = false) {
        cancelBulkSharePreparation()
        let candidates = source.filter {
            $0.status == "active" && $0.targetType == .item
        }
        guard !candidates.isEmpty else {
            reportFailure("Record at least one Margin on it before sharing.")
            return
        }
        let hasStarredCandidates = replyBack == nil && candidates.contains { $0.isStarredForSharing == true }
        sharingState = InterjectionSharingState(isPreparing: true)
        sharingState.replyBackTitle = replyBack?.title
        sharingState.replyBackCaption = replyBack?.caption
        sharingState.openedFrom = ShareSelectionDiagnostics.opened(
            isReplyBack: replyBack != nil, isSingleMargin: isSingleMargin, hasStarredCandidates: hasStarredCandidates)
        sharingState.draftFilter = hasStarredCandidates ? .starred : .all
        isSharingInterjectionsPresented = true
        pauseForShareFlow()
        // The summary: the sheet needs the address, the type and whether there is text, not the article (#2506).
        if let item = try? requireStore().loadItemSummary(id: selectedItem.id) {
            let reference = secureSharedItemURL(for: item)
            sharingState.itemReferenceURL = reference
            sharingState.isAppAuthoredItem = item.id == Self.welcomeSampleItemId
            // A meeting transcript is never embedded (#2997): a friend brings their own copy of the file.
            sharingState.canEmbedLinklessItem = reference == nil
                && sharedItemType(for: item) != .podcast
                && item.hasListenableText
                && SharedItemTransportRule.allowsEmbeddedText(externalReferenceType: item.externalReferenceType)
            sharingState.confirmsPrivateSharingRights = sharingState.isAppAuthoredItem
        }
        // A voice Margin with no words starts with placeholder words instead of being left out (#3027).
        // The switch starts where the sender last put it for each Margin, so a re-share keeps it (#3472). Both are keyed
        // by session and id, like the drafts, so a replay's "ij-001" doesn't take the first listen's choice (#4688).
        let lastSentReadAloud = (try? requireStore().loadLastSentReadAloud(itemId: selectedItem.id)) ?? [:]
        let lastSentLeadIns = (try? requireStore().loadLastSentLeadIns(itemId: selectedItem.id)) ?? [:]
        sharingState.drafts = candidates.map { interjection in
            ShareInterjectionDraft.initial(
                for: interjection,
                isIncluded: replyBack.map { $0.isPreselected(interjection) }
                    ?? (!hasStarredCandidates || interjection.isStarredForSharing == true),
                hasVoice: interjection.audioPath.flatMap(resolvedInterjectionAudioURL(for:)) != nil,
                itemTitle: selectedItem.title,
                lastSentReadAloud: lastSentReadAloud[interjection.sessionScopedId],
                lastSentLeadInMs: lastSentLeadIns[interjection.sessionScopedId]
            )
        }
        // A Margin whose recording was made and then lost goes as words; the row says why it has no voice (#4688),
        // in the words bulk preparation uses.
        for index in sharingState.drafts.indices {
            let interjection = sharingState.drafts[index].interjection
            if let path = interjection.audioPath, resolvedInterjectionAudioURL(for: path) == nil {
                sharingState.drafts[index].preparationMessage = ShareCleanupWords.Failure.recordingMissing.message
            }
        }
        sharingState.isPreparing = false
    }

    /// Opening the share sheet pauses whatever is sounding, and closing it leaves it paused (#5050, `ShareFlowPlayback`).
    /// Every way into Share with a Friend (the playback screen, the Margins tab, Margin details, a reply back) opens the
    /// sheet here, so this is the one place the rule is applied. `activePlaybackIsPlaying` and `pause()` read the same
    /// layers in the same order: a Margin voice first, then a Skim bridge, then the source.
    private func pauseForShareFlow() {
        guard ShareFlowPlayback.onOpen(isPlaying: activePlaybackIsPlaying) == .pause else { return }
        pauseKeepingShareSheetItem()
    }

    /// A pause from inside the share sheet. Pausing the source reloads the playing item into `selectedItem` in the
    /// background. When the sheet is for another item (a Margin from the Margins tab, Margin details or a reply back),
    /// that reload would swap the sheet's item for the playing one before Send, and the packet would name the wrong
    /// source, so the reload is dropped. The sheet's own pauses (opening it, the sender lead-in preview) come here.
    func pauseKeepingShareSheetItem() {
        pause()
        if selectedItem.id != activeItemId { _ = backgroundRefresh.beginItem() }
    }

    /// Where the sharing star's counts are kept (#4173): on this phone, as four numbers.
    var shareStarTally: ShareStarTallyStore { ShareStarTallyStore() }

    /// One `share.selection` Diagnostics line for a send tap (#4173): how the sheet started, what will be written, and how
    /// the star was used since the last send. Counts only. A retry logs again, with the same star counts when the first
    /// send reset them; the last line is the one that counts.
    func recordShareSelection(now: Date = Date()) {
        let stored = shareStarTally.load()
        let counted = stored.isEmpty ? (sharingState.starTallyAtLastSend ?? stored) : stored
        sharingState.starTallyAtLastSend = counted
        let included = SharedMarginTextRequirement.shareable(sharingState.drafts.filter(\.isIncluded), text: \.approvedTranscript).0
        let writtenIDs = Set(included.map(\.id))
        let margins = sharingState.drafts.map {
            ShareSelectionDiagnostics.Margin(isStarred: $0.interjection.isStarredForSharing == true, isWritten: writtenIDs.contains($0.id))
        }
        recordDeveloperDiagnostic(ShareSelectionDiagnostics.kind, ShareSelectionDiagnostics.fields(
            opened: sharingState.openedFrom, margins: margins,
            secondsInSheet: now.timeIntervalSince(sharingState.openedAt), tally: counted))
    }

    /// The system share sheet now shows the packet or the link, so the star counts start again (#4173). A link that
    /// fails never gets here, so its retry logs the same counts again.
    func shareSheetPresented() {
        shareStarTally.reset()
    }

    func setShareDraftIncluded(_ id: String, included: Bool) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == id }) else { return }
        sharingState.drafts[index].setIncluded(included)
    }

    func setShareDraftsIncluded(_ ids: [String], included: Bool) {
        let targetIDs = Set(ids)
        guard !targetIDs.isEmpty else { return }
        for index in sharingState.drafts.indices where targetIDs.contains(sharingState.drafts[index].id) {
            sharingState.drafts[index].setIncluded(included)
        }
    }

    func setShareDraftRepresentation(_ id: String, choice: ShareMarginRepresentationChoice) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == id }) else { return }
        let hasOriginalAudio = originalAudioURL(forShareDraft: id) != nil
        sharingState.drafts[index].setRepresentation(choice, hasOriginalAudio: hasOriginalAudio)
    }

    /// The sender asks the friend's phone to read a text Margin aloud, or not to (#3427). It means nothing for a
    /// Margin that goes as a recording; the packet carries it only for a text one, and only when it is "no".
    func setShareDraftReadAloud(_ id: String, readAloud: Bool) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == id }) else { return }
        sharingState.drafts[index].readAloud = readAloud
    }

    /// The sender's "Before your Margin" length (#4171), clamped to what a reader accepts.
    func setShareDraftLeadIn(_ id: String, ms: Int) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == id }) else { return }
        sharingState.drafts[index].leadInMs = SenderLeadIn.clamped(ms)
    }

    func setShareDraftAnchorBefore(_ id: String, value: String) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == id }) else { return }
        sharingState.drafts[index].setAnchorBefore(value)
    }

    func setShareDraftAnchorAfter(_ id: String, value: String) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == id }) else { return }
        sharingState.drafts[index].setAnchorAfter(value)
    }

    func originalAudioURL(forShareDraft id: String) -> URL? {
        sharingState.drafts.first(where: { $0.id == id })?
            .interjection.audioPath.flatMap(resolvedInterjectionAudioURL(for:))
    }

    func prepareCleanup(forShareDraft id: String) {
        guard !sharingState.isBulkPreparing else { return }
        sharingState.automaticallyCleanedDraftIDs.remove(id)
        if let index = sharingState.drafts.firstIndex(where: { $0.id == id }) {
            sharingState.drafts[index].preparationMessage = nil
        }
        recordShareEdit(for: id) { $0.automaticCleanupEnabled = true }
        analyzeAcousticPauses(forShareDraft: id)
    }

    func setCleanupDecision(draftID: String, decisionID: String, accepted: Bool) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == draftID }) else { return }
        let hasOriginalAudio = originalAudioURL(forShareDraft: draftID) != nil
        if sharingState.drafts[index].setCleanupDecision(decisionID: decisionID, accepted: accepted, hasOriginalAudio: hasOriginalAudio) {
            renderCleanup(forShareDraft: draftID)
        }
    }

    func toggleShareDraftWord(draftID: String, segmentID: String) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == draftID }) else { return }
        let hasOriginalAudio = originalAudioURL(forShareDraft: draftID) != nil
        if sharingState.drafts[index].toggleWord(segmentID: segmentID, hasOriginalAudio: hasOriginalAudio) {
            renderCleanup(forShareDraft: draftID)
        }
    }

    func isShareDraftWordDeleted(draftID: String, segmentID: String) -> Bool {
        sharingState.drafts.first(where: { $0.id == draftID })?.isWordDeleted(segmentID: segmentID) ?? false
    }

    func undoShareDraftEdit(_ id: String) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == id }) else { return }
        let hasOriginalAudio = originalAudioURL(forShareDraft: id) != nil
        if sharingState.drafts[index].undoEdit(hasOriginalAudio: hasOriginalAudio) {
            renderCleanup(forShareDraft: id)
        }
    }

    func redoShareDraftEdit(_ id: String) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == id }) else { return }
        let hasOriginalAudio = originalAudioURL(forShareDraft: id) != nil
        if sharingState.drafts[index].redoEdit(hasOriginalAudio: hasOriginalAudio) {
            renderCleanup(forShareDraft: id)
        }
    }

    func restoreOriginalShareDraft(_ id: String) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == id }) else { return }
        sharingState.automaticallyCleanedDraftIDs.remove(id)
        let hasOriginalAudio = originalAudioURL(forShareDraft: id) != nil
        sharingState.drafts[index].restoreOriginal(hasOriginalAudio: hasOriginalAudio)
    }

    func recordShareEdit(
        for id: String,
        renderCleanedAudio: Bool = true,
        mutate: (inout ShareMarginEditState) -> Void
    ) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == id }) else { return }
        let hasOriginalAudio = originalAudioURL(forShareDraft: id) != nil
        if sharingState.drafts[index].recordEdit(hasOriginalAudio: hasOriginalAudio, renderCleanedAudio: renderCleanedAudio, mutate: mutate) {
            renderCleanup(forShareDraft: id)
        }
    }

    func applyShareEditState(at index: Int, renderCleanedAudio: Bool = true) {
        guard sharingState.drafts.indices.contains(index) else { return }
        let id = sharingState.drafts[index].id
        let hasOriginalAudio = originalAudioURL(forShareDraft: id) != nil
        if sharingState.drafts[index].applyEditState(hasOriginalAudio: hasOriginalAudio, renderCleanedAudio: renderCleanedAudio) {
            renderCleanup(forShareDraft: id)
        }
    }

    private func analyzeAcousticPauses(forShareDraft id: String) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == id }),
              sharingState.drafts[index].acousticPauseDecisions.isEmpty,
              !sharingState.drafts[index].isAnalyzingPauses,
              let aligned = sharingState.drafts[index].interjection.alignedTranscript,
              let sourcePath = sharingState.drafts[index].interjection.audioPath,
              let sourceURL = resolvedInterjectionAudioURL(for: sourcePath) else { return }
        sharingState.drafts[index].isAnalyzingPauses = true
        let analyzer = shareMarginSilenceAnalysisHandler
        Task.detached { [weak self] in
            let result: ([InterjectionCleanupDecision], String?)
            do {
                result = (try analyzer(sourceURL, aligned), nil)
            } catch {
                result = ([], SafeErrorText.describe(error))
            }
            await MainActor.run {
                guard let self,
                      let current = self.sharingState.drafts.firstIndex(where: { $0.id == id }) else { return }
                self.sharingState.drafts[current].isAnalyzingPauses = false
                self.sharingState.drafts[current].acousticPauseDecisions = result.0
                if let reason = result.1 {
                    self.sharingState.drafts[current].preparationMessage = ShareCleanupWords.Failure.pauseAnalysisUnavailable.message
                    self.diagnostics[Self.marginDiagnosticKey("shareCleanupFailure", self.sharingState.drafts[current].interjection)] = "pause_analysis:\(reason)"
                }
                self.applyShareEditState(at: current)
            }
        }
    }

    private func renderCleanup(forShareDraft id: String) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == id }),
              let sourcePath = sharingState.drafts[index].interjection.audioPath,
              let sourceURL = resolvedInterjectionAudioURL(for: sourcePath),
              let decisions = sharingState.drafts[index].cleanup?.decisions,
              let root = try? applicationSupportDirectory()
                .appending(path: "SpokenMargins/ShareRevisions/\(UUID().uuidString)", directoryHint: .isDirectory) else {
            if let index = sharingState.drafts.firstIndex(where: { $0.id == id }) {
                sharingState.drafts[index].warning = ShareCleanupWords.Failure.previewNotPrepared.message
            }
            return
        }
        sharingState.drafts[index].renderGeneration += 1
        let generation = sharingState.drafts[index].renderGeneration
        sharingState.drafts[index].isPreparingCleanup = true
        let destination = root.appending(path: "cleaned-\(safePodcastEvidenceComponent(id)).m4a")
        let renderer = shareMarginAudioCleanupHandler
        Task.detached { [weak self] in
            do {
                let duration = try await renderer(sourceURL, destination, decisions)
                await MainActor.run {
                    guard let current = self?.sharingState.drafts.firstIndex(where: { $0.id == id }),
                          self?.sharingState.drafts[current].renderGeneration == generation else { return }
                    self?.sharingState.drafts[current].isPreparingCleanup = false
                    self?.sharingState.drafts[current].cleanedAudioURL = destination
                    self?.sharingState.drafts[current].cleanedAudioDurationMs = duration
                    self?.sharingState.drafts[current].representationChoice = .cleaned
                    self?.sharingState.drafts[current].warning = nil
                }
            } catch {
                await MainActor.run {
                    guard let current = self?.sharingState.drafts.firstIndex(where: { $0.id == id }),
                          self?.sharingState.drafts[current].renderGeneration == generation else { return }
                    self?.sharingState.drafts[current].isPreparingCleanup = false
                    self?.sharingState.drafts[current].cleanedAudioURL = nil
                    self?.sharingState.drafts[current].cleanedAudioDurationMs = nil
                    self?.sharingState.drafts[current].representationChoice =
                        self?.originalAudioURL(forShareDraft: id) == nil ? .textOnly : .original
                    self?.sharingState.drafts[current].preparationMessage = ShareCleanupWords.Failure.voiceNotPrepared.message
                    if let interjection = self?.sharingState.drafts[current].interjection {
                        self?.diagnostics[Self.marginDiagnosticKey("shareCleanupFailure", interjection)] = "render:\(SafeErrorText.describe(error))"
                        self?.sharingState.drafts[current].warning = ShareCleanupWords.Failure.regenerationFailed.message
                    }
                }
            }
        }
    }
}
