import SessionKit
import SessionKitFeeds
import SwiftUI

/// The "Add <list>" preview (#4046 PR 7a), and "Include <list>" when opened from one of the listener's own lists (PR 8).
/// The address is read once; every show to follow starts ticked, shows already followed join without a tick, and nothing
/// is followed or saved until the button is tapped. The words and the outcome are SessionKit's (`ListLinkWords`,
/// `ListLinkPreviewPlan`).
struct ListLinkPreviewScreen: View {
    let model: Gate1AppModel
    let url: URL
    /// The listener's list to include this one in, or nil to add it as a list of its own.
    let includeInto: FollowList?
    /// Called once the list was added or included, with the list's id.
    let finished: (String) -> Void

    private enum Phase {
        case fetching
        case preview(ListLinkFetch, ListLinkPreviewPlan)
        case adding
        case failed(String)
    }

    @State private var phase: Phase = .fetching
    @State private var ticked: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List { content }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(AppColors.bone)
            .safeAreaInset(edge: .bottom) { actions }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("listLink.preview.screen")
            .task { await fetch() }
    }

    private var title: String {
        guard case .preview(_, let plan) = phase else { return includeInto == nil ? ListLinkWords.addListByLink : ListLinkWords.includeAddressTitle }
        return includeInto == nil ? ListLinkWords.previewTitle(plan.title) : ListLinkWords.includeTitle(plan.title)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .fetching, .adding:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(ListLinkWords.fetching)
                }
                .frame(minHeight: 44)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("listLink.preview.fetching")
            }
        case .failed(let message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle")
                    .accessibilityIdentifier("listLink.preview.error")
            }
        case .preview(_, let plan):
            Section {
                Text(ListLinkWords.previewDetail(host: plan.host))
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
                if plan.leftOut {
                    Label(ListLinkWords.leftOut, systemImage: "info.circle")
                        .font(.subheadline)
                }
            }
            Section {
                if plan.toFollow.isEmpty {
                    Text("Nothing new to follow in this list.")
                }
                ForEach(plan.toFollow) { row in
                    Toggle(isOn: Binding(
                        get: { ticked.contains(row.id) },
                        set: { if $0 { ticked.insert(row.id) } else { ticked.remove(row.id) } }
                    )) {
                        showLabel(row.show)
                    }
                    .tint(AppColors.evergreen)
                    .accessibilityIdentifier("listLink.preview.toggle.\(row.show.title)")
                }
            } header: {
                Text("New (\(plan.toFollow.count))")
            }
            if !plan.alreadyFollowed.isEmpty {
                Section {
                    ForEach(plan.alreadyFollowed) { row in showLabel(row.show) }
                } header: {
                    Text("Already followed (\(plan.alreadyFollowed.count))")
                }
            }
        }
    }

    private func showLabel(_ show: ProposedShow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(show.title).lineLimit(2)
            if let via = show.viaTitle {
                Text(ListLinkWords.viaLine(via)).font(.caption).foregroundStyle(AppColors.secondaryText).lineLimit(1)
            }
        }
        .frame(minHeight: 44, alignment: .leading)
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 8) {
            if case .preview(let fetched, let plan) = phase {
                Button {
                    add(fetched, plan: plan)
                } label: {
                    Text(ListLinkWords.addButton(toFollow: ticked.count, including: includeInto != nil))
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .filledActionButton()
                .accessibilityIdentifier("listLink.preview.add")
            }
            if case .adding = phase {
                EmptyView()
            } else {
                Button { dismiss() } label: {
                    Text("Cancel").frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                }
                .accessibilityIdentifier("listLink.preview.cancel")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// One read; leaving the screen cancels it.
    private func fetch() async {
        guard case .fetching = phase else { return }
        // A session with a delegate lives until it is invalidated.
        let session = ListLinkTransport.makeSession()
        defer { session.finishTasksAndInvalidate() }
        do {
            let fetched = try await ListLinkChecker(session: session).fetch(url)
            let plan = ListLinkPreviewPlan(
                shows: fetched.resolution.shows, documentTitle: fetched.resolution.title, url: fetched.url,
                leftOut: fetched.resolution.leftOut, subscriptions: model.feedSubscriptions)
            ticked = plan.defaultSelection
            phase = .preview(fetched, plan)
        } catch let failure as ListLinkFetchFailure {
            phase = .failed(failure.message)
        } catch {
            // Cancelled: the screen is gone.
        }
    }

    private func add(_ fetched: ListLinkFetch, plan: ListLinkPreviewPlan) {
        guard case .preview = phase else { return }
        phase = .adding
        let ticked = ticked
        Task {
            if let list = includeInto {
                if await model.includeListFromLink(into: list.id, fetch: fetched, plan: plan, ticked: ticked) {
                    finished(list.id)
                } else {
                    phase = .preview(fetched, plan)
                }
            } else if let id = await model.addListFromLink(fetched, plan: plan, ticked: ticked) {
                finished(id)
            } else {
                phase = .preview(fetched, plan)
            }
        }
    }
}

/// The "Changes to <list>" sheet (#4046 PR 7b): what a list's address added and removed since the listener last took it.
/// Every row starts unticked. **Apply** always works: unticked added shows are never offered again, unticked removed shows
/// stay as the listener's own. **Cancel** leaves the change waiting.
struct ListChangesSheet: View {
    let model: Gate1AppModel
    let link: ListLink
    let listName: String
    let subscriptions: [FeedSubscription]

    @State private var tickedAdded: Set<String> = []
    @State private var tickedRemoved: Set<String> = []
    @State private var isApplying = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let proposal = link.pending {
                    Section {
                        Text(ListLinkWords.changesHeader(host: ListLinkWords.host(link.url), checkedAt: proposal.checkedAt))
                            .font(.subheadline)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    if !proposal.added.isEmpty {
                        Section {
                            ForEach(proposal.added, id: \.member.feedKey) { show in
                                tickRow(show.title, detail: show.viaTitle.map(ListLinkWords.viaLine), key: show.member.feedKey, in: $tickedAdded)
                            }
                        } header: {
                            HStack {
                                Text(ListLinkWords.addedHeader(proposal.added.count))
                                Spacer()
                                Button(ListLinkWords.tickAll) { tickedAdded = Set(proposal.added.map(\.member.feedKey)) }
                                    .font(.subheadline)
                                    .accessibilityIdentifier("listChanges.tickAll")
                            }
                        } footer: {
                            Text(ListLinkWords.addedFooter)
                        }
                    }
                    if !proposal.removed.isEmpty {
                        Section {
                            ForEach(proposal.removed, id: \.feedKey) { member in
                                tickRow(title(of: member), detail: nil, key: member.feedKey, in: $tickedRemoved)
                            }
                        } header: {
                            Text(ListLinkWords.removedHeader(proposal.removed.count))
                        } footer: {
                            Text(ListLinkWords.removedFooter)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(AppColors.bone)
            .navigationTitle(ListLinkWords.changesTitle(listName: listName))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("listChanges.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(ListLinkWords.apply) { apply() }
                        .disabled(isApplying || link.pending == nil)
                        .accessibilityIdentifier("listChanges.apply")
                }
            }
        }
    }

    private func tickRow(_ title: String, detail: String?, key: String, in ticked: Binding<Set<String>>) -> some View {
        Button {
            if ticked.wrappedValue.contains(key) { ticked.wrappedValue.remove(key) } else { ticked.wrappedValue.insert(key) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(AppColors.text).lineLimit(2)
                    if let detail { Text(detail).font(.caption).foregroundStyle(AppColors.secondaryText) }
                }
                Spacer()
                Image(systemName: ticked.wrappedValue.contains(key) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(ticked.wrappedValue.contains(key) ? AppColors.evergreen : AppColors.secondaryText)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(ticked.wrappedValue.contains(key) ? .isSelected : [])
    }

    /// A removed show is one the listener follows, so its name comes from there.
    private func title(of member: ListMember) -> String {
        subscriptions.first { FollowListEditing.member(for: $0).matches(feedKey: member.feedKey, podcastGUID: member.podcastGUID) }
            .map(FollowingShowRows.displayTitle(of:)) ?? ListLinkWords.address(member.feedKey)
    }

    private func apply() {
        guard !isApplying, let reviewed = link.pending?.checkedAt else { return }
        isApplying = true
        let added = tickedAdded, removed = tickedRemoved
        Task {
            await model.applyListChange(link, reviewed: reviewed, tickedAdded: added, tickedRemoved: removed)
            dismiss()
        }
    }
}
