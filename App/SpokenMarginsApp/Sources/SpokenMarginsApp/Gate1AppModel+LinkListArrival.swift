import Foundation
import SessionKit

// A link list from the listener's own AI reaches the app (#4683, Design section 2f). Four entries lead here: the Quick
// Folder (on its own, or tapped), Paste & go, and the handoff folder. `LinkListArrivalPlan` in SessionKit decides what a
// list means (its key, the links to add, the shows to suggest, the banner); this file runs it. Kept out of
// Gate1AppModel.swift.
extension Gate1AppModel {
    static let linkListOfflinePasteMessage = "You're offline. Paste it again when you're connected."

    /// How one arrival ended, for the route that ran it.
    struct LinkListArrivalResult {
        /// False when nothing was tried, so no try is counted: the phone was offline, or another import was running.
        var attempted: Bool
        /// Why nothing was tried, when `attempted` is false.
        var notTried: NotTried?
        /// No link failed. Entries the list itself got wrong (not https) never land and don't count.
        var allLanded: Bool
        /// Something reached the listener: an item was added or a show was suggested.
        var changedAnything: Bool
        /// What the listener is told. Nil when the import already reported its own failure.
        var message: String?
        var kind: LibraryCollectionImport.Summary.Kind?

        enum NotTried { case offline, busy }

        static func skipped(_ reason: NotTried) -> LinkListArrivalResult {
            LinkListArrivalResult(attempted: false, notTried: reason, allLanded: false, changedAnything: false, message: nil, kind: nil)
        }
    }

    /// The `FeedURLKey`s of the shows the listener follows, so a suggestion for one is dropped.
    var followedFeedKeys: Set<String> {
        Set(feedSubscriptions.compactMap { FeedURLKey.make($0.source.canonicalURL) })
    }

    /// One arrival at a time (2f, item 1). An entry checks this once, before it starts, and then holds
    /// `sourceImportTask` for its whole run; `runLinkListArrival` never checks again, so an entry's own task doesn't block itself.
    var linkListArrivalIsBusy: Bool {
        sourceImportTask != nil || libraryCollections.importCapture != nil
    }

    /// The follow entries of a list go to the shows the listener's AI suggested; none is followed. Returns how many are new.
    @discardableResult
    func suggestShows(from list: LinkListFile) -> Int {
        let urls = list.entries.filter(\.follow).map(\.url)
        guard !urls.isEmpty else { return 0 }
        return aiFollowSuggestionsModel.merge(
            urls: urls, listKey: LinkListArrivalPlan.key(for: list), listTitle: list.title, followed: followedFeedKeys).count
    }

    /// What Undo needs to know, and the one tap it allows.
    final class LinkListArrivalUndo {
        let key: String
        let title: String?
        /// The Quick Folder file this list came from, so Undo can stop its retries.
        let quickFolderFileID: String?
        /// The saved handoff file (the Shortcuts action's list) this list came from, so Undo can remove it and its retry count.
        let handoffEntry: LinkListHandoffFolder.Entry?
        /// The shows this arrival newly suggested, so Undo takes back those and no earlier arrival's.
        let suggestedURLs: [String]
        let collectionID: String?
        let addedItemIDs: [String]
        let libraryBefore: Set<String>
        var isUsed = false

        init(key: String, title: String?, quickFolderFileID: String?, handoffEntry: LinkListHandoffFolder.Entry? = nil, suggestedURLs: [String], collectionID: String?, addedItemIDs: [String], libraryBefore: Set<String>) {
            self.key = key
            self.title = title
            self.quickFolderFileID = quickFolderFileID
            self.handoffEntry = handoffEntry
            self.suggestedURLs = suggestedURLs
            self.collectionID = collectionID
            self.addedItemIDs = addedItemIDs
            self.libraryBefore = libraryBefore
        }
    }

