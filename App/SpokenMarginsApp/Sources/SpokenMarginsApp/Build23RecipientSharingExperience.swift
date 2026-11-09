import SwiftUI
import SessionKit

enum Build23RecipientPrimaryAction: Equatable {
    case addSource
    case importPackage(enabled: Bool)
}

enum Build23RecipientPresentation {
    /// A file that passes its checks says nothing; the honest note sits under "About this file" (#3247).
    static let aboutTitle = FriendArrivalWords.aboutTitle
    static let aboutNote = FriendArrivalWords.aboutNote

    static func canConfirmImport(_ snapshot: Build23RecipientImportSnapshot) -> Bool {
        !snapshot.requiresRecipientSource && snapshot.canImport && !snapshot.isImporting
    }

    static func primaryAction(for snapshot: Build23RecipientImportSnapshot) -> Build23RecipientPrimaryAction {
        if snapshot.requiresRecipientSource {
            return .addSource
        }

        return .importPackage(enabled: canConfirmImport(snapshot))
    }

    static func heading(for snapshot: Build23RecipientImportSnapshot) -> String {
        snapshot.isListeningMap ? "Shared Listening Map" : FriendArrivalWords.fromLine(senderLabel: snapshot.senderLabel)
    }

    /// The confirm button. A map asks before it replaces another: the button says so.
    static func confirmTitle(for snapshot: Build23RecipientImportSnapshot) -> String {
        guard snapshot.isListeningMap else { return "Import" }
        return snapshot.replacesExistingMap ? "Replace Map" : "Add Map"
    }

    static func progressTitle(for snapshot: Build23RecipientImportSnapshot) -> String {
        snapshot.isListeningMap ? "Adding…" : "Importing…"
    }

    /// What choosing the button does. Nil for a friend's Margins, where "never starts playback" and its relatives are
    /// gone (#3247); a map still says it, because it changes the item's chapters.
    static func notice(for snapshot: Build23RecipientImportSnapshot) -> String? {
        guard snapshot.isListeningMap else { return nil }
        let base = "Adding a map never starts playback. It sets the chapters and keeps each chapter's summary. Your own Margins stay as they are."
        return snapshot.replacesExistingMap ? "This already has a shared map. Adding this one replaces it. " + base : base
    }

    static func confirmHint(for snapshot: Build23RecipientImportSnapshot) -> String {
        snapshot.isListeningMap
            ? "Sets the chapters from this map without starting playback"
            : "Opens the Margins on the episode without starting playback"
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
                Text(coordinator.recipientSnapshot.map { Build23RecipientPresentation.heading(for: $0) } ?? "From a friend")
                    .font(.title2.weight(.bold))
                    .screenTitle()
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
                VStack(alignment: .leading, spacing: 6) {
                    Text(snapshot.itemTitle)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(AppColors.text)

                    Label(FriendArrivalWords.fromLine(senderLabel: snapshot.senderLabel), systemImage: "person.crop.circle")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AppColors.text)
                        .accessibilityIdentifier("build23.recipient.sender")
                }

                packageFacts(snapshot)

                DisclosureGroup(Build23RecipientPresentation.aboutTitle) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Build23RecipientPresentation.aboutNote)
                        Text(SharingRightsPresentation.rightsNotice)
                    }
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                }
                .font(.subheadline)
                .tint(AppColors.text)
                .accessibilityIdentifier("build23.recipient.aboutFile")
                Text("Deleting this import removes your local copy only. Other recipients may retain their copies.")
                    .font(.footnote)
                    .foregroundStyle(AppColors.secondaryText)
            }
        }

        if snapshot.requiresRecipientSource {
            missingSourceNotice(snapshot)
        }

        if let notice = Build23RecipientPresentation.notice(for: snapshot) {
            ExperienceSurface {
                Label(notice, systemImage: "play.slash")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text(notice))
            }
        }

        if let errorMessage = snapshot.errorMessage {
            FailureMessageLabel(errorMessage)
                .font(.subheadline)
                .accessibilityLabel("Import error. \(errorMessage)")
        }
    }

    private func packageFacts(_ snapshot: Build23RecipientImportSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let chapters = snapshot.mapChapterCount {
                packageFact(title: "Chapters", value: "\(chapters)", systemImage: "list.bullet")
            } else {
                packageFact(
                    title: "Margins",
                    value: "\(snapshot.marginCount)",
                    systemImage: "quote.bubble"
                )
            }
        }
        .accessibilityElement(children: .contain)
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
                    Text(snapshot.isListeningMap
                        ? "This map stays ready while you add your copy. It can’t be added until the source is in your Library."
                        : "These Margins stay ready while you add the same source. You can add them once it is in your Library.")
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
                    .accessibilityHint("Opens Add to Library and keeps these Margins ready to resume")
                } else {
                    Button(action: requestMissingSource) {
                        Label("Add to Library", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .filledActionButton()
                    .accessibilityIdentifier("build23.recipient.addToLibrary")
                    .accessibilityHint("Opens Add to Library and keeps these Margins ready to resume")
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
                Button(Build23RecipientPresentation.confirmTitle(for: snapshot)) {}
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
                        Text(snapshot.isImporting
                            ? Build23RecipientPresentation.progressTitle(for: snapshot)
                            : Build23RecipientPresentation.confirmTitle(for: snapshot))
                    }
                    .frame(maxWidth: .infinity)
                }
                .filledActionButton()
                .disabled(!enabled)
                .accessibilityHint(Build23RecipientPresentation.confirmHint(for: snapshot))
                .accessibilityIdentifier("build23.recipient.import")
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
                Label("No Margins ready to look at", systemImage: "tray")
                    .font(.headline)
                    .foregroundStyle(AppColors.text)
                Text("Open a file of Margins to look at them before adding them.")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
            }
        }
    }
}
