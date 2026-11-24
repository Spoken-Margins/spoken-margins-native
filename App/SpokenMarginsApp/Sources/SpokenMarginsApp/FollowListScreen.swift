import SessionKit
import SessionKitFeeds
import SwiftUI

/// One list's own screen (#4046 PR 3): its shows, **Add shows**, and a menu to rename or delete it. A list only groups
/// shows, so nothing here follows or unfollows anything: **Remove** takes a show out of this list only, and deleting the
/// list leaves every show followed. **Rules for this list** opens the Rules screen for the rules scoped to it (PR 10b).
/// **Share list** sends `<list>.opml` (PR 5). The Updates section shows each address the list reads, with **Check now** and
/// a way to stop (PR 7a), and **Include a list by link** adds another list's shows that keep updating (PR 8). A show taken
/// from an address reads "via <title>".
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
    @ObservedObject private var linksState = ListLinksState.shared
    @Environment(\.dismiss) private var dismiss
    @State private var sharing: FollowList?
    @State private var isAskingIncludeAddress = false
    @State private var includeAddress = ""
    @State private var includeURL: URL?
    @State private var stopping: ListLink?
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
            await model.reloadListLinks()
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
            updatesSection(list)
            Section {
                Button { beginInclude() } label: {
                    Label(ListLinkWords.includeListByLink, systemImage: "link.badge.plus")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .accessibilityIdentifier("followList.include")
                Button { share(list) } label: {
                    Label(ListLinkWords.shareList, systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .accessibilityIdentifier("followList.share")
            } footer: {
                Text(ListLinkWords.shareListFooter)
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
        .trackedSheet(item: $sharing) { list in
            ShareFollowListSheet(model: model, list: list, subscriptions: subscriptions)
        }
        .alert(ListLinkWords.includeAddressTitle, isPresented: $isAskingIncludeAddress) {
            TextField("https://", text: $includeAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Cancel", role: .cancel) {}
            Button("Continue") {
                includeURL = ListLinkWords.webURL(includeAddress)
                if includeURL == nil { model.reportFailure(ListLinkWords.notAListOrFeed) }
            }
        } message: {
            Text(ListLinkWords.includeAddressMessage)
        }
        .navigationDestination(isPresented: Binding(get: { includeURL != nil }, set: { if !$0 { includeURL = nil } })) {
            if let includeURL {
                ListLinkPreviewScreen(model: model, url: includeURL, includeInto: list) { _ in self.includeURL = nil }
                    .id(includeURL)
                    .miniPlayerKeepOut()
            }
        }
        .confirmationDialog(
            stopping.map { stopQuestion($0, list: list) } ?? "",
            isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }),
            titleVisibility: .visible,
            presenting: stopping
        ) { link in
            Button(link.role == .own ? ListLinkWords.stopUpdatesButton : ListLinkWords.stopIncluding) {
                stopping = nil
                Task { await model.stopListLink(link) }
            }
        } message: { link in
            Text(link.role == .own
                 ? ListLinkWords.stopUpdatesMessage(host: ListLinkWords.host(link.url))
                 : ListLinkWords.stopIncludingMessage(listName: list.name))
        }
        .accessibilityIdentifier("followList.screen")
    }

    /// One block per address the list reads: the address, its status line, **Check now** and a way to stop. Shown only
    /// when the list has an address or includes one.
    @ViewBuilder
    private func updatesSection(_ list: FollowList) -> some View {
        let links = ListLinkScreens.links(ofList: list.id, in: linksState.links)
        if !links.isEmpty {
            Section {
                ForEach(links) { link in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(ListLinkWords.address(link.url))
                            .foregroundStyle(AppColors.text)
                            .lineLimit(2)
                        Text(ListLinkWords.statusLine(for: link, isChecking: linksState.checking.contains(link.id)))
                            .font(.subheadline)
                            .foregroundStyle(AppColors.secondaryText)
                            .accessibilityIdentifier("followList.link.status.\(link.id)")
                        HStack(spacing: 16) {
                            Button(ListLinkWords.checkNow) { Task { await model.checkListLinkNow(link) } }
                                .disabled(linksState.checking.contains(link.id))
                                .accessibilityIdentifier("followList.link.check.\(link.id)")
                            Button(link.role == .own ? ListLinkWords.stopUpdates : ListLinkWords.stopIncluding) { stopping = link }
                                .accessibilityIdentifier("followList.link.stop.\(link.id)")
                        }
                        .buttonStyle(.borderless)
                        .font(.subheadline)
                        .frame(minHeight: 44)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text(ListLinkWords.updatesHeader)
            }
        }
    }

    private func stopQuestion(_ link: ListLink, list: FollowList) -> String {
        link.role == .own ? ListLinkWords.stopUpdatesQuestion(listName: list.name) : ListLinkWords.stopIncludingQuestion(title: link.title)
    }

    /// Straight to the share sheet when the list has no rules to offer; else the rules switch first.
    private func share(_ list: FollowList) {
        if rulesState.loaded, OPMLExporter.shareableRuleCount(list, subscriptions: subscriptions, rules: rulesState.rules) == 0 {
            Task { await model.shareFollowList(list, includeRules: false) }
        } else {
            sharing = list
        }
    }

    private func beginInclude() {
        includeAddress = ""
        isAskingIncludeAddress = true
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(AppColors.text)
                    if let via = ListLinkScreens.viaTitle(for: FollowListEditing.member(for: subscription), listID: list.id, links: linksState.links) {
                        Text(ListLinkWords.viaLine(via))
                            .font(.subheadline)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                }
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

/// **Share list** (#4046 PR 5, 13): when the list has rules that are on, a switch "Include this list’s rules (<n>)",
/// off by default, comes first; then the share sheet with `<list>.opml`. A list with no such rules goes straight to it.
struct ShareFollowListSheet: View {
    let model: Gate1AppModel
    let list: FollowList
    let subscriptions: [FeedSubscription]

    @ObservedObject private var rulesState = ListeningRulesState.shared
    @Environment(\.dismiss) private var dismiss
    @State private var includesRules = false
    @State private var isSharing = false

    private var ruleCount: Int { OPMLExporter.shareableRuleCount(list, subscriptions: subscriptions, rules: rulesState.rules) }

    var body: some View {
        NavigationStack {
            List {
                if rulesState.loaded {
                    if ruleCount > 0 {
                        Section {
                            Toggle(ListLinkWords.includeRulesSwitch(ruleCount), isOn: $includesRules)
                                .tint(AppColors.evergreen)
                                .accessibilityIdentifier("shareList.includeRules")
                        }
                    }
                    Section {
                        Button { share() } label: {
                            Label(ListLinkWords.shareList, systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .disabled(isSharing)
                        .accessibilityIdentifier("shareList.share")
                    } footer: {
                        Text(ListLinkWords.shareListFooter)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppColors.bone)
            .navigationTitle(list.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("shareList.cancel")
                }
            }
            .task {
                await model.reloadListeningRules()
                // Nothing to choose: straight to the share sheet.
                if ruleCount == 0 { share() }
            }
        }
        .presentationDetents([.medium])
        .accessibilityIdentifier("shareList.sheet")
    }

    /// The share sheet goes over whatever is on top, so this sheet closes first.
    private func share() {
        guard !isSharing else { return }
        isSharing = true
        let includeRules = includesRules
        dismiss()
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            await model.shareFollowList(list, includeRules: includeRules)
        }
    }
}
