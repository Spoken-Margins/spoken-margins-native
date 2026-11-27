import SessionKit
import SessionKitSharing
import SwiftUI

/// "From Cole", above the item's title while a friend's Margins wait (#3219). The words come from `FriendMarginsIntro`.
/// Under "From Ana" when the Margins came by link (#5275, Screen C): the friend reads that Ana can see they opened them,
/// with Don't tell Ana. After Don't tell it says what that changed, with no button. Nothing here blocks Play.
struct FriendLinkOpenedNotice: View {
    let text: String
    /// Nil once Don't tell was tapped.
    let dontTellTitle: String?
    let onDontTell: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(text)
                .font(.footnote)
                .foregroundStyle(AppColors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let dontTellTitle {
                Button(action: onDontTell) {
                    Text(dontTellTitle)
                        .font(.footnote)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("item.friendIntro.dontTell")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("item.friendIntro.openedNotice")
    }
}

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
    /// "Tell Sam you got it", when the newest friend's packet on this item answers one of the listener's own Margins
    /// (#3902). Nil for a first share.
    var receipt: ReplyReceiptButton.Content? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(intro.countLine, systemImage: "quote.bubble")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppColors.text)
                .accessibilityIdentifier("item.friendIntro.count")
            if let line = intro.missingParentLine {
                Text(line)
                    .font(.footnote)
                    .foregroundStyle(AppColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("item.friendIntro.missingParent")
            }
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
            if let receipt {
                ReplyReceiptButton(content: receipt, identifier: "itemDetail.friendIntro.tellReceived")
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

/// The one tap that tells a friend their reply arrived (#3902, Design E2). Nothing can see a reply arrive, so the
/// listener sends the text themselves, through the chat the reply came in. The offer and its words come from
/// `ReplyReceipt`. iOS doesn't say whether the message was sent, so the button stays and can be used again; a cancelled
/// sheet changes nothing.
struct ReplyReceiptButton: View {
    /// What one button offers: the friend's packet and the title its message names.
    struct Content: Equatable {
        let offer: ReplyReceipt.Offer
        let itemTitle: String

        var title: String { offer.buttonTitle }
        var message: String { offer.message(itemTitle: itemTitle) }
    }

    let content: Content
    let identifier: String

    var body: some View {
        ShareLink(item: content.message) {
            Label(content.title, systemImage: "paperplane")
                .font(.body.weight(.semibold))
                .multilineTextAlignment(.leading)
                // Wraps at the largest text sizes instead of being cut short.
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(AppColors.evergreen)
        .accessibilityLabel(Text(content.title))
        .accessibilityHint(Text("Opens the share sheet with a message."))
        .accessibilityIdentifier(identifier)
    }
}
