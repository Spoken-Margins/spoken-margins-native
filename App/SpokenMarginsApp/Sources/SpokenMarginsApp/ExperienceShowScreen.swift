import SessionKit
import SwiftUI

/// A followed show's own screen (#1865): its episodes newest first, with Quiet, how new items arrive
/// and Unfollow. Opening it marks the show as looked at, which is what "N new" on Following counts from.
struct ExperienceShowScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let subscriptionID: String
    let artwork: FollowingArtworkCache
    /// When the listener last looked, as of opening: the episodes marked New stay marked while the screen is up.
    @State private var lookedAtOnOpen: Date?
    /// Built off the main thread when the entries reload; `body` only reads it.
    @State private var episodes: [FollowingShowEpisode] = []

    init(subscriptionID: String, lookedAtOnOpen: Date?, artwork: FollowingArtworkCache) {
        self.subscriptionID = subscriptionID
        self.artwork = artwork
        _lookedAtOnOpen = State(initialValue: lookedAtOnOpen)
    }

    private var subscription: FeedSubscription? {
        model.feedSubscriptions.first { $0.id == subscriptionID }
    }

    var body: some View {
        Group {
            if let subscription {
                content(for: subscription)
            } else {
                // Unfollowed (here or from a row's menu): nothing left to show.
                Color.clear.onAppear { dismiss() }
            }
        }
        .background(AppColors.bone)
        .accessibilityIdentifier("show.screen")
        .onAppear { if subscription != nil { model.markShowLooked(id: subscriptionID) } }
        .onDisappear { if subscription != nil { model.markShowLooked(id: subscriptionID) } }
        .task(id: model.followingShowRevision) {
            guard let subscription else { return }
            let entries = model.followingShowEntries, looked = lookedAtOnOpen
            episodes = await Task.detached(priority: .userInitiated) {
                FollowingShowRows.episodes(of: subscription, in: entries, lookedAt: looked)
            }.value
        }
    }

    private func content(for subscription: FeedSubscription) -> some View {
        let title = FollowingShowRows.displayTitle(of: subscription)
        let newCount = subscription.state == .muted ? 0 : episodes.filter(\.isNew).count
        return List {
            headerRows(for: subscription, title: title)
            Section {
                if episodes.isEmpty {
                    Text("No episodes yet. Pull down on Following to look for new ones.")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                        .experienceListBlock(horizontalSizeClass: horizontalSizeClass, verticalPadding: 8)
                }
                ForEach(episodes) { episode in
                    episodeRow(episode)
                        .listRowInsets(EdgeInsets(
                            top: 0,
                            leading: horizontalSizeClass == .regular ? 28 : 16,
                            bottom: 0,
                            trailing: horizontalSizeClass == .regular ? 28 : 16
                        ))
                        .listRowSeparator(.hidden)
                        .listRowBackground(AppColors.bone)
                }
            } header: {
                HStack {
                    Text("Episodes")
                        .font(.headline)
                        .foregroundStyle(AppColors.text)
                    Spacer()
                    if newCount > 0 {
                        Text("\(newCount) new")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppColors.secondaryText)
                    }
                }
                .textCase(nil)
                .experienceListBlock(horizontalSizeClass: horizontalSizeClass, verticalPadding: 8)
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        .refreshable { await model.pullToRefreshFollowing() }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Each control is its own list row, so a tap on one can never reach another (Unfollow in particular).
    @ViewBuilder
    private func headerRows(for subscription: FeedSubscription, title: String) -> some View {
        HStack(spacing: 14) {
            ShowArtworkView(url: artwork.artworkURL(for: subscription.id), title: title, size: 72)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppColors.text)
                    .accessibilityAddTraits(.isHeader)
                Text("Following since \(subscription.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .experienceListBlock(horizontalSizeClass: horizontalSizeClass, verticalPadding: 8)
        // Quiet: the show sinks to Following's collapsed group, stops counting new episodes and stops
        // appearing in the New list. It is still followed and its episodes are still listed here.
        Toggle(isOn: Binding(
            get: { subscription.state == .muted },
            set: { _ in model.toggleMuteSource(id: subscription.id) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Quiet").font(.body.weight(.semibold))
                Text("Moves this show to the bottom of Following with no count.")
                    .font(.footnote)
                    .foregroundStyle(AppColors.secondaryText)
            }
        }
        .frame(minHeight: 44)
        .tint(AppColors.evergreen)
        .accessibilityIdentifier("show.quiet")
        .experienceListBlock(horizontalSizeClass: horizontalSizeClass, verticalPadding: 4)
        Picker("New episodes", selection: Binding(
            get: { subscription.newItemPolicy ?? .letMePick },
            set: { model.setFeedNewItemPolicy(id: subscription.id, policy: $0) }
        )) {
            Text("Let me pick").tag(FeedNewItemPolicy.letMePick)
            Text("Add everything new").tag(FeedNewItemPolicy.addEveryNewItem)
        }
        .frame(minHeight: 44)
        .accessibilityIdentifier("show.newItemPolicy")
        .experienceListBlock(horizontalSizeClass: horizontalSizeClass, verticalPadding: 4)
        Button(role: .destructive) {
            model.unfollowShowWithUndo(subscription)
        } label: {
            Label(FollowingRowActions.unfollowTitle(showTitle: subscription.source.title ?? subscription.source.host), systemImage: "minus.circle")
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.borderless)
        .accessibilityHint("Stops following this show. Everything already in your Library is kept. You can undo right after.")
        .accessibilityIdentifier("show.unfollow")
        .experienceListBlock(horizontalSizeClass: horizontalSizeClass, verticalPadding: 4)
    }

    /// A waiting episode keeps the row actions Following's stream had: add, play now, dismiss. A played one is
    /// already in the Library; where an item resolves for it, it gets Add to Queue and Play (#4044).
    @ViewBuilder
    private func episodeRow(_ episode: FollowingShowEpisode) -> some View {
        if episode.isInLibrary {
            InLibraryEpisodeRow(episode: episode, itemId: model.followingLibraryEpisodes[episode.entry.id]?.itemID)
        } else {
            SourceInboxRow(candidate: .followedSource(episode.entry), artwork: artwork)
        }
    }
}

/// A show's episode that is already in the Library (#4044). With an item behind it the row has the leading swipe (Add to
/// Queue or Remove from Queue, no long swipe), a More button of at least 44 pt and a long-press menu with Play and the
/// queue action, so a listener who can't swipe precisely has a way in (#1932). The item comes from
/// `FollowingLibraryEpisodes.resolve` and never from `isInLibrary` alone: an entry marked imported whose item was
/// deleted keeps the plain row, as before.
private struct InLibraryEpisodeRow: View {
    @EnvironmentObject private var model: Gate1AppModel
    @ObservedObject private var playQueue = PlayQueueState.shared
    let episode: FollowingShowEpisode
    let itemId: String?

    var body: some View {
        if let itemId {
            let action = QueueRowAction.action(forItem: itemId, queuedItemIds: playQueue.itemIds)
            HStack(spacing: 0) {
                label
                    .accessibilityAction(named: "Play") { model.startItem(id: itemId) }
                    .accessibilityAction(named: action.title) { model.toggleQueue(itemId: itemId) }
                Menu { actions(itemId: itemId, action: action) } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(AppColors.evergreen)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("More actions")
                .accessibilityHint(episode.entry.title)
                .accessibilityIdentifier("show.episode.\(episode.entry.id).more")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(AppColors.panel)
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button { model.toggleQueue(itemId: itemId) } label: {
                    Label(action.title, systemImage: action.systemImage)
                }
                .tint(AppColors.swipeSlate)
                .accessibilityIdentifier("show.episode.\(episode.entry.id).queue")
            }
            .contextMenu { actions(itemId: itemId, action: action) }
        } else {
            label
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(AppColors.panel)
        }
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(episode.entry.title)
                .font(.headline)
                .foregroundStyle(AppColors.text)
                .lineLimit(2)
            Text("In your Library")
                .font(.caption)
                .foregroundStyle(AppColors.secondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func actions(itemId: String, action: QueueRowAction) -> some View {
        Button { model.startItem(id: itemId) } label: { Label("Play", systemImage: "play.fill") }
        Button { model.toggleQueue(itemId: itemId) } label: { Label(action.title, systemImage: action.systemImage) }
    }
}
