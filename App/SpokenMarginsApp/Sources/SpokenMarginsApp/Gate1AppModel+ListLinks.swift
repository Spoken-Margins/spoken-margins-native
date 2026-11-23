import Foundation
import SessionKit
import SessionKitFeeds
import SessionKitPersistence
import SwiftUI

/// The list links (#4046 PR 7a, 7b, 8) as views watch them: a list's Updates section, the via lines, the chips' link mark
/// and the change card on Following. Before the first read `links` is empty, so nothing about links shows. The store is
/// read and written only through `ListLinksStore`, an actor, which the checker shares.
@MainActor
final class ListLinksState: ObservableObject {
    static let shared = ListLinksState()
    @Published private(set) var links: [ListLink] = []
    /// The links a **Check now** is reading, for their "Checking…" line.
    @Published private(set) var checking: Set<String> = []
    private var service: ListLinksStore?
    private var serviceStore: SQLiteSessionStore?

    /// One service per store, so the checker and two quick taps queue behind each other instead of racing.
    func service(for store: SQLiteSessionStore) -> ListLinksStore {
        if let service, serviceStore === store { return service }
        let made = ListLinksStore(store: store)
        service = made
        serviceStore = store
        return made
    }

    func publish(_ stored: [ListLink]) {
        if stored != links { links = stored }
    }

    func setChecking(_ id: String, _ isChecking: Bool) {
        if isChecking { checking.insert(id) } else { checking.remove(id) }
    }
}

/// One `ListLinkRunner` per store (#4046 PR 6), so two requests share one runner and queue behind each other instead of
/// racing. The runner, the checker and the store actor all work off the main thread.
@MainActor
final class ListLinkRunnerHolder {
    static let shared = ListLinkRunnerHolder()
    private var runner: ListLinkRunner?
    private var runnerStore: SQLiteSessionStore?

    func runner(for store: SQLiteSessionStore) -> ListLinkRunner {
        if let runner, runnerStore === store { return runner }
        let made = ListLinkRunner(
            store: ListLinksState.shared.service(for: store),
            checker: ListLinkChecker(session: ListLinkTransport.makeSession()))
        runner = made
        runnerStore = store
        return made
    }
}

/// Thin wiring from Following and the list screens to `ListLinkRunner` and `ListLinksStore`. Which triggers read a list
/// address, which links are due, and what each edit does to a link are SessionKit's (`FollowedRefreshTrigger`,
/// `ListLinkSchedule`, `ListLinkEdits`, `ListLinkPreviewPlan`).
extension Gate1AppModel {
    /// Starts reading the list addresses that are due, for a refresh a listener asked for, and returns at once. Any other
    /// trigger returns before the store or the network is touched. A failed or cancelled check changes nothing the listener
    /// sees but a status line; a change waits as a proposal for the card on Following.
    func startListLinkCheck(trigger: FollowedRefreshTrigger) {
        guard trigger.checksListLinks, let store else { return }
        let runner = ListLinkRunnerHolder.shared.runner(for: store)
        Task { [weak self] in
            _ = await runner.run(trigger: trigger)
            await self?.reloadListLinks()
        }
    }

    /// Reads the links. A failed read keeps what is shown.
    func reloadListLinks() async {
        guard let store else { return }
        let state = ListLinksState.shared
        guard let stored = try? await state.service(for: store).listLinks() else { return }
        state.publish(stored)
    }

    /// **Check now** on a list's screen: this link only, whatever the 6-hour rule says.
    func checkListLinkNow(_ link: ListLink) async {
        guard let store else { return }
        let state = ListLinksState.shared
        state.setChecking(link.id, true)
        _ = await ListLinkRunnerHolder.shared.runner(for: store).run(trigger: .checkNow, onlyLinkID: link.id)
        state.setChecking(link.id, false)
        await reloadListLinks()
    }

    /// **Add list and follow <n>** on the "Add <list>" preview: follows the ticked shows, then saves the list, named so it
    /// never merges into one of the listener's, with its link remembering what was taken and what was turned down.
    /// - Returns: the new list's id, or nil when it couldn't be saved.
    func addListFromLink(_ fetch: ListLinkFetch, plan: ListLinkPreviewPlan, ticked: Set<String>) async -> String? {
        guard let store else {
            reportFailure("The Library isn't ready yet.")
            return nil
        }
        let followed = await followProposedShows(plan.toFollow.filter { ticked.contains($0.id) }.map(\.show))
        let outcome = plan.outcome(ticked: ticked, followedFeedKeys: followed)
        let title = plan.title, url = fetch.url, etag = fetch.etag, modified = fetch.lastModified, now = Date()
        do {
            let added = try await ListLinksState.shared.service(for: store).addList(
                title: title, members: outcome.members,
                link: { listID in
                    ListLinkScreens.link(
                        listID: listID, url: url, title: title, role: .own, etag: etag, lastModified: modified,
                        accepted: outcome.accepted, rejected: outcome.rejected, now: now)
                },
                now: now)
            FollowListsState.shared.publish(added.lists)
            ListLinksState.shared.publish(added.links)
            return added.listID
        } catch {
            reportFailure(error, context: "Adding the list failed")
            return nil
        }
    }

