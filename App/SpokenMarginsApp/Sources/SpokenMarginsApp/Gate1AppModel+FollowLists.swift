import SessionKit
import SessionKitPersistence
import SwiftUI

/// The follow lists as views watch them (#4046 PR 2), so Following's chips, the Show screen's Lists row and the picker
/// sheet follow every change without a flag on `Gate1AppModel`. Before the first read finishes `lists` is empty, so
/// Following shows **All** with no chips, never a half-filtered list. The store is read and written only through
/// `FollowListsStore`, an actor, so no list work runs on the main thread.
@MainActor
final class FollowListsState: ObservableObject {
    static let shared = FollowListsState()
    @Published private(set) var lists: [FollowList] = []
    private var service: FollowListsStore?
    private var serviceStore: SQLiteSessionStore?

    /// One service per store, so two quick taps queue behind each other instead of racing.
    func service(for store: SQLiteSessionStore) -> FollowListsStore {
        if let service, serviceStore === store { return service }
        let made = FollowListsStore(store: store)
        service = made
        serviceStore = store
        return made
    }

    func publish(_ stored: [FollowList]) {
        if stored != lists { lists = stored }
    }

    /// The lists a show is in, in chip order.
    func lists(containing subscription: FeedSubscription) -> [FollowList] {
        FollowListFilter.lists(containing: subscription, in: lists)
    }
}

/// Thin wiring from the screens to `FollowListsStore`. The rules are in SessionKit (`FollowListEditing`,
/// `FollowListName`, `FollowingByList`).
extension Gate1AppModel {
    /// Reads the lists. A failed read keeps what is shown, so a blip doesn't empty the chips.
    func reloadFollowLists() async {
        guard let store else { return }
        let state = FollowListsState.shared
        guard let stored = try? await state.service(for: store).lists() else { return }
        state.publish(stored)
    }

    /// Makes a list, ticked for `subscription` when the listener made it from that show's sheet.
    /// - Returns: why the name was refused, or nil when the list was made.
    func createFollowList(named name: String, adding subscription: FeedSubscription?) async -> FollowListName.Problem? {
        guard let service = followListsService() else { return nil }
        do {
            let change = try await service.create(name: name, adding: subscription.map { FollowListEditing.member(for: $0) })
            FollowListsState.shared.publish(change.lists)
            return change.problem
        } catch {
            reportFailure(error, context: "Creating a list failed")
            return nil
        }
    }

    /// Makes an empty list from the Lists screen, which opens "Add shows to <list>" for it next.
    /// - Returns: why the name was refused, or the new list's id.
    func createFollowListForEditing(named name: String) async -> (problem: FollowListName.Problem?, listID: String?) {
        guard let service = followListsService() else { return (nil, nil) }
        do {
            let change = try await service.create(name: name)
            FollowListsState.shared.publish(change.lists)
            return (change.problem, change.changedListID)
        } catch {
            reportFailure(error, context: "Creating a list failed")
            return (nil, nil)
        }
    }

    /// - Returns: why the name was refused, or nil when the list was renamed.
    func renameFollowList(id: String, to name: String) async -> FollowListName.Problem? {
        guard let service = followListsService() else { return nil }
        do {
            let change = try await service.rename(id: id, to: name)
            FollowListsState.shared.publish(change.lists)
            return change.problem
        } catch {
            reportFailure(error, context: "Renaming a list failed")
            return nil
        }
    }

    /// Deleting a list never unfollows a show.
    func deleteFollowList(id: String) async {
        guard let service = followListsService() else { return }
        do {
            FollowListsState.shared.publish(try await service.delete(id: id))
        } catch {
            reportFailure(error, context: "Deleting a list failed")
        }
    }

    /// Ticks or unticks `subscription` in one list. Each tick is saved as it is made.
    func setFollowListMembership(of subscription: FeedSubscription, inList listID: String, isMember: Bool) async {
        guard let service = followListsService() else { return }
        let member = FollowListEditing.member(for: subscription)
        do {
            let lists = try await service.setMembership(of: member, inList: listID, isMember: isMember)
            FollowListsState.shared.publish(lists)
            // Taken out by hand: a list's address never offers it back (#4046 PR 7a).
            if !isMember { await rejectFromListLinks(member, listID: listID) }
        } catch {
            reportFailure(error, context: "Changing a list failed")
        }
    }

    /// Unfollow: the show leaves every list (Default 19 of #4046). Runs after the unfollow itself.
    func removeFromFollowLists(_ member: ListMember) async {
        guard let store else { return }
        let state = FollowListsState.shared
        guard let removed = try? await state.service(for: store).removeFromAllLists(feedKey: member.feedKey, podcastGUID: member.podcastGUID) else { return }
        state.publish(removed.lists)
        await rejectFromListLinks(member, listID: nil)
    }

    /// Undo after an unfollow: the show goes back into the lists it left.
    func restoreFollowListMembership(_ member: ListMember, toLists listIDs: [String]) async {
        guard let store, !listIDs.isEmpty else { return }
        let state = FollowListsState.shared
        guard let lists = try? await state.service(for: store).restore(member: member, toLists: listIDs) else { return }
        state.publish(lists)
    }

    private func followListsService() -> FollowListsStore? {
        guard let store else {
            reportFailure("The Library isn't ready yet.")
            return nil
        }
        return FollowListsState.shared.service(for: store)
    }
}
