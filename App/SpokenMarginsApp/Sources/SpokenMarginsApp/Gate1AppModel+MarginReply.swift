import Foundation
import SessionKit

/// Replying to a friend's shared Margin (#473): the Reply action starts the normal recorder, or the written
/// Margin screen, at the Margin's position in the listener's copy, and the saved Margin carries the link to its
/// parent. The link rides the capture request (see `MarginCaptureRequest.replyTo`), so every way of finishing
/// the recording keeps it.
extension Gate1AppModel {
    /// The shared Margin the recording on screen answers, for the recording screen to name.
    var pendingMarginReply: MarginReplyDraft? { marginCapture.pendingReply }

    /// The same, with the listener's switch to an independent Margin (#473).
    var pendingMarginReplyChoice: MarginReplyChoice { marginCapture.replyChoice }

    /// Reply to `row` by voice, or in writing. The source moves to the Margin's position first, so the reply is
    /// anchored to the moment it answers.
    func replyToSharedMargin(_ row: SharedMarginRow, inWriting: Bool) {
        guard !rejectNavigationOrSessionMutationWhileRecording("reply_to_shared_margin") else { return }
        guard let itemID = row.layer.itemId else {
            reportFailure("The source for this shared Margin isn't in your Library.")
            return
        }
        guard let place = SharedMarginReplyPlace(row.interjection) else {
            reportFailure("This shared Margin has no position in your copy, so a reply can't be placed.")
            return
        }
        endMarginMoment()
        if playingImportedCommentary != nil { stopImportedCommentaryPlayback(resumeSource: false) }
        if snapshot.itemId != itemID || !hasActiveSession { startItem(id: itemID) }
        guard snapshot.itemId == itemID else { return }
        switch place {
        case .media(let timeMs): guard seekMedia(toMediaTimeMs: timeMs) else { return }
        case .text(let charOffset): guard seekText(toCharOffset: charOffset) else { return }
        }
        screen = .playback
        let reply = MarginReplyDraft(parent: row.interjection, in: row.layer)
        if inWriting {
            beginWrittenMargin(answering: reply)
            return
        }
        marginCapture.setPendingReply(reply)
        beginInterjection()
        // The tap was refused (a save under way, Skim): nothing will clear the link, so it goes now.
        if !isRequestingRecordingPermission && !snapshot.isRecording { marginCapture.setPendingReply(nil) }
    }

    /// Every active Margin of `itemId` in thread order, for the lists and the Timeline.
    func marginThreadRows(itemId: String) -> [MarginThreadPresentation.Row] {
        MarginThreadPresentation.rows(
            itemId: itemId,
            localMargins: marginRows.map(\.interjection),
            layers: sharedMarginRows.map(\.layer),
            importedMargins: sharedMarginRows.map(\.interjection)
        )
    }

    /// The Margin a reply answers, when it is in this Library.
    func marginParentContext(of reference: MarginReference, itemId: String) -> MarginThreadPresentation.ParentContext? {
        MarginThreadPresentation.parentContext(
            of: reference,
            itemId: itemId,
            localMargins: marginRows.map(\.interjection),
            layers: sharedMarginRows.map(\.layer),
            importedMargins: sharedMarginRows.map(\.interjection)
        )
    }

    /// Plays the Margin a reply answers, with the same lead-in as tapping it anywhere else.
    func playMarginParent(_ context: MarginThreadPresentation.ParentContext) {
        switch context.parent {
        case .local(let id):
            if let row = marginRows.first(where: { $0.interjection.id == id }) { _ = playMarginMoment(row) }
        case .imported(let id):
            if let row = sharedMarginRows.first(where: { $0.interjection.id == id }) { playSharedMarginMoment(row) }
        }
    }

    // MARK: A Margin recorded over a shared Margin, or just after, answers it (#473, owner 2026-10-25)

    /// The shared Margin a Margin started now answers: the one playing over it or heard in the last few seconds.
    func sharedMarginThisMarginAnswers() -> MarginReplyDraft? {
        guard let itemId = snapshot.itemId else { return nil }
        return marginCapture.sharedReplyMemory.reply(forItem: itemId, at: Date())
    }

    /// Sets the suggestion for a spoken Margin unless Reply already chose one. The recording screen says whom it answers.
    func suggestSharedMarginReply() {
        guard !marginCapture.replyChoice.canToggle, let draft = sharedMarginThisMarginAnswers() else { return }
        marginCapture.setPendingReply(draft)
    }

    /// A Margin started from the Lock Screen, headphones or a Live Activity goes through the engine without a link;
    /// once it is recording, it names its screen and takes the suggestion the same way.
    func compactRecordingBegan() {
        marginCapture.setPresentationContext(RecordingPresentationContext(snapshot: snapshot, startedAt: Date()))
        suggestSharedMarginReply()
        engine?.changeReplyOfCurrentCapture(to: marginCapture.pendingReply?.link)
    }

    /// Switches the Margin being recorded or written between a reply and an independent Margin.
    func toggleReplyOfCurrentMargin() {
        if writtenMarginDraft != nil {
            marginCapture.toggleDraftReply()
            engine?.changeReplyOfCurrentCapture(to: writtenMarginDraft?.reply?.link)
        } else if snapshot.isRecording {
            marginCapture.toggleReplyChoice()
            engine?.changeReplyOfCurrentCapture(to: marginCapture.pendingReply?.link)
        }
    }

    /// A saved Margin becomes independent, or a reply again (`link` is the Margin it answered). Only the link
    /// changes. The store is read and written off the main thread (#2256); Margins already shared keep the link they carried.
    func setSavedMarginReply(_ interjection: Interjection, to link: MarginReplyLink?) {
        guard let store else { return }
        let id = interjection.id, sessionId = interjection.sessionId
        Task { @MainActor [weak self] in
            do {
                let found = try await Self.offMain {
                    try store.updateReply(ofInterjection: id, sessionId: sessionId, to: link)
                }
                if !found { throw SessionKitError.persistenceFailed("margin_reply_missing") }
                self?.hangTelemetry.labels.scoped("savedMarginReply.refresh") {
                    self?.refreshSelectedItem()
                    self?.refreshMarginRows()
                }
            } catch {
                self?.reportFailure(error, context: "Couldn't change this Margin's reply")
            }
        }
    }
}
