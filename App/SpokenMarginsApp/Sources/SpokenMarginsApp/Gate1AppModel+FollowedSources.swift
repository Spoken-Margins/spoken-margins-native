import Foundation
import SessionKit

/// The followed feeds' Manage menu actions, kept out of Gate1AppModel.swift so it doesn't grow.
extension Gate1AppModel {
    func toggleMuteSource(id: String) {
        guard let coordinator = followedSourceCoordinator,
              let subscription = feedSubscriptions.first(where: { $0.id == id }) else { return }
        Task { [weak self] in
            try? await coordinator.setMuted(subscriptionId: id, muted: subscription.state != .muted)
            self?.refreshFollowedSources(force: false)
        }
    }

    /// "Let me pick" or "Add every new item" for one feed (#466). It applies from the next refresh,
    /// to items the feed publishes after that; items already waiting in Following stay there.
    func setFeedNewItemPolicy(id: String, policy: FeedNewItemPolicy) {
        guard let coordinator = followedSourceCoordinator else { return }
        Task { [weak self] in
            try? await coordinator.setNewItemPolicy(subscriptionId: id, policy: policy)
            self?.refreshFollowedSources(force: false)
        }
    }
}
