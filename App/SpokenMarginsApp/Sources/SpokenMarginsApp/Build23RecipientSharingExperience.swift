import SwiftUI
import SessionKit

enum Build23RecipientPrimaryAction: Equatable {
    case addSource
    case importPackage(enabled: Bool)
}

enum Build23RecipientPresentation {
    static let integrityTitle = "Integrity checked"
    static let integrityDetail = "This package passed its integrity check, but the sender label is not cryptographically verified."
    static let importNotice = "Importing never starts playback. Imported Margins remain a separate layer that you control."

    static func canConfirmImport(_ snapshot: Build23RecipientImportSnapshot) -> Bool {
        !snapshot.requiresRecipientSource && snapshot.canImport && !snapshot.isImporting
    }

    static func primaryAction(for snapshot: Build23RecipientImportSnapshot) -> Build23RecipientPrimaryAction {
        if snapshot.requiresRecipientSource {
            return .addSource
        }

        return .importPackage(enabled: canConfirmImport(snapshot))
    }

    static func transportLabel(_ transport: Build23RecipientTransport) -> String {
        switch transport {
        case .reference:
            return "Source reference"
        case .embeddedText:
            return "Embedded text"
        case .recipientSupplied:
            return "Recipient-supplied source"
        }
    }

    static func itemContentsLabel(includesEmbeddedItem: Bool) -> String {
        includesEmbeddedItem ? "Item included in package" : "Item not included in package"
    }
}

@MainActor
struct Build23RecipientSharingExperience: View {
    @ObservedObject var coordinator: Build23SharingCoordinator
    let onRequestMissingSource: (Build23RecipientSourceRequest) -> Void

    init(
        coordinator: Build23SharingCoordinator,
        onRequestMissingSource: @escaping (Build23RecipientSourceRequest) -> Void = { _ in }
    ) {
        self.coordinator = coordinator
        self.onRequestMissingSource = onRequestMissingSource
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Shared Margins")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(AppColors.text)

                if let snapshot = coordinator.recipientSnapshot {
                    preview(snapshot)
                } else {
                    unavailablePreview
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(AppColors.bone)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let snapshot = coordinator.recipientSnapshot {
                VStack(spacing: 12) {
                    Divider()
                    importActions(snapshot)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
            }
        }
    }

    @ViewBuilder
    private func preview(_ snapshot: Build23RecipientImportSnapshot) -> some View {
        ExperienceSurface(tint: AppColors.softGreen) {
            VStack(alignment: .leading, spacing: 16) {
                Label(Build23RecipientPresentation.integrityTitle, systemImage: "checkmark.shield")
                    .font(.headline)
                    .foregroundStyle(AppColors.evergreen)
                    .accessibilityLabel("Package integrity checked")

                VStack(alignment: .leading, spacing: 6) {
                    Text(snapshot.itemTitle)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(AppColors.text)

                    Label("Shared by \(snapshot.senderLabel)", systemImage: "person.crop.circle")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AppColors.text)
                        .accessibilityLabel("Sender label \(snapshot.senderLabel). Sender identity is not cryptographically verified.")
                }

                packageFacts(snapshot)

                Text(Build23RecipientPresentation.integrityDetail)
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
                Text(SharingRightsPresentation.rightsNotice)
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
                Text("Deleting this import removes your local copy only. Other recipients may retain their copies.")
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
            }
        }

        if snapshot.requiresRecipientSource {
            missingSourceNotice(snapshot)
        }

        ExperienceSurface {
            Label(Build23RecipientPresentation.importNotice, systemImage: "play.slash")
                .font(.subheadline)
                .foregroundStyle(AppColors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(Text(Build23RecipientPresentation.importNotice))
        }

        if let errorMessage = snapshot.errorMessage {
            FailureMessageLabel(errorMessage)
                .font(.subheadline)
                .accessibilityLabel("Import error. \(errorMessage)")
        }
    }

    private func packageFacts(_ snapshot: Build23RecipientImportSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            packageFact(
                title: "Margins",
                value: "\(snapshot.marginCount)",
                systemImage: "quote.bubble"
            )
            packageFact(
                title: "Source transport",
                value: Build23RecipientPresentation.transportLabel(snapshot.transport),
                systemImage: "arrow.left.arrow.right"
            )
            packageFact(
                title: "Item contents",
                value: Build23RecipientPresentation.itemContentsLabel(
                    includesEmbeddedItem: snapshot.includesEmbeddedItem
                ),
                systemImage: snapshot.includesEmbeddedItem ? "doc.text.fill" : "doc.text"
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Verified package contents")
    }

    private func packageFact(title: String, value: String, systemImage: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .frame(width: 22)
                .foregroundStyle(AppColors.evergreen)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.secondaryText)
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(AppColors.text)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func missingSourceNotice(_ snapshot: Build23RecipientImportSnapshot) -> some View {
        ExperienceSurface(tint: AppColors.ochre.opacity(0.16)) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Add the source to continue", systemImage: "doc.badge.plus")
                    .font(.headline)
                    .foregroundStyle(AppColors.text)

                if snapshot.isPrivatePodcastSource {
                    Build23PrivateFeedRecoveryPanel(
                        recovery: coordinator.episodeRecovery,
                        episodeTitle: snapshot.itemTitle,
                        recover: { coordinator.recoverSharedEpisode(feedLink: $0) },
                        choose: { coordinator.chooseRecoveredEpisode($0) }
                    )
                } else {
                    Text("This verified package stays ready while you add the matching source. Import remains unavailable until the source is resolved.")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if snapshot.isPrivatePodcastSource {
                    Button(action: requestMissingSource) {
                        Label("Add the Episode Another Way", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Opens Add Source and keeps this package ready to resume")
                } else {
                    Button(action: requestMissingSource) {
                        Label("Add Source", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .filledActionButton()
                    .accessibilityHint("Opens Add Source and keeps this package ready to resume")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("A matching source is required for \(snapshot.itemTitle)")
    }

    private func requestMissingSource() {
        coordinator.send(.requestMissingSource)
        if let request = coordinator.pendingRecipientSourceRequest {
            onRequestMissingSource(request)
        }
    }

    @ViewBuilder
    private func importActions(_ snapshot: Build23RecipientImportSnapshot) -> some View {
        VStack(spacing: 12) {
            switch Build23RecipientPresentation.primaryAction(for: snapshot) {
            case .addSource:
                Button("Import") {}
                    .filledActionButton()
                    .frame(maxWidth: .infinity)
                    .disabled(true)
                    .accessibilityHint("Add the matching source before importing")

            case let .importPackage(enabled):
                Button {
                    coordinator.send(.confirmImport)
                } label: {
                    HStack(spacing: 8) {
                        if snapshot.isImporting {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(snapshot.isImporting ? "Importing…" : "Import")
                    }
                    .frame(maxWidth: .infinity)
                }
                .filledActionButton()
                .disabled(!enabled)
                .accessibilityHint("Imports the Margins as a separate layer without starting playback")
            }

            Button("Cancel", role: .cancel) {
                coordinator.send(.cancelImport)
            }
            .frame(maxWidth: .infinity)
            .disabled(snapshot.isImporting)
        }
    }

    private var unavailablePreview: some View {
        ExperienceSurface {
            VStack(alignment: .leading, spacing: 8) {
                Label("No package ready for review", systemImage: "tray")
                    .font(.headline)
                    .foregroundStyle(AppColors.text)
                Text("Open a verified shared package to preview it before importing.")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
            }
        }
    }
}
