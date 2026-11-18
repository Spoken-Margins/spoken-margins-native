import SessionKit
import SwiftUI

/// "Lists for <show>" (#4046 PR 2): tick the lists a followed show belongs to, or make a new one that starts with this
/// show in it. Each tick is saved as it is made, and **Done** only closes the sheet. A list only groups shows, so
/// nothing here follows or unfollows anything.
struct FollowListPickerSheet: View {
    @EnvironmentObject private var model: Gate1AppModel
    @ObservedObject private var listsState = FollowListsState.shared
    @Environment(\.dismiss) private var dismiss

    let subscription: FeedSubscription

    @State private var isNamingList = false
    @State private var newName = ""
    /// Why the last name was refused. Shown under the list, so the listener can tap New list… again and fix it.
    @State private var problem: String?
    /// A second tap on Create while the first is saving does nothing (`burst`).
    @State private var isCreating = false

    private var showTitle: String { FollowingShowRows.displayTitle(of: subscription) }

    private var lists: [FollowList] { FollowListName.chipOrder(listsState.lists) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        problem = nil
                        isNamingList = true
                    } label: {
                        Label("New list…", systemImage: "plus.circle")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .accessibilityIdentifier("followLists.new.button")
                    if let problem {
                        Text(problem)
                            .font(.subheadline)
                            .foregroundStyle(AppColors.secondaryText)
                            .accessibilityIdentifier("followLists.problem")
                    }
                }
                Section {
                    ForEach(lists) { list in
                        let isMember = list.contains(feedKey: FollowListEditing.member(for: subscription).feedKey)
                        Button {
                            Task { await model.setFollowListMembership(of: subscription, inList: list.id, isMember: !isMember) }
                        } label: {
                            HStack {
                                Text(list.name).foregroundStyle(AppColors.text)
                                Spacer()
                                if isMember {
                                    Image(systemName: "checkmark").foregroundStyle(AppColors.ochreText)
                                        .accessibilityHidden(true)
                                }
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .accessibilityAddTraits(isMember ? .isSelected : [])
                        .accessibilityValue(isMember ? "In this list" : "Not in this list")
                        .accessibilityIdentifier("followLists.row.\(list.id)")
                    }
                } footer: {
                    if lists.isEmpty {
                        Text("You have no lists yet. Make one to group the shows you follow.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppColors.bone)
            .navigationTitle(FollowListWords.sheetTitle(showTitle: showTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("followLists.done.button")
                }
            }
            .task { await model.reloadFollowLists() }
            .alert("New list", isPresented: $isNamingList) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { create() }
            }
        }
        .accessibilityIdentifier("followLists.sheet")
    }

    private func create() {
        guard !isCreating else { return }
        isCreating = true
        let name = newName
        Task {
            let refused = await model.createFollowList(named: name, adding: subscription)
            if let refused {
                problem = refused.message
            } else {
                newName = ""
                problem = nil
            }
            isCreating = false
        }
    }
}
