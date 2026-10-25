import Foundation
import SessionKit
import SessionKitFeeds
import SessionKitPersistence

/// Following actions, discovery and refresh (#1008), moved unchanged out of Gate1AppModel.swift.
/// Stored state, observers and the discovery test seam remain in the model.
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

    func followSource() {
        let value = followedSourceURL
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let store = try self.requireStore()
                let coordinator = self.requireFollowedSourceCoordinator(store: store)
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
                await self.performFollowedSourceRefresh(force: true)
                self.diagnostics["followSourceFailure"] = nil
                self.reportConfirmation("Source followed. New entries stay in the inbox until you import them.")
            } catch {
                await self.recordFollowFailure(error)
                self.reportFailure(error)
            }
        }
    }

    /// #244: a failed Follow said only "FollowedSourceError". Record the case, host and steps.
    private func recordFollowFailure(_ error: Error) async {
        var line = FollowedSourceCoordinator.diagnosticCode(for: error)
        if let coordinator = followedSourceCoordinator { line = await coordinator.failureDiagnostic(for: error) }
        diagnostics["followSourceFailure"] = FollowedSourceMatching.stampedDiagnostic(line)
    }

    /// B1 drawer and OPML import (#463): follows a public https feed link. Throws so the caller
    /// can show the failure on the row. Returns the followed source's id, which the drawer keeps:
    /// the feed can settle on another URL. An import refreshes once at the end, not per feed.
    func followCatalogFeed(_ feedURL: String, refreshAfter: Bool = true) async throws -> String {
        let store = try requireStore()
        let coordinator = requireFollowedSourceCoordinator(store: store)
        let sourceId = try await coordinator.followFeed(urlString: feedURL).source.id
        diagnostics["followSourceFailure"] = nil
        if refreshAfter { await performFollowedSourceRefresh(force: false) }
        return sourceId
    }

    /// Read from the store: `feedSubscriptions` lags a follow until its refresh lands (#463).
    func storedFeedSubscriptions() -> [FeedSubscription] { (try? store?.loadFeedSubscriptions()) ?? feedSubscriptions }

    func followSourceCandidate(_ candidate: SourceCandidateEvidence) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let store = try self.requireStore()
                let coordinator = self.requireFollowedSourceCoordinator(store: store)
                _ = try await coordinator.follow(candidate: candidate)
                self.followedSourceCandidates = []
                self.followedSourceURL = ""
                await self.performFollowedSourceRefresh(force: true)
                self.diagnostics["followSourceFailure"] = nil
                self.reportConfirmation("Source followed. New entries stay in the inbox until you import them.")
            } catch {
                self.reportFailure(error)
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
            sourceReference: row?.sourceReference,
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
              !FollowedSourceMatching.isItemAlreadyFollowed(item, subscriptions: feedSubscriptions) else { return }
        Task { [weak self] in
            guard let self else { return }
            let coordinator = self.requireFollowedSourceCoordinator(store: store)
            var candidates: [SourceCandidateEvidence]?, failure = "none:empty"
            do { candidates = try await self.sharedFollowDiscovery(item: item, preferredURL: url, coordinator: coordinator) } catch { failure = "none:" + FollowedSourceCoordinator.diagnosticCode(for: error) }
            self.diagnostics["followOffer"] = FollowedSourceMatching.discoveryDiagnostic(
                item: item, candidates: candidates, failure: failure, subscriptions: (try? store.loadFeedSubscriptions()) ?? self.feedSubscriptions
            )
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
                let coordinator = self.requireFollowedSourceCoordinator(store: store)
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
                    self.refreshLibraryRowsInBackground(mustPublish: true)
                }
                self.feedSubscriptions = try store.loadFeedSubscriptions()
                await self.performFollowedSourceRefresh(force: true)
                self.diagnostics["followSourceFailure"] = nil
                self.reportConfirmation("Following \(candidate.source.title ?? candidate.source.host).")
            } catch {
                await self.recordFollowFailure(error)
                self.reportFailure(error)
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
        let progress = SourceFollowSuggestionPolicy.engagementProgress(
            itemId: itemId, persistedProgress: persistedProgress, snapshot: snapshot
        )
        guard SourceFollowSuggestionPolicy.isEngaged(
            progress: progress, itemHasMargin: selectedItem.id == itemId && !selectedItem.interjections.isEmpty
        ) else { return }
        sourceSuggestionChecks.insert(itemId)
        Task { [weak self] in
            guard let self else { return }
            defer { self.sourceSuggestionChecks.remove(itemId) }
            do {
                let coordinator = self.requireFollowedSourceCoordinator(store: store)
                guard !FollowedSourceMatching.isItemAlreadyFollowed(item, subscriptions: try store.loadFeedSubscriptions()) else { return }
                let candidates = try await self.sharedFollowDiscovery(
                    item: item,
                    preferredURL: url,
                    coordinator: coordinator
                )
                guard self.selectedItem.id == itemId,
                      self.screen != .playback || self.snapshot.itemId == itemId,
                      let current = try? store.loadItem(id: itemId),
                      SourceFollowSuggestionPolicy.hasSameOrigin(item, current) else {
                    self.diagnostics["sourceFollowSuggestion"] = FollowedSourceMatching.stampedDiagnostic("discarded_stale_origin")
                    return
                }
                // Following may finish while network discovery is suspended.
                let subscriptions = try store.loadFeedSubscriptions()
                self.feedSubscriptions = subscriptions
                let unfollowed = FollowedSourceMatching.uniqueUnfollowedCandidates(candidates, subscriptions: subscriptions)
                guard !FollowedSourceMatching.isItemAlreadyFollowed(current, subscriptions: subscriptions),
                      !unfollowed.isEmpty || candidates.isEmpty else {
                    self.diagnostics["sourceFollowSuggestion"] = FollowedSourceMatching.stampedDiagnostic("already_followed")
                    return
                }
                let now = Date()
                let eligible = try FollowedSourceMatching.suggestible(unfollowed, now: now) { try store.loadSourceSuggestionDecision(sourceId: $0) }
                guard !eligible.isEmpty else { return }
                for decision in SourceFollowSuggestionPolicy.promptedDecisions(for: eligible, now: now) {
                    try store.saveSourceSuggestionDecision(decision)
                }
                self.sourceFollowSuggestionItemId = itemId
                self.storedSourceFollowSuggestionCandidates = eligible
                self.diagnostics["sourceFollowSuggestion"] = FollowedSourceMatching.stampedDiagnostic("offered:\(eligible.count)")
            } catch { // #539: a background check, not a Follow tap, so no followSourceFailure line.
                self.diagnostics["sourceFollowSuggestion"] = FollowedSourceMatching.discoveryDiagnostic(
                    item: item, candidates: nil, failure: "unavailable:" + FollowedSourceCoordinator.diagnosticCode(for: error),
                    subscriptions: (try? store.loadFeedSubscriptions()) ?? self.feedSubscriptions
                )
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

    func acceptSourceFollowSuggestion(_ candidate: SourceCandidateEvidence) {
        guard sourceFollowSuggestionCandidates.contains(where: { $0.id == candidate.id }) else { return }
        let itemId = sourceFollowSuggestionItemId
        Task { [weak self] in
            guard let self else { return }
            do {
                let store = try self.requireStore()
                let coordinator = self.requireFollowedSourceCoordinator(store: store)
                let subscription = try await coordinator.follow(candidate: candidate)
                if let itemId, var item = try? store.loadItem(id: itemId) {
                    item.sourceURL = subscription.source.canonicalURL
                    item.sourceTitle = item.sourceTitle ?? subscription.source.title
                    try store.saveItem(item)
                    self.refreshLibraryRowsInBackground(mustPublish: true)
                }
                self.feedSubscriptions = try store.loadFeedSubscriptions()
                try store.saveSourceSuggestionDecision(SourceSuggestionDecision(sourceId: candidate.source.id, decision: .accepted, lastPromptAt: Date()))
                self.storedSourceFollowSuggestionCandidates = []
                await self.performFollowedSourceRefresh(force: true)
                self.diagnostics["followSourceFailure"] = nil
                self.reportConfirmation("Following \(candidate.source.title ?? candidate.source.host).")
            } catch {
                await self.recordFollowFailure(error)
                self.reportFailure(error, context: "Follow suggestion failed")
            }
        }
    }

    func deferSourceFollowSuggestion() {
        persistSourceFollowSuggestionDecision(.notNow)
    }

    func rejectSourceFollowSuggestion() {
        persistSourceFollowSuggestionDecision(.neverSuggest)
    }

    private func persistSourceFollowSuggestionDecision(_ answer: SourceFollowSuggestionPolicy.Answer) {
        guard let store else { return }
        let decisions = SourceFollowSuggestionPolicy.decisions(
            for: answer, candidates: sourceFollowSuggestionCandidates, now: Date()
        ) { try? store.loadSourceSuggestionDecision(sourceId: $0) }
        for decision in decisions {
            try? store.saveSourceSuggestionDecision(decision)
        }
        storedSourceFollowSuggestionCandidates = []
    }

    func refreshFollowedSources(force: Bool = true) {
        Task { [weak self] in await self?.performFollowedSourceRefresh(force: force) }
    }

    func performFollowedSourceRefresh(force: Bool) async {
        guard !isRefreshingFollowedSources else { return }
        isRefreshingFollowedSources = true
        defer { isRefreshingFollowedSources = false }
        do {
            let store = try requireStore()
            let coordinator = requireFollowedSourceCoordinator(store: store)
            for entry in await coordinator.refreshStale(force: force) { importFollowedSourceEntry(entry, startedByListener: false) } // "Add every new item" (#466)
            feedSubscriptions = try store.loadFeedSubscriptions()
            followedSourceEntries = try await coordinator.entries()
            diagnostics["followedSourceCount"] = "\(feedSubscriptions.count)"
            diagnostics["followedSourceEntryCount"] = "\(followedSourceEntries.count)"
        } catch {
            diagnostics["followedSourceRefresh"] = "failed:\(String(describing: type(of: error)))"
        }
    }

    func importFollowedSourceEntry(_ entry: FeedEntry, openWhenFinished: Bool = false, playWhenFinished: Bool = false, startedByListener: Bool = true) {
        guard importingFollowedSourceEntryIds.insert(entry.id).inserted else { return }
        // Opening or playing waits on a fetch; anything the listener opens or starts meanwhile wins (#2124).
        let intent = openWhenFinished || playWhenFinished ? followedPlayIntent.begin() : nil
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
                if FollowedArticleImport.holdsBackgroundImport(entry, startedByListener: startedByListener) { return }
                let lookup = await self.followedSourceCoordinator?.publisherAudioLookup(for: entry, trigger: startedByListener ? .listenerAction : .background)
                let entry = lookup?.entry ?? entry
                let imported: Bool
                // Posts with the publisher's own audio (#545) and text-only posts (#641) import as articles.
                let route = try await self.followedSourceCoordinator?.importRoute(for: entry, subscriptionKind: subscription.source.kind)
                    ?? FollowedEntryImportRoute.route(for: entry, subscriptionKind: subscription.source.kind, audio: .stored(in: entry))
                if case .episode(let importURL) = route {
                    let importedItemId = try await self.importSourceLinkInBackground(SourceLinkHandoff(
                        id: "quick-add-\(entry.id)",
                        inputURL: importURL,
                        sourceSurface: "followed_source",
                        startSession: false
                    ), feedEntry: entry, subscription: subscription)
                    let stillWanted = intent.map { self.followedPlayIntent.finish($0) } ?? false
                    imported = importedItemId != nil
                    self.recordFollowedPublisherAudio(lookup?.outcome, itemId: importedItemId, saved: false)
                    if let importedItemId, stillWanted { if openWhenFinished { self.openItem(id: importedItemId) }; if playWhenFinished { self.startItem(id: importedItemId) } } // Play now (#478)
                } else {
                    let handoff = self.listeningSignals.followedArticle(try await FollowedArticleImport.handoff(for: entry, url: url, startedByListener: startedByListener, using: self.readablePageExtractor, record: { self.diagnostics.merge($0) { _, new in new } }), for: entry)
                    let stillWanted = intent.map { self.followedPlayIntent.finish($0) } ?? false
                    let openWhenFinished = openWhenFinished && stillWanted, playWhenFinished = playWhenFinished && stillWanted
                    // With something already playing, importBrowserText only adds; Add and open still opens it (#567).
                    if openWhenFinished, !playWhenFinished, !entry.hasPublisherAudio, !self.hasActiveSession {
                        let itemId = self.importBrowserTextItem(handoff).map { self.listeningSignals.followedArticleImported($0, for: entry) }
                        self.recordFollowedPublisherAudio(lookup?.outcome, itemId: itemId, saved: false)
                        imported = itemId != nil
                    } else {
                        let itemId = self.listeningSignals.followedArticleImported(try self.importBrowserTextInBackground(handoff), for: entry)
                        let audio = try PublisherAudioDetector.publisherAudio(for: entry, itemId: itemId)?.keepingTextMap(of: store.loadPublisherAudio(itemId: itemId))
                        if let audio { try store.savePublisherAudio(audio); PublisherAudioTextMapper.start(audio, store: store, transcriber: self.sourceTranscriptionClient) { [weak self] in self?.diagnostics["publisherAudioTextMap"] = "\(itemId): \($0)" } }
                        self.recordFollowedPublisherAudio(lookup?.outcome, itemId: audio?.itemId ?? itemId, saved: audio != nil)
                        if openWhenFinished { self.openItem(id: itemId) }; if playWhenFinished { self.startItem(id: itemId) } // Play now (#478)
                        imported = true
                    }
                }
                guard imported else { return }
                try await self.followedSourceCoordinator?.setEntryState(id: entry.id, state: .imported)
                await self.performFollowedSourceRefresh(force: false)
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
            await self?.performFollowedSourceRefresh(force: false)
        }
    }
}
