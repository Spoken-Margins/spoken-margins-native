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
    var sourceFollowSuggestionCandidates: [SourceCandidateEvidence] {
        guard sourceFollowSuggestionItemId == selectedItem.id,
              screen != .playback || sourceFollowSuggestionItemId == snapshot.itemId else { return [] }
        guard !FollowedSourceMatching.isSourceAlreadyFollowed(
            sourceURL: libraryItems.first(where: { $0.id == selectedItem.id })?.sourceURL,
            sourceTitle: libraryItems.first(where: { $0.id == selectedItem.id })?.sourceTitle,
            subscriptions: feedSubscriptions
        ) else { return [] }
        return FollowedSourceMatching.uniqueUnfollowedCandidates(storedSourceFollowSuggestionCandidates, subscriptions: feedSubscriptions)
    }

    func followSource() {
        let value = followedSourceURL
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let store = try self.requireStore()
                let coordinator = self.followedSourceCoordinator ?? FollowedSourceCoordinator(repository: store)
                self.followedSourceCoordinator = coordinator
                let candidates = try await coordinator.discover(urlString: value)
                self.diagnostics["followedSourceNetworkHosts"] = await coordinator.contactedHosts.sorted().joined(separator: ",")
                guard candidates.count == 1, let candidate = candidates.first, !candidate.needsConfirmation else {
                    self.followedSourceCandidates = candidates
                    self.reportConfirmation("Choose which feed to follow.")
                    return
                }
                _ = try await coordinator.follow(candidate: candidate)
                self.followedSourceCandidates = []
                self.followedSourceURL = ""
                await self.refreshFollowedSources(force: true)
                self.reportConfirmation("Source followed. New entries stay in the inbox until you import them.")
            } catch {
                await self.recordFollowFailure(error)
                self.reportFailure(error, context: "Follow source failed")
            }
        }
    }

    /// #244: a failed Follow said only "FollowedSourceError". Record the case, host and steps.
    private func recordFollowFailure(_ error: Error) async {
        guard let coordinator = followedSourceCoordinator else {
            diagnostics["followSourceFailure"] = FollowedSourceCoordinator.diagnosticCode(for: error)
            return
        }
        diagnostics["followSourceFailure"] = await coordinator.failureDiagnostic(for: error)
    }

    /// B1 drawer: follows a catalog feed (always a public https feed) in one tap. Throws so the
    /// drawer can show the failure on the row.
    /// Returns the followed source's id, which the drawer keeps: the feed can settle on another URL.
    func followCatalogFeed(_ feedURL: String) async throws -> String {
        let store = try requireStore()
        let coordinator = followedSourceCoordinator ?? FollowedSourceCoordinator(repository: store)
        followedSourceCoordinator = coordinator
        guard let candidate = try await coordinator.discover(urlString: feedURL).first else {
            throw FollowedSourceError.noFeedCandidates
        }
        let sourceId: String
        if let existing = try store.loadFeedSubscriptions().first(where: { $0.source.id == candidate.source.id }) {
            sourceId = existing.source.id
        } else {
            sourceId = try await coordinator.follow(candidate: candidate).source.id
        }
        await refreshFollowedSources(force: false)
        return sourceId
    }

    func followSourceCandidate(_ candidate: SourceCandidateEvidence) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let store = try self.requireStore()
                let coordinator = self.followedSourceCoordinator ?? FollowedSourceCoordinator(repository: store)
                self.followedSourceCoordinator = coordinator
                _ = try await coordinator.follow(candidate: candidate)
                self.followedSourceCandidates = []
                self.followedSourceURL = ""
                await self.refreshFollowedSources(force: true)
                self.reportConfirmation("Source followed. New entries stay in the inbox until you import them.")
            } catch {
                self.reportFailure(error, context: "Follow source failed")
            }
        }
    }

    func cancelFollowSourceCandidates() {
        followedSourceCandidates = []
    }

    /// Follow shows only once discovery found a feed for the selected item (#280).
    var canManuallyFollowSelectedSource: Bool {
        guard sourceFollowSuggestionCandidates.isEmpty, selectedFollowOffer != nil else { return false }
        let row = libraryItems.first(where: { $0.id == selectedItem.id })
        return !FollowedSourceMatching.isSourceAlreadyFollowed(
            sourceURL: row?.sourceURL,
            sourceTitle: row?.sourceTitle,
            subscriptions: feedSubscriptions
        )
    }

    /// Names what will be followed, and is settled when the button first appears (#243, #280).
    var manualFollowButtonTitle: String {
        guard let offer = selectedFollowOffer else { return "" }
        return isFollowingSelectedSource ? offer.followingTitle : offer.title
    }

    var manualFollowButtonSymbol: String {
        selectedFollowOffer?.symbol ?? ManualFollowPolicy.buttonSymbol(mediaType: "podcast")
    }

    /// Built from the same de-duplicated, unfollowed feeds the suggestion card lists, so the
    /// button and the card name the feed the same way.
    private var selectedFollowOffer: FollowOffer? {
        guard let found = followOffers[selectedItem.id] else { return nil }
        return ManualFollowPolicy.offer(
            itemId: found.itemId, mediaType: found.mediaType,
            candidates: FollowedSourceMatching.uniqueUnfollowedCandidates(found.candidates, subscriptions: feedSubscriptions)
        )
    }

    /// Starts feed discovery when an item opens. Follow appears when a feed is found, and never
    /// for a file, a PDF, a Listening Edition or a site with no feed (#280).
    func discoverFollowOfferIfEligible(itemId: String, store: SQLiteSessionStore) {
        guard followOffers[itemId] == nil,
              let item = try? store.loadItem(id: itemId),
              let url = ManualFollowPolicy.discoveryURL(for: item),
              !FollowedSourceMatching.isSourceAlreadyFollowed(
                sourceURL: item.sourceURL, sourceTitle: item.sourceTitle, subscriptions: feedSubscriptions
              ) else { return }
        Task { [weak self] in
            guard let self else { return }
            let coordinator = self.followedSourceCoordinator ?? FollowedSourceCoordinator(repository: store)
            self.followedSourceCoordinator = coordinator
            do {
                let candidates = try await self.sharedFollowDiscovery(item: item, preferredURL: url, coordinator: coordinator)
                self.diagnostics["followOffer"] = candidates.isEmpty ? "none:empty" : "found:\(candidates.count)"
            } catch {
                self.diagnostics["followOffer"] = "none:\(String(describing: type(of: error)))"
            }
        }
    }

    /// One discovery per item and link, shared by the Follow button, the suggestion card and the
    /// tap, so all three show the same feeds and the same name. "No feed" is kept for the session;
    /// other failures (offline, timeouts) are retried on the next open.
    private func sharedFollowDiscovery(
        item: Item,
        preferredURL: URL,
        coordinator: FollowedSourceCoordinator
    ) async throws -> [SourceCandidateEvidence] {
        let key = item.id + "\u{1f}" + preferredURL.absoluteString
        if let task = followDiscoveries[key] { return try await task.value }
        let task = Task { try await self.discoverFollowCandidates(item: item, preferredURL: preferredURL, coordinator: coordinator) }
        followDiscoveries[key] = task
        do {
            let candidates = try await task.value
            // Whichever path ran discovery, the Follow button can use what it found.
            if followOffers[item.id] == nil {
                followOffers[item.id] = ManualFollowPolicy.offer(itemId: item.id, mediaType: item.mediaType, candidates: candidates)
            }
            return candidates
        } catch FollowedSourceError.noFeedCandidates {
            throw FollowedSourceError.noFeedCandidates
        } catch {
            followDiscoveries[key] = nil
            throw error
        }
    }

    func followSelectedSource() {
        guard !isFollowingSelectedSource, let store else { return }
        let itemId = selectedItem.id
        isFollowingSelectedSource = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isFollowingSelectedSource = false }
            do {
                let item = try store.loadItem(id: itemId)
                guard let preferredURL = ManualFollowPolicy.discoveryURL(for: item) else { throw FollowedSourceError.invalidURL }
                let coordinator = self.followedSourceCoordinator ?? FollowedSourceCoordinator(repository: store)
                self.followedSourceCoordinator = coordinator
                let candidates = try await self.sharedFollowDiscovery(
                    item: item,
                    preferredURL: preferredURL,
                    coordinator: coordinator
                )
                guard let candidate = candidates.first else { throw FollowedSourceError.noFeedCandidates }
                guard candidates.count == 1, !candidate.needsConfirmation else {
                    self.followedSourceCandidates = candidates
                    self.reportConfirmation("Choose the source feed to follow.")
                    return
                }
                let subscriptionsBySourceID = Dictionary(
                    uniqueKeysWithValues: try store.loadFeedSubscriptions().map { ($0.source.id, $0) }
                )
                let subscription = if let existing = subscriptionsBySourceID[candidate.source.id] {
                    existing
                } else {
                    try await coordinator.follow(candidate: candidate)
                }
                var updated = item
                updated.sourceURL = subscription.source.canonicalURL
                updated.sourceTitle = updated.sourceTitle ?? subscription.source.title
                if updated != item {
                    try store.saveItem(updated)
                    try self.refreshLibraryRows(store: store)
                }
                self.feedSubscriptions = try store.loadFeedSubscriptions()
                await self.refreshFollowedSources(force: true)
                self.reportConfirmation("Following \(candidate.source.title ?? candidate.source.host).")
            } catch {
                await self.recordFollowFailure(error)
                self.reportFailure(error, context: "Follow source failed")
            }
        }
    }

    func offerFollowSuggestionIfEligible(itemId: String, store: SQLiteSessionStore) {
        guard !sourceSuggestionChecks.contains(itemId),
              sourceFollowSuggestionCandidates.isEmpty,
              // Files, PDFs and Listening Editions get no suggestion card either (#280).
              let item = try? store.loadItem(id: itemId), let url = ManualFollowPolicy.discoveryURL(for: item) else { return }
        // Opening Item loads its sessions synchronously; Home's display cache
        // may still be awaiting refresh or may have been superseded by navigation.
        let persistedProgress = selectedItem.id == itemId
            ? Self.preferredContinuationSession(in: selectedItem.sessions)?.completionPercent
            : libraryItems.first(where: { $0.id == itemId })?.continuationProgressPercent
        let progress = Self.sourceSuggestionEngagementProgress(
            itemId: itemId, persistedProgress: persistedProgress, snapshot: snapshot
        )
        guard progress >= 25 || (selectedItem.id == itemId && !selectedItem.interjections.isEmpty) else { return }
        sourceSuggestionChecks.insert(itemId)
        Task { [weak self] in
            guard let self else { return }
            defer { self.sourceSuggestionChecks.remove(itemId) }
            do {
                let coordinator = self.followedSourceCoordinator ?? FollowedSourceCoordinator(repository: store)
                self.followedSourceCoordinator = coordinator
                guard !FollowedSourceMatching.isSourceAlreadyFollowed(
                    sourceURL: item.sourceURL, sourceTitle: item.sourceTitle,
                    subscriptions: try store.loadFeedSubscriptions()
                ) else { return }
                let candidates = try await self.sharedFollowDiscovery(
                    item: item,
                    preferredURL: url,
                    coordinator: coordinator
                )
                guard self.selectedItem.id == itemId,
                      self.screen != .playback || self.snapshot.itemId == itemId,
                      let current = try? store.loadItem(id: itemId),
                      current.sourceURL == item.sourceURL,
                      current.externalReference == item.externalReference,
                      current.media?.url == item.media?.url else {
                    self.diagnostics["sourceFollowSuggestion"] = "discarded_stale_origin"
                    return
                }
                // Following may finish while network discovery is suspended.
                let subscriptions = try store.loadFeedSubscriptions()
                self.feedSubscriptions = subscriptions
                guard !FollowedSourceMatching.isSourceAlreadyFollowed(
                    sourceURL: current.sourceURL, sourceTitle: current.sourceTitle,
                    subscriptions: subscriptions
                ) else { return }
                let now = Date()
                let eligible = try FollowedSourceMatching.uniqueUnfollowedCandidates(candidates, subscriptions: subscriptions).filter { candidate in
                    guard let decision = try store.loadSourceSuggestionDecision(sourceId: candidate.source.id) else { return true }
                    if decision.decision == .accepted || decision.decision == .neverSuggest { return false }
                    if let suppressUntil = decision.suppressUntil, suppressUntil > now { return false }
                    if let lastPromptAt = decision.lastPromptAt,
                       now.timeIntervalSince(lastPromptAt) < 30 * 24 * 60 * 60 { return false }
                    return true
                }
                guard !eligible.isEmpty else { return }
                for candidate in eligible {
                    try store.saveSourceSuggestionDecision(SourceSuggestionDecision(
                        id: "suggestion-\(candidate.source.id)",
                        sourceId: candidate.source.id,
                        decision: .prompted,
                        decidedAt: now,
                        lastPromptAt: now
                    ))
                }
                self.sourceFollowSuggestionItemId = itemId
                self.storedSourceFollowSuggestionCandidates = eligible
                self.diagnostics["sourceFollowSuggestion"] = "offered:\(eligible.count)"
            } catch {
                self.diagnostics["sourceFollowSuggestion"] = "unavailable:\(String(describing: type(of: error)))"
                await self.recordFollowFailure(error)
            }
        }
    }

    private func discoverFollowCandidates(
        item: Item,
        preferredURL: URL,
        coordinator: FollowedSourceCoordinator
    ) async throws -> [SourceCandidateEvidence] {
        if let followCandidateDiscoveryHandler { return try await followCandidateDiscoveryHandler(item, preferredURL) }
        do {
            return try await coordinator.discover(urlString: preferredURL.absoluteString, requiringItemMembership: item.sourceURL == nil)
        } catch {
            guard let originalReference = item.externalReference,
                  let originalURL = URL(string: originalReference),
                  originalURL.scheme?.lowercased() == "https" else { throw error }
            let resolver = PublicPodcastLinkResolver()
            let canonicalFeed = try await Task.detached {
                try resolver.canonicalFeedURL(for: originalURL)
            }.value
            guard let canonicalFeed else { throw error }
            return try await coordinator.discover(urlString: canonicalFeed.absoluteString)
        }
    }

    nonisolated static func sourceSuggestionEngagementProgress(
        itemId: String,
        persistedProgress: Int?,
        snapshot: SessionSnapshot
    ) -> Int {
        let liveProgress = snapshot.itemId == itemId ? snapshot.currentPlaybackProgressPercent : 0
        return max(persistedProgress ?? 0, liveProgress)
    }

    func acceptSourceFollowSuggestion(_ candidate: SourceCandidateEvidence) {
        guard sourceFollowSuggestionCandidates.contains(where: { $0.id == candidate.id }) else { return }
        let itemId = sourceFollowSuggestionItemId
        Task { [weak self] in
            guard let self else { return }
            do {
                let store = try self.requireStore()
                let coordinator = self.followedSourceCoordinator ?? FollowedSourceCoordinator(repository: store)
                self.followedSourceCoordinator = coordinator
                let subscription = try await coordinator.follow(candidate: candidate)
                if let itemId, var item = try? store.loadItem(id: itemId) {
                    item.sourceURL = subscription.source.canonicalURL
                    item.sourceTitle = item.sourceTitle ?? subscription.source.title
                    try store.saveItem(item)
                    try self.refreshLibraryRows(store: store)
                }
                self.feedSubscriptions = try store.loadFeedSubscriptions()
                try store.saveSourceSuggestionDecision(SourceSuggestionDecision(
                    id: "suggestion-\(candidate.source.id)",
                    sourceId: candidate.source.id,
                    decision: .accepted,
                    lastPromptAt: Date()
                ))
                self.storedSourceFollowSuggestionCandidates = []
                await self.refreshFollowedSources(force: true)
                self.reportConfirmation("Following \(candidate.source.title ?? candidate.source.host).")
            } catch {
                self.reportFailure(error, context: "Follow suggestion failed")
            }
        }
    }

    func deferSourceFollowSuggestion() {
        persistSourceFollowSuggestionDecision(.notNow, suppressFor: 14 * 24 * 60 * 60)
    }

    func rejectSourceFollowSuggestion() {
        persistSourceFollowSuggestionDecision(.neverSuggest, suppressFor: nil)
    }

    private func persistSourceFollowSuggestionDecision(_ decision: SourceSuggestionDecisionKind, suppressFor interval: TimeInterval?) {
        guard let store else { return }
        let now = Date()
        for candidate in sourceFollowSuggestionCandidates {
            let prior = try? store.loadSourceSuggestionDecision(sourceId: candidate.source.id)
            try? store.saveSourceSuggestionDecision(SourceSuggestionDecision(
                id: "suggestion-\(candidate.source.id)",
                sourceId: candidate.source.id,
                decision: decision,
                decidedAt: now,
                suppressUntil: interval.map { now.addingTimeInterval($0) },
                lastPromptAt: prior?.lastPromptAt ?? now
            ))
        }
        storedSourceFollowSuggestionCandidates = []
    }

    func refreshFollowedSources(force: Bool = true) {
        Task { [weak self] in await self?.refreshFollowedSources(force: force) }
    }

    func refreshFollowedSources(force: Bool) async {
        guard !isRefreshingFollowedSources else { return }
        isRefreshingFollowedSources = true
        defer { isRefreshingFollowedSources = false }
        do {
            let store = try requireStore()
            let coordinator = followedSourceCoordinator ?? FollowedSourceCoordinator(repository: store)
            followedSourceCoordinator = coordinator
            for entry in await coordinator.refreshStale(force: force) { importFollowedSourceEntry(entry) } // "Add every new item" (#466)
            feedSubscriptions = try store.loadFeedSubscriptions()
            followedSourceEntries = try await coordinator.entries()
            diagnostics["followedSourceCount"] = "\(feedSubscriptions.count)"
            diagnostics["followedSourceEntryCount"] = "\(followedSourceEntries.count)"
        } catch {
            diagnostics["followedSourceRefresh"] = "failed:\(String(describing: type(of: error)))"
        }
    }

    func dismissFollowedSourceEntry(id: String) {
        guard let coordinator = followedSourceCoordinator else { return }
        Task { [weak self] in
            try? await coordinator.setEntryState(id: id, state: .dismissed)
            await self?.refreshFollowedSources(force: false)
        }
    }

    func importFollowedSourceEntry(_ entry: FeedEntry, openWhenFinished: Bool = false) {
        guard importingFollowedSourceEntryIds.insert(entry.id).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { self.importingFollowedSourceEntryIds.remove(entry.id) }
            do {
                guard let url = URL(string: entry.canonicalURL), url.scheme?.lowercased() == "https" else {
                    throw ReadablePageExtractionError.invalidURL
                }
                let store = try self.requireStore()
                guard let subscription = try store.loadFeedSubscriptions().first(where: { $0.id == entry.subscriptionId }) else {
                    throw FollowedSourceError.noFeedCandidates
                }
                let imported: Bool
                if subscription.source.kind == .podcastFeed {
                    let importURL = try await self.followedSourceCoordinator?.playableAudioURL(for: entry)
                        ?? entry.audioURL
                        ?? entry.canonicalURL
                    let importedItemId = try await self.importSourceLinkInBackground(SourceLinkHandoff(
                        id: "quick-add-\(entry.id)",
                        inputURL: importURL,
                        sourceSurface: "followed_source",
                        startSession: false
                    ), feedEntry: entry, subscription: subscription)
                    imported = importedItemId != nil
                    if openWhenFinished, let importedItemId { self.openItem(id: importedItemId) }

                } else {
                    let handoff = try await self.readablePageExtractor.extract(url: url)
                    self.diagnostics["followedArticleNetworkHosts"] = self.readablePageExtractor.contactedHosts.joined(separator: ",")
                    self.diagnostics["followedArticleExtractor"] = self.readablePageExtractor.lastExtractor ?? "unknown"
                    if openWhenFinished {
                        imported = self.importBrowserText(handoff)
                    } else {
                        try self.importBrowserTextInBackground(handoff)
                        imported = true
                    }
                }
                guard imported else { return }
                try await self.followedSourceCoordinator?.setEntryState(id: entry.id, state: .imported)
                await self.refreshFollowedSources(force: false)
                self.reportConfirmation("Imported \(entry.title) into the library.")
            } catch {
                self.reportFailure(error, context: "Source entry import failed")
            }
        }
    }

    func unfollowSource(id: String) {
        guard let coordinator = followedSourceCoordinator else { return }
        Task { [weak self] in
            try? await coordinator.unfollow(subscriptionId: id)
            await self?.refreshFollowedSources(force: false)
        }
    }
}
