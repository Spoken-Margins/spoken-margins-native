import AVFoundation
import SessionKit
import SessionKitAudio
import SessionKitFeeds
import SessionKitSharing
import SwiftUI
import UIKit

enum ShareMarginDraftFilter: String, CaseIterable, Identifiable {
    case all
    case starred

    var id: String { rawValue }
}

enum ShareAutoCleanPreference {
    static let decisionRecordedKey = "sharingAutoCleanDecisionRecordedV1"
    static let enabledKey = "sharingAutoCleanSelectedEnabledV1"

    static var hasRecordedDecision: Bool {
        UserDefaults.standard.bool(forKey: decisionRecordedKey)
    }

    static var isEnabled: Bool {
        hasRecordedDecision && UserDefaults.standard.bool(forKey: enabledKey)
    }

    static func record(enabled: Bool) {
        UserDefaults.standard.set(true, forKey: decisionRecordedKey)
        UserDefaults.standard.set(enabled, forKey: enabledKey)
    }
}

struct InterjectionSharingState {
    var drafts: [ShareInterjectionDraft] = []
    var senderDisplayLabel = UserDefaults.standard.string(forKey: "sharingSenderDisplayLabel") ?? ""
    var includesAcousticEvidence = true
    /// Model-written scene summaries the packet leaves out because the source is not marked public (#3449). Zero shows no note.
    var withheldMapSceneCount = 0
    var itemReferenceURL: String?
    var canEmbedLinklessItem = false
    var isAppAuthoredItem = false
    var confirmsPrivateSharingRights = false
    var isPreparing = false
    var isBulkPreparing = false
    var bulkPreparationCompleted = 0
    var bulkPreparationTotal = 0
    var bulkPreparationFailureCount = 0
    var isExporting = false
    var errorMessage: String?
    var draftFilter: ShareMarginDraftFilter = .all
    /// "Share replies with Ana" when the sheet was opened to share replies back (#3221, #3906); nil for an ordinary share.
    var replyBackTitle: String?
    var autoCleanSelectedEnabled = ShareAutoCleanPreference.isEnabled
    var needsAutoCleanDecision = !ShareAutoCleanPreference.hasRecordedDecision
    var automaticallyCleanedDraftIDs: Set<String> = []
    /// Set by the export screen, which prepares drafts from the session picked there. The
    /// sheet's `begin` keeps them once instead of rebuilding from the open item's session.
    var draftsPreparedForExport = false
    /// Where the sheet starts (#1507). The playback screen's Share sets `.reviewDefaults`, so the sheet opens on
    /// the review with Share pinned; `begin` reads it once and resets it.
    var entry: ShareSheetEntry = .chooseMargins
    /// How the sheet got its starting selection, and when it opened, for the `share.selection` Diagnostics line (#4173).
    var openedFrom: ShareOpenedFrom = .all
    var openedAt = Date()
    /// The star counts the last send tap on this sheet logged. The counts start again once the system sheet shows, so a
    /// retry after cancelling it logs these instead of zeros (#4173).
    var starTallyAtLastSend: ShareStarTally?
}

struct SpokenMarginsPackageImportReview: Identifiable {
    let id = UUID()
    let packageURL: URL
    let extractionDirectory: URL
    let contents: VerifiedSpokenMarginsPackage
    let matchingItemId: String?
    /// A map packet whose item already carries a different shared map: adding this one replaces it.
    var replacesExistingMap = false
    /// Removes the file the packet was opened from (the Share inbox copy), once it is imported or cancelled (#2123).
    var releaseSource: (@MainActor () -> Void)?
    /// Imported as soon as it shows, with no sheet (#3291): set when the file arrives and nothing waits on the listener.
    var opensDirectly = false
    /// The id of the share link this packet was opened from, kept with the imported layer so the listener can
    /// report that link later (#2846). Nil for a file handed over directly.
    var shareLinkId: String?

    /// A file that carries a Listening Map for an article or PDF and no Margins (#1471).
    var isListeningMap: Bool { ListeningMapPacket.isMapPacket(contents.manifest) }

    var mapChapterCount: Int? { ListeningMapPacket.proposal(in: contents)?.scenes.count }

    var marginCount: Int {
        contents.commentaryLayers.reduce(0) { $0 + $1.interjections.count }
    }

