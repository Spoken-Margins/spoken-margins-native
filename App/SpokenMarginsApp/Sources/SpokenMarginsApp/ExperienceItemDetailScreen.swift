import SwiftUI
import SessionKit
import SessionKitPersistence

struct ExperienceItemDetailScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @EnvironmentObject private var sharingCoordinator: Build23SharingCoordinator
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var confirmsTrash = false
    @State private var confirmsNewSession = false
    @State private var showsAdvanced = false
    /// Set while Continue waits on the "hear new Margins first?" question (#474).
    @State private var newMarginsOfferItemId: String?
    @State private var episodeLinkStatus = ImportedFileEpisodeLinker.Status()
    @State private var asksForEpisodeLink = false
    @State private var episodeLinkText = ""
    @State private var showsReactions = false
    @State private var collectionItem: LibraryItemRow?
    private let episodeLinker = ImportedFileEpisodeLinker()

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    hero
                    if let description = model.selectedItem.descriptionText {
                        ItemDescriptionPreview(text: description).id(model.selectedItem.id)
                    }
                    secondaryActions
                    downloadRecovery
                    ItemLastFailureCard(itemId: model.selectedItem.id)
                    if !sharingCoordinator.importedLayers.isEmpty {
                        Build23ImportedMarginPresentation(coordinator: sharingCoordinator)
                    }
                    reactionsEntry
                    SourceFollowSuggestionCard()
                    ManualSourceFollowButton()
                    if !model.selectedItem.overview.isEmpty { overview }
                    sessions
                    structure
                    if let edition = model.selectedListeningEdition { ListeningEditionScenes(edition: edition) }
                    if !model.selectedItem.listeningMapScenes.isEmpty { listeningMap }
                    recentMargins
                    itemLinks
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
            .announcesScreenChange()
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
                        quickActionButtons
                        if episodeLinkStatus.canLink && !episodeLinkStatus.canChange {
                            Button("Episode can't change: friends' Margins are on it", systemImage: "link") {}
                                .disabled(true)
                        }
                        if episodeLinkStatus.canLink && episodeLinkStatus.canChange {
                            Button(
                                episodeLinkStatus.episodeTitle == nil ? "This is a podcast episode…" : "Change linked episode…",
                                systemImage: "link.badge.plus"
                            ) {
                                episodeLinkText = ""
                                asksForEpisodeLink = true
                            }
                            .accessibilityIdentifier("item.linkEpisode.button")
                            if episodeLinkStatus.episodeTitle != nil {
                                Button("Unlink episode", systemImage: "minus.circle") { unlinkEpisode() }
                            }
                        }
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
            .task(id: model.selectedItem.id) { refreshEpisodeLinkStatus() }
            .sheet(item: $collectionItem) { item in
                ItemCollectionSheet(item: item).environmentObject(model)
            }
            .sheet(isPresented: $showsReactions) {
                ExperienceReactionsScreen().environmentObject(model)
            }
            .alert("Which episode is this?", isPresented: $asksForEpisodeLink) {
                TextField("Episode link", text: $episodeLinkText)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) {}
                Button("Link") { linkEpisode() }
            } message: {
                Text("Paste the link to this episode, like the one a friend shared. Margins a friend shares by link for it will then land on this file.")
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
            .miniPlayerKeepOut()
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.selectedItem.title)
                .font(.title.weight(.bold))
                .screenTitle()
                .foregroundStyle(AppColors.text)
                .fixedSize(horizontal: false, vertical: true)
            if let published = model.selectedItem.publishedDateText {
                Text(published)
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
                    .accessibilityIdentifier("item.publishedDate")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { metadataPills }
                VStack(alignment: .leading, spacing: 7) { metadataPills }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func refreshEpisodeLinkStatus() {
        guard let store = model.store, !model.selectedItem.id.isEmpty else {
            episodeLinkStatus = ImportedFileEpisodeLinker.Status()
            return
        }
        episodeLinkStatus = episodeLinker.status(itemId: model.selectedItem.id, store: store)
    }

    private func linkEpisode() {
        guard let store = model.store else { return }
        let itemId = model.selectedItem.id
        let pasted = episodeLinkText
        Task { @MainActor in
            do {
                let title = try await episodeLinker.link(itemId: itemId, to: pasted, store: store)
                refreshEpisodeLinkStatus()
                model.refreshSpokenMarginsPackageImportAfterAddingSource()
                model.reportConfirmation("Linked to \u{201C}\(title)\u{201D}. Margins a friend shares by link for it will land on this file.")
            } catch {
                model.reportFailure(error.localizedDescription, itemId: itemId)
            }
        }
    }

    private func unlinkEpisode() {
        guard let store = model.store else { return }
        do {
            try episodeLinker.unlink(itemId: model.selectedItem.id, store: store)
            refreshEpisodeLinkStatus()
            model.reportConfirmation("Episode unlinked. The file and its Margins are unchanged.")
        } catch {
            model.reportFailure(error.localizedDescription, itemId: model.selectedItem.id)
        }
    }

    @ViewBuilder
    private var metadataPills: some View {
        if let episodeTitle = episodeLinkStatus.episodeTitle {
            metadataPill("Episode: \(episodeTitle)", systemImage: "link")
        }
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

    /// The Library row's Mark Complete, Add to Collection and Prepare Offline, as visible menu entries (#1973).
    /// They call what the row's swipe and long-press call. The row is the Library's, so an item the Library
    /// doesn't list gets none.
    @ViewBuilder private var quickActionButtons: some View {
        if let row = model.libraryItems.first(where: { $0.id == model.selectedItem.id }) {
            ForEach(ItemQuickAction.actions(for: row), id: \.self) { action in
                switch action {
                case .markComplete:
                    Button("Mark Complete", systemImage: "checkmark.circle") { model.markItemCompleted(id: row.id) }
                        .accessibilityIdentifier("item.markComplete.button")
                case .markUnfinished:
                    Button("Mark Not Complete", systemImage: "arrow.uturn.backward.circle") { model.markItemUnfinished(id: row.id) }
                        .accessibilityIdentifier("item.markUnfinished.button")
                case .addToCollection:
                    Button("Add to Collection…", systemImage: "folder.badge.plus") { collectionItem = row }
                        .accessibilityIdentifier("item.addToCollection.button")
                case .prepareOffline:
                    Button("Prepare Offline", systemImage: "arrow.down.circle") { model.prioritizeOfflinePreparation(id: row.id) }
                        .accessibilityIdentifier("item.prepareOffline.button")
                }
            }
        }
    }

    @ViewBuilder
    private var secondaryActions: some View {
        if model.selectedItemPreferredContinuationSession != nil || hasItemMargins || !newSharedMargins.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { secondaryActionButtons }
                VStack(alignment: .leading, spacing: 8) { secondaryActionButtons }
            }
        }
    }

    /// "Where people reacted" (#476): offered once the item has Margins from two or more people.
    @ViewBuilder
    private var reactionsEntry: some View {
        let item = model.selectedItem
        if MarginLayerSynthesis.offersReactions(
            itemId: item.id,
            layers: item.importedCommentaryLayers,
            interjections: item.importedCommentaryInterjections,
            ownMargins: item.interjections
        ) {
            Button {
                showsReactions = true
            } label: {
                Label("Where people reacted", systemImage: "person.2.fill")
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .expandedHitArea(vertical: 2)
            }
            .buttonStyle(.bordered)
            .tint(AppColors.evergreen)
            .accessibilityIdentifier("item.reactions.button")
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
                    .expandedHitArea(vertical: 2)
            }
            .buttonStyle(.bordered)
            .tint(AppColors.evergreen)
            .accessibilityIdentifier("item.startNew.button")
        }

        if hasItemMargins {
            Button {
                model.marginCollectionQuery = MarginCollectionQuery(itemID: model.selectedItem.id)
                model.openMargins()
            } label: {
                Label("Review Margins", systemImage: "quote.bubble")
                    .frame(minHeight: 40)
                    .expandedHitArea(vertical: 2)
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
                                GutterRow(gutterWidth: 42, spacing: 8) {
                                    Text("\(chapter.percent)%")
                                        .font(.caption.monospacedDigit().weight(.bold))
                                        .foregroundStyle(AppColors.evergreen)
                                } content: {
                                    HStack {
                                        Text(chapter.title)
                                            .font(.headline)
                                            .foregroundStyle(AppColors.text)
                                        Spacer()
                                        Image(systemName: "play.fill")
                                            .foregroundStyle(AppColors.evergreen)
                                            .accessibilityHidden(true)
                                    }
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
                                GutterRow(gutterWidth: 52, alignment: .center, spacing: 12) {
                                    Text(formatPlaybackTime(chapter.startMs))
                                        .font(.caption.monospacedDigit().weight(.bold))
                                        .foregroundStyle(AppColors.evergreen)
                                } content: {
                                    HStack(spacing: 12) {
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
                                            .accessibilityHidden(true)
                                    }
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
        ExperienceListeningMapSection(
            scenes: model.selectedItem.listeningMapScenes,
            isCommunityMap: model.selectedItem.listeningMapIsCommunity,
            model: model
        )
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
                                        .accessibilityHidden(true)
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
                                        .accessibilityHidden(true)
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

    /// "Open Original Source" and "Open in Readwise" side by side above Advanced, one under the other
    /// when they don't fit (narrow phones, large text).
    private var itemLinks: some View {
        ItemLinksRow(
            sync: model.readwiseHighlightSync,
            itemId: model.selectedItem.id,
            originalSource: model.selectedItem.originalSourceURL
        )
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
                                .accessibilityLabel("Resume this session")
                                .accessibilityIdentifier("session.resume.\(row.session.id)")
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
            // The status beside its button, or one above the other when they don't fit (large text, #1938).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    downloadStatusLabel
                    Spacer(minLength: 8)
                    downloadRecoveryControl
                }
                VStack(alignment: .leading, spacing: 8) {
                    downloadStatusLabel
                    downloadRecoveryControl
                }
            }
            .accessibilityIdentifier("item.podcastDownload.status")
        case .availableOffline:
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    downloadStatusLabel
                        .accessibilityIdentifier("item.podcastDownload.saved")
                    Spacer(minLength: 8)
                    Button("Download Again", action: model.redownloadSelectedPodcast)
                        .buttonStyle(.bordered)
                }
                VStack(alignment: .leading, spacing: 8) {
                    downloadStatusLabel
                        .accessibilityIdentifier("item.podcastDownload.saved")
                    Button("Download Again", action: model.redownloadSelectedPodcast)
                        .buttonStyle(.bordered)
                }
            }
        case .none:
            EmptyView()
        }
    }

    private var downloadStatusLabel: some View {
        Label(readinessLabel, systemImage: readinessIcon)
            .font(.subheadline)
            .foregroundStyle(readinessColor)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var downloadRecoveryControl: some View {
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
            if let progress = model.selectedPodcastDownloadProgress {
                ProgressView(value: progress)
                    .tint(readinessColor)
                    .frame(width: 72)
                    .accessibilityLabel("Download progress")
            } else {
                ProgressView()
                    .accessibilityLabel("Downloading")
                    .tint(readinessColor)
            }
        case .availableOffline, .none:
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

    /// `!itemMargins.isEmpty` without building and sorting the rows, for the checks `body` makes on every render.
    private var hasItemMargins: Bool {
        model.selectedItem.interjections.contains { $0.status == "active" }
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
        case .downloading: model.selectedPodcastDownloadStatusText ?? "Downloading"
        case .availableOffline: model.selectedPodcastDownloadStatusText ?? "Available offline"
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
    let isCommunityMap: Bool
    let model: Gate1AppModel

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scenes == rhs.scenes && lhs.isCommunityMap == rhs.isCommunityMap && lhs.model === rhs.model
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            sectionHeading(
                isCommunityMap ? "Community map" : "Listening Map",
                detail: isCommunityMap
                    ? "Made from other listeners' transcripts. Scene navigation and Skim summaries."
                    : "Scene navigation and Skim summaries"
            )
            .accessibilityIdentifier(isCommunityMap ? "listeningMap.heading.community" : "listeningMap.heading")
            ExperienceSurface(tint: AppColors.evergreen.opacity(0.18)) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(scenes.enumerated()), id: \.element.id) { index, scene in
                        VStack(spacing: 0) {
                            if index > 0 { Divider() }
                            Button { model.jumpToListeningMapScene(scene) } label: {
                                GutterRow(gutterWidth: 52, alignment: .center, spacing: 12) {
                                    Text(formatPlaybackTime(scene.startMs))
                                        .font(.caption.monospacedDigit().weight(.bold))
                                        .foregroundStyle(AppColors.evergreen)
                                } content: {
                                    HStack(spacing: 12) {
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
                                            .accessibilityHidden(true)
                                    }
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

/// The links off the Item screen: the original page (#1167), and Readwise once this item's Margins
/// have been sent there (#623). Nothing here fetches anything; the system browser opens the address.
private struct ItemLinksRow: View {
    @ObservedObject var sync: ReadwiseHighlightSync
    let itemId: String
    let originalSource: URL?

    var body: some View {
        let readwise = sync.links[itemId]
        if originalSource != nil || readwise != nil {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 24) { links(readwise: readwise) }
                VStack(alignment: .leading, spacing: 0) { links(readwise: readwise) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func links(readwise: URL?) -> some View {
        if let originalSource {
            Link(destination: originalSource) {
                // The height is inside the label so the whole 44 pt row takes the tap, not only the text.
                Label("Open Original Source", systemImage: "safari")
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("item.originalSource.link")
        }
        if let readwise {
            Link(destination: readwise) {
                // The height is inside the label so the whole 44 pt row takes the tap, not only the text.
                Label("Open in Readwise", systemImage: "arrow.up.right.square")
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("item.readwise.link")
        }
    }
}

/// The publisher's description under the title: its first three lines, with More to read the rest in place (#1322).
/// The text is whole to VoiceOver either way; only the sighted preview is cut.
private struct ItemDescriptionPreview: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(AppColors.secondaryText)
                .lineLimit(expanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("item.description.text")
            if ItemMetadata.needsExpansion(text) {
                Button(expanded ? "Less" : "More") { expanded.toggle() }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44, alignment: .leading)
                    .accessibilityHint(expanded ? "Shows fewer lines of the description." : "Shows the whole description.")
                    .accessibilityIdentifier("item.description.more")
            }
        }
    }
}
