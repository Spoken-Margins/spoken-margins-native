import Foundation
import SessionKit
import SessionKitPersistence

/// Call sites for "Follow this show" at the end of a friend's arrival (#4672). The rules are `FirstLaunchArrival`.
extension Gate1AppModel {
    /// The show the card would offer for the playing item right now, or nil when it should not show. Reads the
    /// stored decision off the main thread.
    func arrivalFollowCandidateToOffer() async -> SourceCandidateEvidence? {
        let arrival = FirstLaunchArrival()
        let target = canManuallyFollowSelectedSource ? FirstLaunchArrival.followTarget(from: selectedFollowOffer) : nil
        // Cheap checks first: most items are not the arrival item, and most moments are not its end.
        guard arrival.isArrivalItem(selectedItem.id), snapshot.phase == .finished, !arrival.hasOffered,
              let target, let store else { return nil }
        let sourceId = target.source.id
        let decision = try? await StoreReader(store).read { try $0.loadSourceSuggestionDecision(sourceId: sourceId) }
        let shows = FirstLaunchArrival.shouldOfferFollow(
            isArrivalItem: true,
            finished: snapshot.phase == .finished,
            canFollow: true,
            decisionExists: decision != nil,
            alreadyOffered: arrival.hasOffered
        )
        return shows ? target : nil
    }

    /// The card is on screen: the offer is spent, so it is never shown again.
    func markArrivalFollowOffered() {
        var arrival = FirstLaunchArrival()
        arrival.markOffered()
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