    /// Runs one list through the arrival and tells the listener how it went. The caller holds the gate
    /// (`linkListArrivalIsBusy` was false when it started and it set `sourceImportTask`).
    ///
    /// - Nothing starts playing, the play queue is not changed and nothing is followed.
    /// - Offline: nothing is attempted and nothing is counted.
    /// - A titled list is one collection, named by its key, so the same list by two routes, or twice, is one collection
    ///   (the second arrival is a re-pick: it adds only what failed before).
    /// - An untitled list is loose items.
    @discardableResult
    func runLinkListArrival(
        _ list: LinkListFile, route: LinkListArrivalPlan.Route, quickFolderFileID: String? = nil, handoffEntry: LinkListHandoffFolder.Entry? = nil
    ) async -> LinkListArrivalResult {
        let plan = LinkListArrivalPlan.make(list: list, followedFeedKeys: followedFeedKeys, isOffline: connectivity.isOffline)
        guard plan.attempt == .attempt else { return .skipped(.offline) }
        // The entry checked the gate before it started, but a Files folder import can begin while it waited on a file read;
        // never take over its capture, and never count this as a failed try.
        guard libraryCollections.importCapture == nil else { return .skipped(.busy) }

        let libraryBefore = Set(libraryItems.map(\.id))
        let steps = route.onboardingSteps
        var base: LibraryCollectionImport.Summary?
        var addedItemIDs: [String] = []
        var collectionID: String?
        var collectionIsNew = false
        var failed = 0
        var importAlreadyReported = false
        var collectionDeleted = false
        if plan.hasLinks {
            if let title = plan.title {
                if let result = await importLinkListAsCollection(
                    key: plan.key, list: plan.itemList, title: title, reportsBanner: false, onboarding: steps) {
                    base = result.summary
                    addedItemIDs = result.addedItemIDs
                    collectionID = result.collectionID
                    collectionIsNew = result.isNew
                    failed = result.failed
                    collectionDeleted = result.deleted
                } else {
                    // Refused, deleted while it filled, or the collection couldn't be saved: it said why itself where it could.
                    importAlreadyReported = true
                    failed = plan.links.count
                }
            } else {
                let loose = await importLooseLinkList(plan.itemList, onboarding: steps)
                base = loose.summary
                addedItemIDs = loose.addedItemIDs
                failed = loose.failed
            }
        }
        let suggestedURLs = plan.followURLs.isEmpty ? [] : aiFollowSuggestionsModel.merge(
            urls: plan.followURLs, listKey: plan.key, listTitle: plan.title, followed: followedFeedKeys)
        let suggested = suggestedURLs.count

        let madeItems = addedItemIDs.contains { !libraryBefore.contains($0) }
        if madeItems || suggested > 0 {
            LinkListArrivalRecord(title: plan.title, date: Date()).save()
        }
        if suggested > 0 { markOnboardingSteps(steps) }
        // The listener deleted the collection while it filled: their choice, not a failure. The items that landed are in the
        // Library, nothing is retried, and no banner offers to undo what they already undid.
        guard !collectionDeleted else {
            return LinkListArrivalResult(
                attempted: true, notTried: nil, allLanded: true, changedAnything: true, message: nil, kind: nil)
        }
        guard !importAlreadyReported else {
            return LinkListArrivalResult(
                attempted: true, notTried: nil, allLanded: false, changedAnything: suggested > 0, message: nil, kind: nil)
        }
        let banner = LinkListArrivalPlan.banner(
            base: base, suggested: suggested, madeItems: madeItems, isTitled: plan.isTitled, collectionIsNew: collectionIsNew,
            mentionsFollowing: true) // Following's "Suggested by your AI" row shows them
        let result = LinkListArrivalResult(
            attempted: true, notTried: nil, allLanded: failed == 0, changedAnything: madeItems || suggested > 0,
            message: banner.message, kind: banner.kind)
        // Paste & go says a failure under its own bar; every other route, and every success, is a banner.
        if banner.kind != .failure || route != .pasteAndGo {
            presentLinkListBanner(
                banner,
                undo: banner.offersUndo
                    ? LinkListArrivalUndo(key: plan.key, title: plan.title, quickFolderFileID: quickFolderFileID, handoffEntry: handoffEntry, suggestedURLs: suggestedURLs, collectionID: collectionID,
                                          addedItemIDs: addedItemIDs, libraryBefore: libraryBefore)
                    : nil)
        }
        return result
    }

    private func presentLinkListBanner(_ banner: LinkListArrivalPlan.Banner, undo: LinkListArrivalUndo?) {
        let action = undo.map { undo in
            UserFeedbackEvent.Action(
                title: "Undo",
                accessibilityLabel: undo.title.map { "Undo adding \($0)" } ?? "Undo adding your list",
                identifier: "linkList.undo.button",
                perform: { [weak self] in self?.undoLinkListArrival(undo) })
        }
        switch banner.kind {
        case .success: reportConfirmation(banner.message, action: action)
        case .warning: reportWarning(banner.message, action: action)
        case .failure: reportFailure(banner.message)
        }
    }