    var senderLabel: String {
        SharedPacketArrival.snapshotSenderLabel(contents.manifest.senderDisplayLabel)
    }

    var includesEmbeddedItem: Bool {
        contents.manifest.itemTransport.kind == .embeddedText
    }

    var requiresRecipientItem: Bool {
        // A PDF or EPUB can't be fetched from a link, so the listener picks their copy even when the sender had a link.
        let needsPickedFile = isListeningMap && contents.manifest.item.itemType != .text
        return (contents.manifest.itemTransport.kind == .recipientSupplied || needsPickedFile) && matchingItemId == nil
    }
}

struct SharedSpokenMarginsPackageActivityView: UIViewControllerRepresentable {
    let packageURL: URL
    /// The item's title. When it is set, Messages and Mail get a line beside the file saying what it is and where to
    /// get the app (#3800); every other target gets the file alone.
    var itemTitle: String?
    /// Runs when the share sheet reports the packet was sent (logged as an I4 `share`, #483).
    var onShared: () -> Void = {}

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: Self.activityItems(packageURL: packageURL, itemTitle: itemTitle),
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, completed, _, _ in
            if completed { onShared() }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}

    /// What the sheet carries: the packet, then, when there is a title, the line that only Messages and Mail take.
    /// A test reads this; `UIActivityViewController` doesn't give its items back.
    static func activityItems(packageURL: URL, itemTitle: String?) -> [Any] {
        guard let itemTitle else { return [SpokenMarginsPackageActivityItem(packageURL: packageURL)] }
        return [
            SpokenMarginsPackageActivityItem(packageURL: packageURL, mailSubject: ShareFileMessage.mailSubject(itemTitle: itemTitle)),
            SpokenMarginsFileMessageActivityItem(itemTitle: itemTitle),
        ]
    }
}

/// The line beside a file sent as a file (#3800): returned for Messages and Mail, and nothing for any other target, so
/// an app that keeps one of two items can never keep the line and drop the file.
final class SpokenMarginsFileMessageActivityItem: NSObject, UIActivityItemSource {
    let itemTitle: String

    init(itemTitle: String) {
        self.itemTitle = itemTitle
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        ShareFileMessage.text(itemTitle: itemTitle)
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        ShareFileMessage.carriesMessage(activityType: activityType?.rawValue) ? ShareFileMessage.text(itemTitle: itemTitle) : nil
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        subjectForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        ShareFileMessage.mailSubject(itemTitle: itemTitle)
    }
}

final class SpokenMarginsPackageActivityItem: NSObject, UIActivityItemSource {
    let packageURL: URL
    /// The subject Mail gets. A file sent beside the line in #3800 names the item; the rest keep the old one.
    let mailSubject: String

    init(packageURL: URL, mailSubject: String = "Spoken Margins shared session") {
        self.packageURL = packageURL
        self.mailSubject = mailSubject
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        packageURL
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        packageURL
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        SpokenMarginsPackageHandoffStore.uniformTypeIdentifier
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        subjectForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        mailSubject
    }
}

struct SharedSpokenMarginsPackageReadyView: View {
    @EnvironmentObject private var model: Gate1AppModel
    let packageURL: URL
    @State private var isActivityPresented = false
    /// The packet file's size, read off the main thread, so the sender sees it before sending (#3218).
    @State private var packetSizeText: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                ProductPanel {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Your Margins are ready")
                            .font(.headline)
                        Text(packageURL.lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                        if let packetSizeText {
                            Text("Size: \(packetSizeText)")
                                .font(.caption)
                                .foregroundStyle(AppColors.secondaryText)
                                .accessibilityIdentifier("sharing.packetSize")
                        }
                    }
                }
                Button("Share File") { isActivityPresented = true }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Done") { model.isSharedSpokenMarginsPackagePresented = false }
                    .buttonStyle(SecondaryButtonStyle())
                Spacer()
            }
            .padding(20)
            .navigationTitle("Share Margins")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task(id: packageURL) {
            let url = packageURL
            let bytes = await Task.detached(priority: .utility) {
                (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            }.value
            packetSizeText = bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        }
        .trackedSheet(isPresented: $isActivityPresented) {
            SharedSpokenMarginsPackageActivityView(packageURL: packageURL) {
                model.listeningSignals.share(packetURL: packageURL)
            }
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
