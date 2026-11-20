import SessionKit
import SwiftUI

/// The Lists screen, pushed from Following's toolbar (#4046 PR 3): every list with how many shows it holds, **New list**,
/// and a swipe to delete. Adding a list by link, exporting and Rules arrive with later slices. A list only groups shows,
/// so deleting one leaves every show followed.
struct FollowListsScreen: View {
    let model: Gate1AppModel
    let subscriptions: [FeedSubscription]
    let artwork: FollowingArtworkCache

    @ObservedObject private var listsState = FollowListsState.shared
    @State private var isNaming = false
    @State private var newName = ""
    /// Why the last name was refused; shown in an alert of its own.
    @State private var problem: String?
    @State private var deleting: FollowList?
    /// The list just made: its "Add shows to <list>" sheet opens at once.
    @State private var addingShows: FollowList?
    /// A second tap on Create while the first is saving does nothing (`burst`).
    @State private var isCreating = false

    var body: some View {
        // Its own alert, on the outer view rather than the list, so it can follow the New list alert's dismissal.
        listBody
            .alert("Can’t save that name", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(problem ?? "")
            }
    }

    private var listBody: some View {
        let rows = FollowListScreens.overviewRows(lists: listsState.lists, subscriptions: subscriptions)
        return List {
            if rows.isEmpty {
                SMExperienceEmptyState(
                    systemImage: "list.bullet",
                    title: FollowListWords.emptyListsTitle,
                    detail: FollowListWords.emptyListsDetail,
                    actionTitle: "New list"
                ) { beginNaming() }
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("followLists.empty")
            } else {
                Section {
                    ForEach(rows) { row in
                        NavigationLink {
                            FollowListScreen(model: model, subscriptions: subscriptions, artwork: artwork, listID: row.id)
                                .miniPlayerKeepOut()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name).foregroundStyle(AppColors.text)
                                Text(row.subtitle)
                                    .font(.subheadline)
                                    .foregroundStyle(AppColors.secondaryText)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .accessibilityLabel(row.accessibilityLabel)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                deleting = listsState.lists.first { $0.id == row.id }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .accessibilityIdentifier("followLists.row.\(row.id)")
                    }
                }
                Section {
                    Button { beginNaming() } label: {
                        Label("New list", systemImage: "plus.circle")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .accessibilityIdentifier("followLists.new")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppColors.bone)
        .navigationTitle(FollowListWords.listsTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.reloadFollowLists() }
        .alert("New list", isPresented: $isNaming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { create() }
        }
        // `presenting:` hands the button the list itself, so it never depends on the order in which the binding is
        // reset and the action runs.
        .confirmationDialog(
            FollowListWords.deleteQuestion(listName: deleting?.name ?? "this list"),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { list in
            Button("Delete list", role: .destructive) {
                deleting = nil
                Task { await model.deleteFollowList(id: list.id) }
            }
        } message: { _ in
            Text(FollowListWords.deleteMessage)
        }
        .trackedSheet(item: $addingShows) { list in
            FollowListAddShowsSheet(model: model, subscriptions: subscriptions, listID: list.id)
        }
        .accessibilityIdentifier("followLists.screen")
    }

    private func beginNaming() {
        newName = ""
        isNaming = true
    }

    private func create() {
        guard !isCreating else { return }
        isCreating = true
        let name = newName
        Task {
            let made = await model.createFollowListForEditing(named: name)
            if let refused = made.problem {
                problem = refused.message
            } else if let id = made.listID {
                addingShows = listsState.lists.first { $0.id == id }
            }
            isCreating = false
        }
    }
}
