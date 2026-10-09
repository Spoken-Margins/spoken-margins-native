import SwiftUI
import SessionKit

struct ExperienceItemDetailScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @EnvironmentObject private var sharingCoordinator: Build23SharingCoordinator
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var confirmsTrash = false
    @State private var confirmsNewSession = false
    @State private var showsAdvanced = false
    /// Set while Continue waits on the "hear new Margins first?" question (#474).
    @State private var newMarginsOfferItemId: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    hero
                    secondaryActions
                    downloadRecovery
                    ItemLastFailureCard(itemId: model.selectedItem.id)
                    if !sharingCoordinator.importedLayers.isEmpty {
                        Build23ImportedMarginPresentation(coordinator: sharingCoordinator)
                    }
                    SourceFollowSuggestionCard()
                    ManualSourceFollowButton()
                    if !model.selectedItem.overview.isEmpty { overview }
                    sessions
                    structure
                    if let edition = model.selectedListeningEdition { ListeningEditionScenes(edition: edition) }
                    if !model.selectedItem.listeningMapScenes.isEmpty { listeningMap }
                    recentMargins
                    advanced
                }
                .padding(.horizontal, horizontalSizeClass == .regular ? 30 : 18)
                .padding(.vertical, 22)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            // The main listening button stays pinned at the bottom, within thumb reach, above the mini player (#149).
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) { primaryPlaybackAction }
                    .padding(.horizontal, horizontalSizeClass == .regular ? 30 : 18)
                    .padding(.vertical, 10)
                    .frame(maxWidth: 900)
                    .frame(maxWidth: .infinity)
                    .background(AppColors.bone)
            }
            .background(AppColors.bone)
            .accessibilityIdentifier("item.screen")
            .navigationTitle("Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: model.openHome) {
                        Label("Library", systemImage: "arrow.left")
                    }
                    .accessibilityIdentifier("item.home.button")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Export latest session", systemImage: "square.and.arrow.up") {
                            model.openExport(sessionId: model.selectedItem.sessions.first?.id)
                        }
                        .disabled(model.selectedItem.sessions.isEmpty)
                        if !model.selectedItem.id.isEmpty {
                            Button("Move to Recently Deleted", systemImage: "trash", role: .destructive) {
                                confirmsTrash = true
                            }
                            .accessibilityIdentifier("item.delete.button")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Item options")
                }
            }
            .alert("Move to Recently Deleted?", isPresented: $confirmsTrash) {
                Button("Cancel", role: .cancel) {}
                Button("Move to Recently Deleted", role: .destructive) {
                    model.moveItemToTrash(id: model.selectedItem.id)
                }
            } message: {
                Text("\(model.selectedItem.title) can be restored from Settings.")
            }
            .confirmationDialog("Start a separate listening session?", isPresented: $confirmsNewSession) {
                Button("Start New Session") { model.startNewSession(id: model.selectedItem.id) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your existing listening position and Margins remain in their current session.")
            }
            .newMarginsOffer(itemId: $newMarginsOfferItemId)
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.selectedItem.title)
                .font(.title.weight(.bold))
                .foregroundStyle(AppColors.text)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { metadataPills }
                VStack(alignment: .leading, spacing: 7) { metadataPills }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var metadataPills: some View {
        if chapterCount > 0 {
            metadataPill("\(chapterCount) chapter\(chapterCount == 1 ? "" : "s")", systemImage: "list.bullet")
        }
        if !model.selectedItem.listeningMapScenes.isEmpty {
            let count = model.selectedItem.listeningMapScenes.count
            metadataPill(
                "\(count) map scene\(count == 1 ? "" : "s")",
                systemImage: "map"
            )
        }
        if !model.selectedItem.interjections.isEmpty {
            let count = model.selectedItem.interjections.count
            metadataPill("\(count) Margin\(count == 1 ? "" : "s")", systemImage: "quote.bubble")
        }
        if let tableCount = model.selectedItem.documentStructure?.tables.count,
           tableCount > 0 {
            metadataPill(
                "\(tableCount) table\(tableCount == 1 ? "" : "s") skipped",
                systemImage: "tablecells"
            )
        }
    }

    private var chapterCount: Int {
        model.selectedItem.chapters.isEmpty
            ? model.selectedItem.mediaChapters.count
            : model.selectedItem.chapters.count
    }

    @ViewBuilder
    private var secondaryActions: some View {
        if model.selectedItemPreferredContinuationSession != nil || !itemMargins.isEmpty || !newSharedMargins.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { secondaryActionButtons }
                VStack(alignment: .leading, spacing: 8) { secondaryActionButtons }
            }
        }
    }

    @ViewBuilder
    private var primaryPlaybackAction: some View {
        if [.waiting, .preparing].contains(model.selectedItemStartupAudioState) {
            HStack(spacing: 10) {
                if model.selectedItemStartupAudioState == .preparing {
                    ProgressView()
                        .tint(AppColors.evergreen)
                }
                Text(model.selectedItemStartupAudioProgressDescription)
                    .fontWeight(.semibold)
            }
            .foregroundStyle(AppColors.secondaryText)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(model.selectedItemStartupAudioProgressDescription)
            .accessibilityIdentifier("item.start.preparing")
        }
        Button {
                model.continueListening(itemId: model.selectedItem.id) { newMarginsOfferItemId = $0 }
            } label: {
                Label([.waiting, .preparing].contains(model.selectedItemStartupAudioState) ? "Listen now" : primaryPlaybackLabel, systemImage: "play.fill")
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .filledActionButton()
            .accessibilityIdentifier("item.start.button")
    }

    @ViewBuilder
    private var secondaryActionButtons: some View {
        if !newSharedMargins.isEmpty {
            Button {
                model.reviewNewMargins(itemId: model.selectedItem.id, thenContinue: false)
            } label: {
                Label("Review new Margins (\(newSharedMargins.count))", systemImage: "person.2")
                    .frame(minHeight: 40)
            }
            .filledActionButton()
            .accessibilityIdentifier("item.reviewNewMargins.button")
        }

        if model.selectedItemPreferredContinuationSession != nil {
            Button {
                confirmsNewSession = true
            } label: {
                Label("New session", systemImage: "plus.circle")
                    .frame(minHeight: 40)
            }
            .buttonStyle(.bordered)
            .tint(AppColors.evergreen)
            .accessibilityIdentifier("item.startNew.button")
        }

        if !itemMargins.isEmpty {
            Button {
                model.marginCollectionQuery = MarginCollectionQuery(itemID: model.selectedItem.id)
                model.openMargins()
            } label: {
                Label("Review Margins", systemImage: "quote.bubble")
                    .frame(minHeight: 40)
            }
            .buttonStyle(.bordered)
            .tint(AppColors.evergreen)
            .accessibilityIdentifier("item.reviewMargins.button")
        }
    }

    private var primaryPlaybackLabel: String {
        if hasFinishedSession { return "Replay" }
        return model.selectedItemPreferredContinuationSession == nil ? "Start listening" : "Continue"
    }

    private var hasFinishedSession: Bool {
        guard let session = model.selectedItemPreferredContinuationSession else { return false }
        return session.status == "finished" || session.phase == .finished || session.completionPercent >= 100
    }

    private var overview: some View {
        ExperienceSurface {
            VStack(alignment: .leading, spacing: 10) {
                Text("Overview")
                    .font(.system(.title3, design: .serif).weight(.bold))
                Text(model.selectedItem.overview)
                    .font(.body)
                    .foregroundStyle(AppColors.secondaryText)
                    .lineSpacing(3)
            }
        }
    }

    private var structure: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("Chapters", detail: "Authored source structure")
            if !model.selectedItem.navigation.isEmpty {
                ExperienceSurface {
                    ExperienceCanonicalNavigationTree(
                        nodes: model.selectedItem.navigation,
                        chapters: model.selectedItem.chapters,
                        action: { model.jumpToChapter($0) }
                    )
                }
            } else if !model.selectedItem.chapters.isEmpty {
                ExperienceSurface {
                    VStack(spacing: 0) {
                        ForEach(Array(model.selectedItem.chapters.enumerated()), id: \.element.id) { index, chapter in
                            if index > 0 { Divider() }
                            Button { model.jumpToChapter(chapter) } label: {
                                HStack {
                                    Text("\(chapter.percent)%")
                                        .font(.caption.monospacedDigit().weight(.bold))
                                        .foregroundStyle(AppColors.evergreen)
                                        .frame(width: 42, alignment: .leading)
                                    Text(chapter.title)
                                        .font(.headline)
                                        .foregroundStyle(AppColors.text)
                                    Spacer()
                                    Image(systemName: "play.fill")
                                        .foregroundStyle(AppColors.evergreen)
                                }
                                .frame(minHeight: 52)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("chapter.jump.\(chapter.id)")
                        }
                    }
                }
            } else if !model.selectedItem.mediaChapters.isEmpty {
                ExperienceSurface {
                    VStack(spacing: 0) {
                        ForEach(Array(model.selectedItem.mediaChapters.sorted { $0.startMs < $1.startMs }.enumerated()), id: \.element.id) { index, chapter in
                            if index > 0 { Divider() }
                            Button { model.jumpToMediaChapter(chapter) } label: {
                                HStack(spacing: 12) {
                                    Text(formatPlaybackTime(chapter.startMs))
                                        .font(.caption.monospacedDigit().weight(.bold))
                                        .foregroundStyle(AppColors.evergreen)
                                        .frame(width: 52, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(chapter.title)
                                            .font(.headline)
                                            .foregroundStyle(AppColors.text)
                                            .multilineTextAlignment(.leading)
                                        if let description = chapter.description, !description.isEmpty {
                                            Text(description)
                                                .font(.caption)
                                                .foregroundStyle(AppColors.secondaryText)
                                                .lineLimit(2)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "play.fill")
                                        .foregroundStyle(AppColors.evergreen)
                                }
                                .frame(minHeight: 52)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("mediaChapter.jump.\(chapter.id)")
                        }
                    }
                }
            } else {
                ExperienceSurface {
                    Label("No authored chapters", systemImage: "doc.text")
                        .font(.headline)
                    Text("Listening is available from the beginning. A generated map is optional and lives under Advanced.")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                        .padding(.top, 4)
                }
            }
        }
    }

    private var listeningMap: some View {
        ExperienceListeningMapSection(scenes: model.selectedItem.listeningMapScenes, model: model)
            .equatable()
    }

    @ViewBuilder
    private var recentMargins: some View {
        if !model.selectedItem.interjections.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeading("Recent Margins", detail: "Your thoughts on this item")
                ExperienceSurface(tint: AppColors.coral.opacity(0.34)) {
                    VStack(spacing: 0) {
                        ForEach(Array(itemMargins.prefix(3).enumerated()), id: \.element.id) { index, row in
                            if index > 0 { Divider() }
                            Button { model.openMarginInTimeline(row) } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: "quote.bubble.fill")
                                        .foregroundStyle(AppColors.coral)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(row.preview)
                                            .font(.headline)
                                            .foregroundStyle(AppColors.text)
                                            .multilineTextAlignment(.leading)
                                            .lineLimit(2)
                                        Text("At \(row.interjection.roughPercent)%")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(AppColors.secondaryText)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(AppColors.secondaryText)
                                }
                                .padding(.vertical, 12)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                ReadwiseItemLink(sync: model.readwiseHighlightSync, itemId: model.selectedItem.id)
            }
        }
    }

    private var sessions: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("Listening sessions", detail: "Each pass keeps its own position and Margins")
            if model.selectedItem.sessionRows.isEmpty {
                ExperienceSurface { Text("No sessions yet.").foregroundStyle(AppColors.secondaryText) }
            } else {
                ExperienceSurface {
                    VStack(spacing: 0) {
                        ForEach(Array(model.selectedItem.sessionRows.enumerated()), id: \.element.id) { index, row in
                            if index > 0 { Divider() }
                            HStack(spacing: 12) {
                                Button { model.openSession(row.session) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(sessionTitle(row.session, index: index))
                                            .font(.headline)
                                            .foregroundStyle(AppColors.text)
                                        Text("\(row.session.completionPercent)% · \(row.interjectionCount) Margin\(row.interjectionCount == 1 ? "" : "s")")
                                            .font(.subheadline.monospacedDigit())
                                            .foregroundStyle(AppColors.secondaryText)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("session.inspect.\(row.session.id)")
                                Button { model.resumeSession(row.session) } label: {
                                    Image(systemName: "play.fill").frame(width: 44, height: 44)
                                }
                                .buttonStyle(.bordered)
                                Button { model.openExport(sessionId: row.session.id) } label: {
                                    Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Export this session")
                                .accessibilityIdentifier("session.export.\(row.session.id)")
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var downloadRecovery: some View {
        switch model.selectedPodcastDownloadState {
        case .waitingForWiFi, .streamingOnly, .failed, .evicted, .downloading:
            HStack(spacing: 12) {
                Label(readinessLabel, systemImage: readinessIcon)
                    .font(.subheadline)
                    .foregroundStyle(readinessColor)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                switch model.selectedPodcastDownloadState {
                case .waitingForWiFi, .streamingOnly:
                    Button("Download Now", action: model.downloadSelectedPodcastNow)
                        .buttonStyle(.bordered)
                        .tint(AppColors.evergreen)
                case .failed, .evicted:
                    Button("Retry Download", action: model.retrySelectedPodcastDownload)
                        .buttonStyle(.bordered)
                        .tint(AppColors.evergreen)
                case .downloading:
                    ProgressView()
                        .tint(readinessColor)
                case .availableOffline, .none:
                    EmptyView()
                }
            }
            .accessibilityIdentifier("item.podcastDownload.status")
        case .availableOffline:
            Button("Download Again", action: model.redownloadSelectedPodcast)
                .buttonStyle(.bordered)
        case .none:
            EmptyView()
        }
    }

    private var advanced: some View {
        DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                if !model.selectedItem.externalReference.isEmpty {
                    LabeledContent("Source reference") {
                        Text(model.selectedItem.externalReference)
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                            .textSelection(.enabled)
                    }
                    .accessibilityIdentifier("item.externalReference")
                }
                if let reason = model.sharedListeningMapRefusal(itemId: model.selectedItem.id) {
                    VStack(alignment: .leading, spacing: 4) {
                        FailureMessageLabel("A shared map couldn't be placed on your copy")
                            .font(.subheadline.weight(.semibold))
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("item.sharedMap.refusal")
                }
                if model.canGenerateListeningMap {
                    Button(model.episodeMapPreparationStatus == "Preparing" ? "Preparing Listening Map…" : "Prepare Listening Map", systemImage: "sparkles") {
                        model.generateListeningMap()
                    }
                    .disabled(model.isGeneratingListeningMap || model.episodeMapPreparationStatus == "Preparing")
                    .accessibilityIdentifier("item.generateMap.button")
                    if model.episodeMapPreparationStatus != "Not started" {
                        Text(model.episodeMapPreparationStatus)
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                            .accessibilityIdentifier("item.episodeMap.status")
                    }
                } else {
                    Text(model.listeningMapGenerationAvailabilityDescription)
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                }
            }
            .padding(.top, 12)
        }
        .font(.headline)
        .padding(16)
        .background(AppColors.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18).stroke(AppColors.border) }
    }

    /// Shared Margins on this item that the listener hasn't heard (#474).
    private var newSharedMargins: [SharedMarginReview.Entry] {
        model.newSharedMargins(itemId: model.selectedItem.id)
    }

    private var itemMargins: [MarginRow] {
        model.selectedItem.interjections
            .filter { $0.status == "active" }
            .sorted { $0.createdAt > $1.createdAt }
            .map { MarginRow(interjection: $0, itemTitle: model.selectedItem.title, sessionDate: nil) }
    }

    private var readinessLabel: String {
        switch model.selectedPodcastDownloadState {
        case .waitingForWiFi: "Waiting for Wi-Fi"
        case .streamingOnly: "Streaming available"
        case .failed, .evicted: "Download needs attention"
        case .downloading: "Downloading"
        case .availableOffline: "Available offline"
        case .none: ""
        }
    }

    private var readinessIcon: String {
        switch model.selectedPodcastDownloadState {
        case .availableOffline: "arrow.down.circle.fill"
        case .failed, .evicted: "exclamationmark.arrow.circlepath"
        case .downloading: "arrow.down.circle.dotted"
        case .waitingForWiFi: "wifi.exclamationmark"
        case .streamingOnly, .none: "play.circle"
        }
    }

    private var readinessColor: Color {
        switch model.selectedPodcastDownloadState {
        case .failed, .evicted: AppColors.coral
        case .downloading, .waitingForWiFi: AppColors.ochre
        case .availableOffline, .streamingOnly, .none: AppColors.evergreen
        }
    }

    private func metadataPill(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppColors.secondaryText)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 9)
            .frame(minHeight: 30)
            .background(AppColors.panel, in: Capsule())
    }

    private func formatPlaybackTime(_ milliseconds: Int) -> String {
        let seconds = max(0, milliseconds / 1_000)
        if seconds >= 3_600 {
            return String(format: "%d:%02d:%02d", seconds / 3_600, (seconds % 3_600) / 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func sectionHeading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(.title3, design: .serif).weight(.bold))
            Text(detail).font(.caption).foregroundStyle(AppColors.secondaryText)
        }
    }

    private func sessionTitle(_ session: Session, index: Int) -> String {
        let marker = index == 0 ? "Most recent" : "Earlier session"
        guard let date = session.updatedAt ?? session.createdAt else { return marker }
        return "\(marker) · \(date.formatted(date: .abbreviated, time: .omitted))"
    }

}

// Playback publishes frequent model updates. The scene section depends only on
// its value inputs; keep those updates from rebuilding every summary row.
private struct ExperienceListeningMapSection: View, Equatable {
    let scenes: [MediaTimelineChapter]
    let model: Gate1AppModel

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scenes == rhs.scenes && lhs.model === rhs.model
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            sectionHeading("Listening Map", detail: "Scene navigation and Skim summaries")
            ExperienceSurface(tint: AppColors.evergreen.opacity(0.18)) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(scenes.enumerated()), id: \.element.id) { index, scene in
                        VStack(spacing: 0) {
                            if index > 0 { Divider() }
                            Button { model.jumpToListeningMapScene(scene) } label: {
                                HStack(spacing: 12) {
                                    Text(formatPlaybackTime(scene.startMs))
                                        .font(.caption.monospacedDigit().weight(.bold))
                                        .foregroundStyle(AppColors.evergreen)
                                        .frame(width: 52, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(scene.title)
                                            .font(.headline)
                                            .foregroundStyle(AppColors.text)
                                            .multilineTextAlignment(.leading)
                                        if let description = scene.description, !description.isEmpty {
                                            Text(description)
                                                .font(.caption)
                                                .foregroundStyle(AppColors.secondaryText)
                                                .lineLimit(3)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "play.fill")
                                        .foregroundStyle(AppColors.evergreen)
                                }
                                .frame(minHeight: 52)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("listeningMap.scene.jump.\(scene.id)")
                        }
                    }
                }
            }
        }
    }

    private func formatPlaybackTime(_ milliseconds: Int) -> String {
        let seconds = max(0, milliseconds / 1_000)
        if seconds >= 3_600 {
            return String(format: "%d:%02d:%02d", seconds / 3_600, (seconds % 3_600) / 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func sectionHeading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(.title3, design: .serif).weight(.bold))
            Text(detail).font(.caption).foregroundStyle(AppColors.secondaryText)
        }
    }

}

/// "Open in Readwise" once this item's Margins have been sent there (#623).
private struct ReadwiseItemLink: View {
    @ObservedObject var sync: ReadwiseHighlightSync
    let itemId: String

    var body: some View {
        if let url = sync.links[itemId] {
            Link(destination: url) {
                Label("Open in Readwise", systemImage: "arrow.up.right.square")
            }
            .accessibilityIdentifier("item.readwise.link")
        }
    }
}
