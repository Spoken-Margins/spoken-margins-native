import SwiftUI
import SessionKit

struct ExperienceItemDetailScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var confirmsTrash = false
    @State private var confirmsNewSession = false
    @State private var showsAdvanced = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    hero
                    primaryActions
                    SourceFollowSuggestionCard()
                    ManualSourceFollowButton()
                    if !model.selectedItem.overview.isEmpty { overview }
                    structure
                    recentMargins
                    sessions
                    readiness
                    advanced
                }
                .padding(.horizontal, horizontalSizeClass == .regular ? 30 : 18)
                .padding(.vertical, 22)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
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
                            model.openExport()
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
        }
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: 20) {
            SMExperienceTypeCover(
                id: model.selectedItem.id,
                mediaType: model.selectedItem.isNativeAudio ? "audiobook" : "text",
                sourceReferenceType: model.selectedItem.externalReference.isEmpty ? nil : "url",
                size: horizontalSizeClass == .regular ? 132 : 98
            )
            VStack(alignment: .leading, spacing: 9) {
                Text(heroStatusLabel.uppercased())
                    .font(.caption.weight(.bold))
                    .tracking(1)
                    .foregroundStyle(readinessColor)
                Text(model.selectedItem.title)
                    .font(.system(.largeTitle, design: .serif).weight(.bold))
                    .foregroundStyle(AppColors.text)
                    .lineLimit(4)
                    .minimumScaleFactor(0.72)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { metadataPills }
                    VStack(alignment: .leading, spacing: 7) { metadataPills }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var metadataPills: some View {
        metadataPill(itemStatusLabel, systemImage: "checkmark.circle")
        if chapterCount > 0 {
            metadataPill("\(chapterCount) chapters", systemImage: "list.bullet")
        }
        if !model.selectedItem.interjections.isEmpty {
            metadataPill("\(model.selectedItem.interjections.count) Margins", systemImage: "quote.bubble")
        }
    }

    private var chapterCount: Int {
        model.selectedItem.chapters.isEmpty
            ? model.selectedItem.mediaChapters.count
            : model.selectedItem.chapters.count
    }

    private var itemStatusLabel: String {
        if !model.selectedItem.mediaChapters.isEmpty,
           model.selectedItem.status == "needs_listening_map" {
            return "Publisher chapters"
        }
        return humanize(model.selectedItem.status)
    }

    private var heroStatusLabel: String {
        switch model.selectedPodcastDownloadState {
        case .availableOffline: "Available offline"
        case .downloading: "Downloading"
        case .waitingForWiFi: "Waiting for Wi-Fi"
        case .failed, .evicted: "Download needs attention"
        case .streamingOnly: "Ready to stream"
        case .none: itemStatusLabel
        }
    }

    private var primaryActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { primaryActionButtons }
            VStack(spacing: 10) { primaryActionButtons }
        }
    }

    @ViewBuilder
    private var primaryActionButtons: some View {
        Button {
            model.startItem(id: model.selectedItem.id)
        } label: {
            Label(model.selectedItemPreferredContinuationSession == nil ? "Start listening" : "Continue listening", systemImage: "play.fill")
                .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.borderedProminent)
        .tint(AppColors.evergreen)
        .accessibilityIdentifier("item.start.button")

        if model.selectedItemPreferredContinuationSession != nil {
            Button {
                confirmsNewSession = true
            } label: {
                Label("New session", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("item.startNew.button")
        }
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
                                        Text("\(row.session.completionPercent)% · \(row.interjectionCount) Margins")
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

    private var readiness: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("Listening readiness", detail: "Availability is separate from source structure")
            ExperienceSurface(tint: readinessColor.opacity(0.4)) {
                HStack(spacing: 12) {
                    Image(systemName: readinessIcon)
                        .font(.title2)
                        .foregroundStyle(readinessColor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(readinessLabel).font(.headline)
                        Text(model.selectedPodcastDownloadDescription ?? "This item can be played with its current preparation state.")
                            .font(.subheadline)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    Spacer()
                    switch model.selectedPodcastDownloadState {
                    case .waitingForWiFi, .streamingOnly:
                        Button("Download Now", action: model.downloadSelectedPodcastNow)
                            .buttonStyle(.borderedProminent)
                            .tint(AppColors.evergreen)
                    case .failed, .evicted:
                        Button("Retry Download", action: model.retrySelectedPodcastDownload)
                            .buttonStyle(.bordered)
                    case .downloading:
                        ProgressView()
                    case .availableOffline:
                        Label("Downloaded", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppColors.evergreen)
                    case .none:
                        EmptyView()
                    }
                }
                .accessibilityIdentifier("item.podcastDownload.status")
            }
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
                if model.canGenerateListeningMap {
                    Button(model.isGeneratingListeningMap ? "Generating map…" : "Generate optional listening map", systemImage: "sparkles") {
                        model.generateListeningMap()
                    }
                    .disabled(model.isGeneratingListeningMap)
                    .accessibilityIdentifier("item.generateMap.button")
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

    private var itemMargins: [MarginRow] {
        model.selectedItem.interjections
            .filter { $0.status == "active" }
            .sorted { $0.createdAt > $1.createdAt }
            .map { MarginRow(interjection: $0, itemTitle: model.selectedItem.title, sessionDate: nil) }
    }

    private var readinessLabel: String {
        model.selectedPodcastDownloadDescription ?? humanize(model.selectedItem.status)
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

    private func humanize(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
