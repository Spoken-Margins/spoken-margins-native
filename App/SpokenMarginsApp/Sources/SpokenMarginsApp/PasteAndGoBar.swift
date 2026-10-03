import SwiftUI
import SessionKit

/// The Add sheet's bottom bar (#145): one Paste & go tap adds a copied link or copied text.
/// `PasteButton` reads the clipboard without the iOS "Allow Paste" prompt because the tap is the
/// permission; the system draws its "Paste" label, so the bar names the action beside it.
struct PasteAndGoBar: View {
    @EnvironmentObject private var model: Gate1AppModel
    let onAdded: () -> Void
    @State private var notAddedMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let notAddedMessage {
                Label(notAddedMessage, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.dangerText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("addSource.pasteAndGo.message")
            } else if model.sourceLinkImportState == "resolving" || model.sourceLinkImportState == "failure" {
                SourceLinkImportStatusView()
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Paste & go")
                        .font(.headline)
                        .foregroundStyle(AppColors.text)
                    Text("Adds a copied link or copied text")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityHidden(true)
                Spacer(minLength: 8)
                if model.isResolvingSourceLink {
                    ProgressView()
                        .frame(minWidth: 44, minHeight: 44)
                } else {
                    PasteButton(payloadType: String.self) { strings in
                        let pasted = strings.first
                        Task { @MainActor in paste(pasted) }
                    }
                    .labelStyle(.titleAndIcon)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .tint(AppColors.evergreen)
                    .accessibilityLabel("Paste and add from clipboard")
                    .accessibilityIdentifier("addSource.pasteAndGo.button")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .background(AppColors.bone)
    }

    private func paste(_ content: String?) {
        switch model.pasteAndGo(content) {
        case .resolvingLink:
            // The sheet closes itself when the link import reports success.
            notAddedMessage = nil
        case .addedText:
            notAddedMessage = nil
            onAdded()
        case .notAdded(let message):
            notAddedMessage = message
        }
    }
}

/// The link import's progress or failure, with Open in Safari when the app couldn't read the page itself.
struct SourceLinkImportStatusView: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = model.sourceLinkImportMessage {
                Group {
                    if model.sourceLinkImportState == "failure" {
                        FailureMessageLabel(message)
                    } else {
                        Text(message)
                            .foregroundStyle(AppColors.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.subheadline)
                .accessibilityIdentifier("sourceLink.import.status")
            }
            if model.sourceLinkImportState == "failure", let offer = model.sourceLinkSafariOffer {
                Button {
                    openURL(offer.url)
                } label: {
                    Label("Open in Safari", systemImage: "safari")
                        .frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(AppColors.evergreen)
                .accessibilityIdentifier("sourceLink.openInSafari.button")
                Text(OpenInSafariOffer.shareBackHint)
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
            }
        }
    }
}
