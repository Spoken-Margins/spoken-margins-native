import SessionKit
import SwiftUI

/// What a show's Up next card draws (#3863): the episode `FollowingUpNext.pick` chose, its description, and the
/// "12 min · Nov 9" line. Built off the main thread with the show's episode list, so `body` only reads it.
struct ShowUpNext: Equatable, Sendable {
    var card: FollowingUpNext.Card
    /// Length and date from the same `FollowingEntryRow` the Following rows use; nil when the feed gave neither.
    var trailingMetadata: String?

    init(card: FollowingUpNext.Card, rate: Double) {
        self.card = card
        trailingMetadata = FollowingEntryRow(entry: card.entry, showTitle: nil, artworkURL: nil, rate: rate).trailingMetadata
    }
}

/// The first thing on a followed show's screen under its header (#3863): the episode worth hearing next, with its whole
/// title, the publisher's description and the buttons to decide. It is one list row, so a tap on one control can never
/// reach another. The episode is the one the Following row's ▶ plays, because both ask `FollowingUpNext.pick`.
struct ShowUpNextCard: View {
    @EnvironmentObject private var model: Gate1AppModel
    @ObservedObject private var playQueue = PlayQueueState.shared
    let upNext: ShowUpNext

    private var entry: FeedEntry { upNext.card.entry }
    private var isImporting: Bool { model.importingFollowedSourceEntryIds.contains(entry.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Up next")
                .font(.headline)
                .foregroundStyle(AppColors.text)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("show.upNext.header")
            VStack(alignment: .leading, spacing: 8) {
                // The whole title wraps; ordinary rows keep their two-line cap (#884).
                Text(entry.title.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppColors.text)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("show.upNext.title")
                if let meta = upNext.trailingMetadata {
                    Text(meta)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                        .accessibilityIdentifier("show.upNext.meta")
                }
                // No description, no block and no placeholder.
                if let description = upNext.card.description {
                    ItemDescriptionPreview(text: description, identifierPrefix: "show.upNext.description")
                        .id(entry.id)
                }
                buttons
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(AppColors.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("show.upNext")
    }

    /// Side by side when they fit; stacked and full width when they don't (large text sizes), where three controls and a
    /// menu have no room on one line.
    private var buttons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                choices
                Spacer(minLength: 0)
                moreMenu
            }
            VStack(alignment: .leading, spacing: 8) {
                choices
                moreMenu
            }
        }
    }

    @ViewBuilder
    private var choices: some View {
        if upNext.card.isInLibrary {
            Label("In your Library", systemImage: "checkmark.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppColors.evergreen)
                .frame(minHeight: 44)
                .accessibilityIdentifier("show.upNext.inLibrary")
        } else {
            Button { model.importFollowedSourceEntry(entry) } label: {
                Text(isImporting ? "Adding…" : "Add to Library").frame(minHeight: 44)
            }
            .filledActionButton()
            .disabled(isImporting)
            .accessibilityIdentifier("show.upNext.add")
        }
        Button(action: play) {
            Label("Play", systemImage: "play.fill").frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(AppColors.evergreen)
        .disabled(isImporting)
        .accessibilityIdentifier("show.upNext.play")
    }

    /// In the Library: resume it there. Otherwise the episode enters the Library as it starts and not before, as the
    /// Following row's ▶ does.
    private func play() {
        if let itemID = upNext.card.libraryItemID {
            model.startItem(id: itemID)
        } else {
            model.importFollowedSourceEntry(entry, playWhenFinished: true)
        }
    }

    /// The row actions the buttons don't cover, with the same names and model calls as the episode rows' menus.
    private var moreMenu: some View {
        Menu {
            if let itemID = upNext.card.libraryItemID, upNext.card.isInLibrary {
                let action = QueueRowAction.action(forItem: itemID, queuedItemIds: playQueue.itemIds)
                Button { model.toggleQueue(itemId: itemID) } label: {
                    Label(action.title, systemImage: action.systemImage)
                }
            } else {
                Button { model.addEntryToQueue(entry) } label: {
                    Label(QueueRowAction.add.title, systemImage: QueueRowAction.add.systemImage)
                }
                Button { model.dismissFollowedSourceEntry(id: entry.id) } label: {
                    Label("Dismiss", systemImage: "xmark")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(AppColors.evergreen)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .disabled(isImporting)
        .accessibilityLabel("More actions")
        .accessibilityHint(entry.title)
        .accessibilityIdentifier("show.upNext.more")
    }
}