    /// Undo of an arrival (2f, item 8): the items this arrival made go to Recently Deleted, which shows its own banner and
    /// its own Undo; a titled list's collection then goes quietly, and so do that list's suggestions. Items that were
    /// already in the Library stay, with their progress and Margins, and so does the item that is playing. Used up by
    /// the first tap. Refused, with nothing changed, while a Margin is recording.
    func undoLinkListArrival(_ undo: LinkListArrivalUndo) {
        guard !undo.isUsed else { return }
        guard !rejectNavigationOrSessionMutationWhileRecording("undo_link_list") else { return }
        undo.isUsed = true
        // A list the listener took back waits on Following for a tap; nothing tries it again on its own (#4274).
        if let fileID = undo.quickFolderFileID {
            linkListArrival.hold(fileID)
        }
        // The same for a saved Shortcuts list: its file and its count go now, so the next foreground doesn't add it back.
        // Removed off the main actor, and a relaunch finds nothing to retry.
        if let entry = undo.handoffEntry {
            linkListArrival.handoffRetry.clear(entry.id)
            linkListArrival.holdHandoff(entry.id)
            if let folder = try? resolvedLinkListHandoffFolder() {
                Task.detached(priority: .userInitiated) { folder.remove(entry) }
            }
        }
        aiFollowSuggestionsModel.remove(urls: undo.suggestedURLs)
        let newItemIDs = LinkListArrivalPlan.undoItemIDs(
            added: undo.addedItemIDs, libraryBefore: undo.libraryBefore, playing: snapshot.itemId)
        if !newItemIDs.isEmpty { moveItemsToTrash(newItemIDs) }
        if let collectionID = undo.collectionID {
            Task { @MainActor [weak self] in await self?.deleteCollection(collectionID: collectionID, quiet: true) }
        }
    }

    // MARK: - Paste & go

    /// Reads a pasted reply off the main actor and gives its list to the arrival. Paste & go's bar watches
    /// `linkListArrival.phase`. The caller has checked `classifyPaste` and the gate.
    func beginPastedLinkList(_ text: String, html: String?, startSession: Bool) {
        linkListArrival.phase = .reading
        sourceImportTask = Task { [weak self] in
            let recognition = await Task.detached(priority: .userInitiated) { LinkListText.find(in: text) }.value
            guard let self else { return }
            switch recognition {
            case .notALinkList:
                // The marker was only in prose around something else: the text goes the way it always did.
                self.sourceImportTask = nil
                // The add itself runs on the main actor; the label lets the hang probe name it, as Paste & go's own does.
                self.hangTelemetry.labels.scoped("pasteAndGo") {
                    self.finishPastedTextThatIsNotAList(text, html: html, startSession: startSession)
                }
            case .rejected(let message):
                self.sourceImportTask = nil
                self.linkListArrival.phase = .refused(message)
            case .linkList(let list):
                let result = await self.runLinkListArrival(list, route: .pasteAndGo)
                self.sourceImportTask = nil
                if !result.attempted {
                    self.linkListArrival.phase = .refused(
                        result.notTried == .busy ? Self.collectionImportBusyMessage : Self.linkListOfflinePasteMessage)
                } else if let message = result.message, result.kind == .failure {
                    self.linkListArrival.phase = .refused(message)
                } else if result.message == nil, !result.changedAnything {
                    // The import said why itself (a banner); the sheet stays open.
                    self.linkListArrival.phase = .refused("Nothing was added from that list.")
                } else {
                    self.linkListArrival.phase = .added
                }
            }
        }
    }

    /// Text that holds the link list marker but no list goes through Paste & go as plain text or a link, as before.
    private func finishPastedTextThatIsNotAList(_ text: String, html: String?, startSession: Bool) {
        switch pasteAndGoWithoutLinkList(text, html: html, startSession: startSession) {
        case .notAdded(let message):
            linkListArrival.phase = .refused(message)
        case .addedText, .openingShareLink:
            linkListArrival.phase = .added
        case .resolvingLink, .readingLinkList:
            // The link import shows its own progress under the bar and closes the sheet when it is done.
            linkListArrival.phase = .idle
        }
    }
}

extension LinkListArrivalPlan.Route {
    /// Onboarding steps an arrival marks. A list always counts as the listener's own source; only the Quick Folder
    /// counts as adding from Files.
    var onboardingSteps: Set<OnboardingStep> {
        switch self {
        case .quickFolderAutomatic, .quickFolderTapped: return [.addedOwnSource, .addedFromFiles]
        case .pasteAndGo, .handoffFolder: return [.addedOwnSource]
        }
    }
}