    /// **Include list** on the preview opened from one of the listener's own lists (#4046 PR 8): the ticked shows are
    /// followed, the included list's shows join this list, and its link remembers them. A show the listener had already put
    /// in this list stays theirs: the include can never offer to remove it.
    /// - Returns: false when nothing was saved.
    func includeListFromLink(into listID: String, fetch: ListLinkFetch, plan: ListLinkPreviewPlan, ticked: Set<String>) async -> Bool {
        guard let store else {
            reportFailure("The Library isn't ready yet.")
            return false
        }
        let key = FeedURLKey.make(fetch.url)
        if ListLinkScreens.links(ofList: listID, in: ListLinksState.shared.links).contains(where: { FeedURLKey.make($0.url) == key }) {
            reportConfirmation("That list is already included.")
            return true
        }
        let followed = await followProposedShows(plan.toFollow.filter { ticked.contains($0.id) }.map(\.show))
        let outcome = plan.outcome(ticked: ticked, followedFeedKeys: followed)
        let own = FollowListsState.shared.lists.first { $0.id == listID }
        let taken = outcome.accepted.filter { !(own?.contains(feedKey: $0.feedKey, podcastGUID: $0.podcastGUID) ?? false) }
        let link = ListLinkScreens.link(
            listID: listID, url: fetch.url, title: plan.title, role: .include, etag: fetch.etag, lastModified: fetch.lastModified,
            accepted: taken, rejected: outcome.rejected, now: Date())
        do {
            let result = try await ListLinksState.shared.service(for: store).addInclude(link, members: outcome.members)
            FollowListsState.shared.publish(result.lists)
            ListLinksState.shared.publish(result.links)
            return true
        } catch {
            reportFailure(error, context: "Including the list failed")
            return false
        }
    }

    /// **Apply** on the "Changes to <list>" sheet. The ticked added shows are followed first; the store then applies the
    /// change only if it is still the one the sheet showed, so a double tap or a newer check changes nothing twice.
    func applyListChange(_ link: ListLink, reviewed: Date, tickedAdded: Set<String>, tickedRemoved: Set<String>) async {
        guard let store, let pending = link.pending, pending.checkedAt == reviewed else { return }
        let followedMembers = feedSubscriptions.map { FollowListEditing.member(for: $0) }
        let isFollowed: (ListMember) -> Bool = { member in
            followedMembers.contains { member.matches(feedKey: $0.feedKey, podcastGUID: $0.podcastGUID) }
        }
        let ticked = pending.added.filter { tickedAdded.contains($0.member.feedKey) }
        var followed = await followProposedShows(ticked.filter { !isFollowed($0.member) })
        followed.formUnion(ticked.filter { isFollowed($0.member) }.map(\.member.feedKey))
        do {
            let result = try await ListLinksState.shared.service(for: store).apply(
                linkID: link.id, reviewed: reviewed, tickedAdded: tickedAdded, tickedRemoved: tickedRemoved, followedFeedKeys: followed)
            FollowListsState.shared.publish(result.lists)
            ListLinksState.shared.publish(result.links)
        } catch {
            reportFailure(error, context: "Applying the changes failed")
        }
    }

    /// **Stop updates and keep as mine** and **Stop including**: the link goes, every show stays.
    func stopListLink(_ link: ListLink) async {
        guard let store else { return }
        do {
            ListLinksState.shared.publish(try await ListLinksState.shared.service(for: store).delete(linkID: link.id))
        } catch {
            reportFailure(error, context: "Stopping updates failed")
        }
    }

    /// A show taken out of a list by hand (`listID`), or unfollowed (nil): the links that had taken it now have it as turned
    /// down, so no check offers it back.
    func rejectFromListLinks(_ member: ListMember, listID: String?) async {
        guard let store, ListLinksState.shared.links.contains(where: { link in
            link.acceptedMembers.contains { $0.matches(feedKey: member.feedKey, podcastGUID: member.podcastGUID) }
        }) else { return }
        guard let links = try? await ListLinksState.shared.service(for: store).reject(member, listID: listID) else { return }
        ListLinksState.shared.publish(links)
    }

