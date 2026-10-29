import Foundation
import SessionKit

/// What the first-run drawer's Done plays (#2851), kept out of `Gate1AppModel.swift`.
extension Gate1AppModel {
    /// The first pick's newest episode or latest post, else the Welcome sample. The play goes through
    /// `importFollowedSourceEntry`, the same path as ▶ on a Following row, so the Terms sheet and any
    /// download appear in the flow and resume the play; nothing the listener picked is undone by them.
    func startFirstListen(pickedSourceIds: [String]) async {
        if !pickedSourceIds.isEmpty {
            reportConfirmation("Getting your first listen ready.")
            var entry = await firstListenEntry(pickedSourceIds: pickedSourceIds)
            if entry == nil {
                // A follow whose refresh was skipped (one was already running) has no entries yet.
                await performFollowedSourceRefresh(force: true)
                entry = await firstListenEntry(pickedSourceIds: pickedSourceIds)
            }
            if let entry {
                importFollowedSourceEntry(entry, playWhenFinished: true)
                return
            }
        }
        guard libraryItems.contains(where: { $0.id == Self.welcomeSampleItemId }) else { return }
        startItem(id: Self.welcomeSampleItemId)
    }

    private func firstListenEntry(pickedSourceIds: [String]) async -> FeedEntry? {
        guard let store else { return nil }
        return await Task.detached(priority: .userInitiated) {
            let subscriptions = (try? store.loadFeedSubscriptions()) ?? []
            let entries = subscriptions.flatMap { (try? store.loadFeedEntries(subscriptionId: $0.id)) ?? [] }
            return FirstRunListenChoice.entry(forPickedSourceIds: pickedSourceIds, subscriptions: subscriptions, entries: entries)
        }.value
    }
}
