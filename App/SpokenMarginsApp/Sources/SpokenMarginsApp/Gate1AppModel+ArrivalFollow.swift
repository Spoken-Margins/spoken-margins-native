import Foundation
import SessionKit
import SessionKitPersistence

/// Call sites for "Follow this show" at the end of a friend's arrival (#4672). The rules are `FirstLaunchArrival`.
extension Gate1AppModel {
    /// The show the card should offer for the playing item right now, or nil. When it returns a show, the offer is
    /// already spent: the claim has no `await` between its last check and the mark, so two callers can't both win.
    func arrivalFollowCandidateToOffer() async -> SourceCandidateEvidence? {
        // The playing item's id throughout; the follow target belongs to the selected item, so they must be one item.
        guard let playingId = snapshot.itemId, playingId == selectedItem.id else { return nil }
        let arrival = FirstLaunchArrival()
        let target = canManuallyFollowSelectedSource ? FirstLaunchArrival.followTarget(from: selectedFollowOffer) : nil
        // Cheap checks first: most items are not the arrival item, and most moments are not its end.
        guard arrival.isArrivalItem(playingId), snapshot.phase == .finished, !arrival.hasOffered,
              let target, let store else { return nil }
        let sourceId = target.source.id
        let stored = try? await StoreReader(store).read { try $0.loadSourceSuggestionDecision(sourceId: sourceId) }
        guard !Task.isCancelled else { return nil }
        var claim = FirstLaunchArrival()
        let shows = FirstLaunchArrival.shouldOfferFollow(
            isArrivalItem: claim.isArrivalItem(snapshot.itemId ?? ""),
            finished: snapshot.phase == .finished,
            canFollow: playingId == selectedItem.id && canManuallyFollowSelectedSource,
            decisionExists: FirstLaunchArrival.answerSuppressesOffer(stored, now: Date()),
            alreadyOffered: claim.hasOffered
        )
        guard shows else { return nil }
        claim.markOffered()
        return target
    }

    /// "Not now": the same 14-day hold the suggestion card's Not now writes.
    func declineArrivalFollow() {
        guard let store, canManuallyFollowSelectedSource,
              let target = FirstLaunchArrival.followTarget(from: selectedFollowOffer) else { return }
        let sourceId = target.source.id
        Task {
            let prior = try? await StoreReader(store).read { try $0.loadSourceSuggestionDecision(sourceId: sourceId) }
            let decision = FirstLaunchArrival.notNowDecision(for: target, now: Date()) { _ in prior }
            _ = try? await StoreReader(store).read { try $0.saveSourceSuggestionDecision(decision) }
        }
    }
}
