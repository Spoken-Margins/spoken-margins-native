import Foundation
import SessionKit
import SessionKitAudio

/// A catch-up run and the conductor it started with (#4785). Only that conductor's natural end shows the card, so a later
/// ordinary review on the same item can never end with "You're caught up".
struct ActiveCatchUp: Equatable {
    var run: CatchUpRun
    let conductor: ObjectIdentifier?
    /// The run's friend Margins whose voice started, so the end can say what stays new wherever the listener has browsed.
    var heardMarginIds: Set<String> = []
}

/// Catch-up (#4785): on an item the listener finished, a new reply to one of their own Margins plays by itself with only
/// what is new, pauses when the last reply ends and leaves a card that says no answer is owed. The rules are SessionKit's
/// (`ConversationCatchUp`, `CatchUpRun`, `PlayRule.catchUpStart`, `MarginMomentSequence.endsPaused`); this file starts
/// the run's session, feeds the run its events and hands the pinned card its words. It adds no store read beyond the one
/// `startItem` already makes.
extension Gate1AppModel {
    /// Where a catch-up run's session starts: the place to give back on Stop (the re-listen's place when one is resumed,
    /// nil for a new session).
    struct CatchUpStart {
        let returnToMediaTimeMs: Int?
    }

    /// Starts the session a catch-up run plays in (`PlayRule.catchUpStart`): a new one, even when the item is loaded, or a
    /// re-listen the listener left short of the end. A finished session, or one at 99% or more, is never moved. Nil when no
    /// session started (offline with the episode not downloaded, the Terms not answered, a recording): the replies stay new.
    func startCatchUpSession(itemId: String) -> CatchUpStart? {
        let before = snapshot.sessionId
        switch startItem(id: itemId, catchUp: true) { // `startItem`'s own read of the sessions, no second one
        case .resume(let session)?:
            guard snapshot.itemId == itemId, snapshot.sessionId == session.id else { return nil }
            return CatchUpStart(returnToMediaTimeMs: snapshot.currentMediaTimeMs)
        case .startNew?:
            guard snapshot.itemId == itemId, let started = snapshot.sessionId, started != before else { return nil }
            return CatchUpStart(returnToMediaTimeMs: nil)
        case nil:
            return nil
        }
    }

    /// Notes the run that just started, keyed to the conductor that plays it.
    func beginCatchUpRun(itemId: String, entries: [SharedMarginReview.Entry]) {
        let ids = entries.map(\.marginId)
        let run = ConversationCatchUp.make(isFinished: true, entries: entries).map {
            CatchUpRun(itemId: itemId, catchUp: $0, friendMarginIds: ids, noun: sourceNoun, title: selectedItem.title)
        } ?? CatchUpRun(
            itemId: itemId, friendMarginIds: ids, senderName: nil, replyCount: 0, allReplies: false, noun: sourceNoun,
            title: selectedItem.title)
        catchUp = ActiveCatchUp(run: run, conductor: marginMomentConductor.map { ObjectIdentifier($0) })
        diagnostics["catchUp"] = "started:margins=\(ids.count)"
    }

    /// A catch-up run for `itemId` is playing, so a second tap starts nothing (the `burst` row).
    func catchUpRunIsPlaying(itemId: String) -> Bool {
        guard let catchUp, catchUp.run.isRunning, catchUp.run.itemId == itemId else { return false }
        return catchUp.conductor != nil && catchUp.conductor == marginMomentConductor.map { ObjectIdentifier($0) }
    }

    /// One event for the run. A run that stopped or was put away is let go.
    func noteCatchUp(_ event: CatchUpRun.Event) {
        guard var current = catchUp else { return }
        current.run.handle(event)
        switch current.run.state {
        case .stopped, .dismissed:
            catchUp = nil
            diagnostics["catchUp"] = "\(current.run.state == .stopped ? "stopped" : "dismissed")"
        case .running, .ended:
            if current != catchUp { catchUp = current }
        }
    }

    /// A voice of the run started: that friend Margin is heard.
    func noteCatchUpVoiceStarted(_ marginId: String) {
        guard var current = catchUp, current.run.isRunning, current.run.friendMarginIds.contains(marginId) else { return }
        current.heardMarginIds.insert(marginId)
        catchUp = current
    }

    /// The conductor saw its last Margin end. Only the run's own conductor counts. What stays new is the run's friend
    /// Margins whose voice never started (they couldn't play, or were skipped first); the listener's own parents never count.
    func catchUpRunReachedItsEnd(_ conductor: MarginMomentConductor) {
        guard let catchUp, catchUp.run.isRunning, catchUp.conductor == ObjectIdentifier(conductor) else { return }
        let stillNew = catchUp.run.friendMarginIds.filter { !catchUp.heardMarginIds.contains($0) }.count
        noteCatchUp(.completed(stillNew: stillNew))
        diagnostics["catchUp"] = "ended:still_new=\(stillNew)"
    }

    /// The open item's catch-up second button is "Continue": `PlayRule.catchUpStart` would resume a re-listen short of the
    /// end. From the sessions the open item already holds.
    func selectedItemCatchUpResumesARelisten() -> Bool {
        if case .resume = PlayRule.catchUpStart(sessions: selectedItem.sessions, addedAgainAt: addedAgainAt(forItem: selectedItem.id)) {
            return true
        }
        return false
    }

    /// The length of each own Margin a catch-up run on the open item plays before its reply, for the big button's minutes.
    func catchUpOwnParentLengthsMs(_ catchUp: ConversationCatchUp) -> [Int] {
        catchUp.ownParentLengthsMs(ownMargins: ownMargins(itemId: selectedItem.id)) { margin in
            margin.audioPath.flatMap(resolvedInterjectionAudioURL(for:)) != nil
        }
    }

    /// The caught-up card while the run's item is the one on Now.
    var caughtUpCard: PinnedMarginCard? {
        guard let catchUp, catchUp.run.itemId == snapshot.itemId else { return nil }
        return catchUp.run.card
    }
}