    /// Follows each show in turn through the normal follow path, without a refresh per show, and answers with the feed keys
    /// (as the list file wrote them) that ended up followed. One refresh follows when anything was followed.
    private func followProposedShows(_ shows: [ProposedShow]) async -> Set<String> {
        var followed = Set<String>()
        for show in shows {
            if Task.isCancelled { break }
            if (try? await followCatalogFeed(show.feedURL, refreshAfter: false)) != nil { followed.insert(show.member.feedKey) }
        }
        if !followed.isEmpty { refreshFollowedSources(force: false, trigger: .afterFollow) }
        return followed
    }
}

/// Sharing and importing lists (#4046 PR 5, 8, 13): the files are written off the main thread and handed to the share
/// sheet; an import's lists, includes and rules are saved after its follows.
extension Gate1AppModel {
    /// **Share list**: `<list>.opml`, with its includes and, when the listener switched it on, its rules.
    func shareFollowList(_ list: FollowList, includeRules: Bool) async {
        if includeRules, !ListeningRulesState.shared.loaded { await reloadListeningRules() }
        let subscriptions = feedSubscriptions, links = ListLinksState.shared.links
        let rules = includeRules ? ListeningRulesState.shared.rules : nil
        let url = await Task.detached(priority: .userInitiated) {
            Self.writeSharedFile(
                OPMLExporter.exportList(list, subscriptions: subscriptions, links: links, rules: rules),
                named: OPMLExporter.fileName(for: list.name))
        }.value
        presentSharedFile(url)
    }

    /// **Export all follows**: `Following.opml`, every followed show with its lists. Private feeds are left out.
    func exportAllFollows() async {
        let subscriptions = feedSubscriptions, lists = FollowListsState.shared.lists
        let url = await Task.detached(priority: .userInitiated) {
            Self.writeSharedFile(OPMLExporter.exportAllFollows(subscriptions, lists: lists), named: "Following.opml")
        }.value
        presentSharedFile(url)
    }

    private func presentSharedFile(_ url: URL?) {
        guard let url else {
            reportFailure("The file couldn’t be written.")
            return
        }
        #if canImport(UIKit)
        ShareFilePresenter.present(fileURL: url)
        #endif
    }

    /// In a folder of its own under the temporary directory, so the file keeps its plain name.
    nonisolated private static func writeSharedFile(_ export: OPMLExport, named name: String) -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "Shared lists", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appending(path: name, directoryHint: .notDirectory)
            try export.data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Saves what an OPML import brings beyond follows, for the shows that ended up followed: the lists switched on (each
    /// merges into the listener's list of the same name), the included lists switched on (as include links on the list the
    /// file was shared from), and the file's rules, switched off.
    /// - Returns: the result line, such as "Added 2 lists.", or nil when no list changed.
    func saveOPMLImportExtras(_ extras: OPMLImportExtras) async -> String? {
        guard let store else { return nil }
        let followed = OPMLListImporter.followedFeedKeys(preview: extras.preview, result: extras.result)
        var line: String?
        do {
            let planned = extras.preview.lists, on = extras.listsOn
            let saved = try await FollowListsState.shared.service(for: store).update { existing in
                let result = OPMLListImporter.apply(planned, switchedOn: on, followedFeedKeys: followed, existing: existing)
                return (result.lists, (result: result, before: existing))
            }
            FollowListsState.shared.publish(saved.lists)
            line = OPMLImportListWords.resultLine(saved.value.result)

            if let target = OPMLIncludeImporter.targetList(preview: extras.preview, listsOn: extras.listsOn),
               let list = saved.lists.first(where: { FollowListName.sameName($0.name, target.name) }), !extras.includesOn.isEmpty {
                // A show already in the listener's list before this import stays theirs: the include can never offer to
                // remove it (as `includeListFromLink`).
                let before = saved.value.before.first { $0.id == list.id }
                let links = OPMLIncludeImporter.links(
                    extras.preview.includes, switchedOn: extras.includesOn, listID: list.id, followedFeedKeys: followed,
                    existing: ListLinksState.shared.links
                ).map { link -> ListLink in
                    var link = link
                    link.acceptedMembers.removeAll { before?.contains(feedKey: $0.feedKey, podcastGUID: $0.podcastGUID) ?? false }
                    return link
                }
                if !links.isEmpty { ListLinksState.shared.publish(try await ListLinksState.shared.service(for: store).saveLinks(links)) }
            }

            if !extras.preview.rules.isEmpty {
                let service = ListeningRulesState.shared.service(for: store)
                let made = OPMLRulesImporter.rules(extras.preview.rules, followedFeedKeys: followed, existing: try await service.rules())
                if !made.isEmpty {
                    _ = try await service.importRules(made)
                    ListeningRulesState.shared.publish(try await service.rules())
                }
            }
        } catch {
            reportFailure(error, context: "Saving the file’s lists failed")
        }
        return line
    }
}
