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
        .onAppear { model.markShowLooked(id: subscriptionID) }
        .onDisappear { model.markShowLooked(id: subscriptionID) }
    }

    private func content(for subscription: FeedSubscription) -> some View {
        let title = FollowingShowRows.displayTitle(of: subscription)
        let episodes = FollowingShowRows.episodes(of: subscription, in: model.followingShowEntries, lookedAt: lookedAtOnOpen)
        let newCount = subscription.state == .muted ? 0 : episodes.filter(\.isNew).count
        return List {
            header(for: subscription, title: title)
                .experienceListBlock(horizontalSizeClass: horizontalSizeClass)
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

    private func header(for subscription: FeedSubscription, title: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ShowArtworkView(url: artwork.artworkURL(for: subscription.id), title: title, size: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(AppColors.text)
                    Text("Following since \(subscription.createdAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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
            Picker("New episodes", selection: Binding(
                get: { subscription.newItemPolicy ?? .letMePick },
                set: { model.setFeedNewItemPolicy(id: subscription.id, policy: $0) }
            )) {
                Text("Let me pick").tag(FeedNewItemPolicy.letMePick)
                Text("Add every new item").tag(FeedNewItemPolicy.addEveryNewItem)
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("show.newItemPolicy")
            Button(role: .destructive) {
                model.unfollowShowWithUndo(subscription)
            } label: {
                Label(FollowingRowActions.unfollowTitle(showTitle: subscription.source.title ?? subscription.source.host), systemImage: "minus.circle")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .accessibilityHint("Stops following this show. Items already in your Library are kept. You can undo right after.")
            .accessibilityIdentifier("show.unfollow")
        }
    }

    /// A waiting episode keeps the row actions Following's stream had: add, play now, dismiss. A played one is
    /// already in the Library.
    @ViewBuilder
    private func episodeRow(_ episode: FollowingShowEpisode) -> some View {
        if episode.isInLibrary {
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
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(AppColors.panel)
            .accessibilityElement(children: .combine)
        } else {
            SourceInboxRow(candidate: .followedSource(episode.entry), artwork: artwork)
        }
    }
}
