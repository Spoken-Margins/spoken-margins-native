import SessionKit
import SwiftUI

/// A friend who sent Margins, on Following (#3291): their initial, "Cole", "3 Margins on 1 episode" and ›, in the
/// shows' row style. The rows come from `FollowingFriends`.
struct FollowingFriendRowView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let friend: FollowingFriends.Friend
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: 12) {
                ShowArtworkView(url: nil, title: friend.name, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(friend.name)
                        .font(.headline)
                        .foregroundStyle(AppColors.text)
                        .multilineTextAlignment(.leading)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    Text(friend.summary)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.secondaryText)
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AppColors.panel)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(friend.name), \(friend.summary)")
        .accessibilityHint(friend.items.count == 1 ? "Opens the item." : "Shows their items.")
        .accessibilityIdentifier("sources.friend")
    }
}

/// A friend's items, when they sent Margins on more than one: each opens its own screen.
struct FollowingFriendItemsScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let friend: FollowingFriends.Friend

    var body: some View {
        List {
            ForEach(friend.items) { item in
                Button { model.openItem(id: item.id) } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                                .font(.headline)
                                .foregroundStyle(AppColors.text)
                                .multilineTextAlignment(.leading)
                            Text(item.countLabel)
                                .font(.subheadline)
                                .foregroundStyle(AppColors.secondaryText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppColors.secondaryText)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 44)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(AppColors.panel)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("sources.friend.item")
                .listRowInsets(EdgeInsets(top: 0, leading: horizontalSizeClass == .regular ? 28 : 16, bottom: 0, trailing: horizontalSizeClass == .regular ? 28 : 16))
                .listRowSeparator(.hidden)
                .listRowBackground(AppColors.bone)
            }
        }
        .background(AppColors.bone)
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        .navigationTitle(friend.name)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("sources.friend.screen")
    }
}
