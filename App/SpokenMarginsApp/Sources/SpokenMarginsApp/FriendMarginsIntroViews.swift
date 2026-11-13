import SessionKit
import SwiftUI

/// "From Cole", above the item's title while a friend's Margins wait (#3219). The words come from `FriendMarginsIntro`.
struct FriendMarginsSenderLine: View {
    let intro: FriendMarginsIntro

    var body: some View {
        Label(intro.senderLine, systemImage: "person.crop.circle.fill")
            .font(.headline)
            .foregroundStyle(AppColors.evergreen)
            .accessibilityIdentifier("item.friendIntro.sender")
    }
}

/// "3 Margins · about 2 min" and what a Margin is (not for replies), under the item's title while a friend's Margins wait (#3219).
struct FriendMarginsSummary: View {
    let intro: FriendMarginsIntro

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(intro.countLine, systemImage: "quote.bubble")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppColors.text)
                .accessibilityIdentifier("item.friendIntro.count")
            // Replies come back to the person who made the Margins, who needs no explanation of them (#3889).
            if let explanation = intro.explanation {
                Text(explanation)
                    .font(.body)
                    .foregroundStyle(AppColors.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppColors.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityIdentifier("item.friendIntro.explanation")
            }
            // What the old Import sheet said honestly, one tap away (#3291).
            DisclosureGroup(SharedPacketArrival.aboutTitle) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(SharedPacketArrival.aboutIntegrity)
                    Text(SharingRightsPresentation.rightsNotice)
                }
                .font(.footnote)
                .foregroundStyle(AppColors.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            }
            .font(.subheadline)
            .tint(AppColors.text)
            .accessibilityIdentifier("item.friendIntro.aboutFile")
        }
    }
}
