import SessionKit
import SwiftUI

/// The card at the top of the first-launch "Follow a few favourites" sheet for a friend who installed from a link
/// (#3782). The words and the paste judgment are `FirstLaunchFriendLinkCard`'s; the drawer decides when it shows.
///
/// The system Paste button is the only way the card reads the clipboard: iOS shows no "Allow Paste" prompt for it and
/// nothing is read before the tap. A link opens as a tapped one does; anything else leaves the sheet as it was, with
/// one line under the button. Follows `ClipboardLinkOfferCard`'s surface and Paste button.
struct FirstLaunchFriendLinkCardView: View {
    @ObservedObject var drawer: CatalogDrawerModel

    var body: some View {
        ExperienceSurface(tint: AppColors.evergreen.opacity(0.5), padding: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Text(FirstLaunchFriendLinkCard.headline)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("catalog.friendLink.headline")
                Text(FirstLaunchFriendLinkCard.line)
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("catalog.friendLink.line")
                pasteButton
                if let note = drawer.friendLinkNote {
                    Label(note, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(AppColors.warningText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("catalog.friendLink.note")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("catalog.friendLink.card")
    }

    private var pasteButton: some View {
        PasteButton(supportedContentTypes: PastedClipboardContent.supportedTypes) { providers in
            // The closure runs on the tap: the clipboard is read here and nowhere else.
            Task { @MainActor in
                let content = await PastedClipboardContent.text(from: providers)
                drawer.pasteIntoFriendLinkCard(content)
                if drawer.friendLinkNote != nil {
                    AccessibilityNotification.Announcement(FirstLaunchFriendLinkCard.notAFriendLinkLine).post()
                }
            }
        }
        .labelStyle(.titleAndIcon)
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
        .tint(AppColors.evergreen)
        .accessibilityLabel("Paste the link")
        .accessibilityIdentifier("catalog.friendLink.paste")
    }
}
