import SessionKit
import SwiftUI

/// One list's own screen (#4046 PR 3): its shows, **Add shows**, and a menu to rename or delete it. A list only groups
/// shows, so nothing here follows or unfollows anything: **Remove** takes a show out of this list only, and deleting the
/// list leaves every show followed. **Rules for this list** opens the Rules screen for the rules scoped to it (PR 10b).
/// Share, Updates and Include arrive with later slices.
///
/// The model is passed in, not observed, so the screen redraws for the lists and the shows it is handed, not for every
/// publish of `Gate1AppModel` (#4028).
struct FollowListScreen: View {
    let model: Gate1AppModel
    let subscriptions: [FeedSubscription]
    let artwork: FollowingArtworkCache
    let listID: String

    @ObservedObject private var listsState = FollowListsState.shared
    @ObservedObject private var rulesState = ListeningRulesState.shared
    @Environment(\.dismiss) private var dismiss
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var isDeleting = false
    @State private var addingShows: FollowList?
    /// Why the last rename was refused; shown in an alert of its own.
    @State private var problem: String?

    private var list: FollowList? { listsState.lists.first { $0.id == listID } }

    var body: some View {
        Group {
            if let list {
                content(list)
            } else {
                // Deleted here, or on another path while the screen was open: there is nothing left to show. Only this
                // branch dismisses, so one deletion pops one level.
                Color.clear.onAppear { dismiss() }
            }
        }
        .task {
            await model.reloadFollowLists()
            await model.reloadListeningRules()
        }
        // Its own alert, on the group rather than the list, so it can follow the rename alert's dismissal.
        .alert("Can’t save that name", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    private func content(_ list: FollowList) -> some View {
        let shows = FollowListScreens.shows(in: list, subscriptions: subscriptions)
        return List {
            if shows.isEmpty {
                Section {
                    Text(FollowListWords.emptyListText(listName: list.name))
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                        .accessibilityIdentifier("followList.empty")
                    addShowsButton(list)
                }
            } else {
                Section {
                    ForEach(shows) { subscription in
                        showRow(subscription, in: list)
                    }
                    addShowsButton(list)
                } header: {
                    Text(FollowListWords.showsHeader(count: shows.count))
                }
            }
            Section {
                NavigationLink {
                    RulesScreen(model: model, subscriptions: subscriptions, onlyListID: list.id)
                        .miniPlayerKeepOut()
                } label: {
                    LabeledContent("Rules for this list", value: ListeningRuleScreens.rowValue(rules: rulesState.rules, onlyList: list.id))
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("followList.rules")
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppColors.bone)
        .navigationTitle(list.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Rename", systemImage: "pencil") {
                        renameText = list.name
                        isRenaming = true
                    }
                    Button("Delete list", systemImage: "trash", role: .destructive) { isDeleting = true }
                } label: {
                    Image(systemName: "ellipsis.circle").minimumTapTarget()
                }
                .accessibilityLabel("List actions")
                .accessibilityIdentifier("followList.menu")
            }
        }
        .alert("Rename list", isPresented: $isRenaming) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { rename(list) }
        }
        .confirmationDialog(
            FollowListWords.deleteQuestion(listName: list.name),
            isPresented: $isDeleting,
            titleVisibility: .visible
        ) {
            Button("Delete list", role: .destructive) { Task { await model.deleteFollowList(id: list.id) } }
        } message: {
            Text(FollowListWords.deleteMessage)
        }
        .trackedSheet(item: $addingShows) { list in
            FollowListAddShowsSheet(model: model, subscriptions: subscriptions, listID: list.id)
        }
        .accessibilityIdentifier("followList.screen")
    }

    private func addShowsButton(_ list: FollowList) -> some View {
        Button { addingShows = list } label: {
            Label("Add shows", systemImage: "plus.circle")
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .accessibilityIdentifier("followList.addShows")
    }

    private func showRow(_ subscription: FeedSubscription, in list: FollowList) -> some View {
        let title = FollowingShowRows.displayTitle(of: subscription)
        return NavigationLink {
            ExperienceShowScreen(
                subscriptionID: subscription.id,
                lookedAtOnOpen: model.followingLooked.lookedAt[subscription.id],
                artwork: artwork
            )
            .miniPlayerKeepOut()
        } label: {
            HStack(spacing: 12) {
                ShowArtworkView(url: artwork.artworkURL(for: subscription.id), title: title, size: 44)
                Text(title)
                    .foregroundStyle(AppColors.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 44)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Task { await model.setFollowListMembership(of: subscription, inList: list.id, isMember: false) }
            } label: {
                Label("Remove", systemImage: "minus.circle")
            }
        }
        .accessibilityIdentifier("followList.show.\(subscription.id)")
    }

    private func rename(_ list: FollowList) {
        let name = renameText
        Task {
            if let refused = await model.renameFollowList(id: list.id, to: name) { problem = refused.message }
        }
    }
}

/// "Add shows to <list>" (#4046 PR 3): every followed show, Quiet ones included, in alphabetical order, with a check
/// for each one in the list. Each tick is saved as it is made, and **Done** only closes the sheet.
struct FollowListAddShowsSheet: View {
    let model: Gate1AppModel
    let subscriptions: [FeedSubscription]
    let listID: String

    @ObservedObject private var listsState = FollowListsState.shared
    @Environment(\.dismiss) private var dismiss

    private var list: FollowList? { listsState.lists.first { $0.id == listID } }

    var body: some View {
        NavigationStack {
            List {
                if let list {
                    ForEach(FollowListScreens.pickerRows(for: list, subscriptions: subscriptions)) { row in
                        Button {
                            guard let subscription = subscriptions.first(where: { $0.id == row.id }) else { return }
                            Task { await model.setFollowListMembership(of: subscription, inList: list.id, isMember: !row.isMember) }
                        } label: {
                            HStack {
                                Text(row.title).foregroundStyle(AppColors.text)
                                Spacer()
                                if row.isMember {
                                    Image(systemName: "checkmark").foregroundStyle(AppColors.ochreText)
                                        .accessibilityHidden(true)
                                }
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .accessibilityAddTraits(row.isMember ? .isSelected : [])
                        .accessibilityValue(row.isMember ? "In this list" : "Not in this list")
                        .accessibilityIdentifier("followList.pick.\(row.id)")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppColors.bone)
            .navigationTitle(FollowListWords.addShowsTitle(listName: list?.name ?? "list"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("followList.pick.done")
                }
            }
            .onChange(of: list == nil) { _, gone in if gone { dismiss() } }
        }
        .accessibilityIdentifier("followList.pick.sheet")
    }
}

/// What Following pushes for a chip's Edit list. A type of its own, so the destination can't be confused with the stack's
/// own `String` destination for a show.
struct FollowListEditTarget: Hashable {
    let id: String
}
