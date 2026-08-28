import SwiftUI
import SessionKit
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

struct ExperienceRootTabs: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Binding var navigation: AppNavigationState

    private var rootSelection: Binding<AppRoot> {
        Binding(
            get: { navigation.selectedRoot },
            set: { navigation.select($0, recordingIsLocked: model.recordingNavigationIsLocked) }
        )
    }

    var body: some View {
        TabView(selection: rootSelection) {
            ExperienceLibraryRoot(addSourceRoute: addSourceRoute)
                .tabItem {
                    Label("Library", systemImage: AppRoot.library.systemImage)
                        .accessibilityIdentifier("navigation.tab.library")
                }
                .tag(AppRoot.library)

            ExperienceSourcesRoot(addSourceRoute: addSourceRoute)
                .tabItem {
                    Label("Sources", systemImage: AppRoot.sources.systemImage)
                        .accessibilityIdentifier("navigation.tab.sources")
                }
                .tag(AppRoot.sources)

            ExperienceMarginsRoot()
                .tabItem {
                    Label("Margins", systemImage: AppRoot.margins.systemImage)
                        .accessibilityIdentifier("navigation.tab.margins")
                }
                .tag(AppRoot.margins)
        }
        .tabViewStyle(.sidebarAdaptable)
        .tint(AppColors.evergreen)
        .sheet(item: addSourceRoute) { route in
            ExperienceAddSourceFlow(initialRoute: route)
                .environmentObject(model)
        }
    }

    private var addSourceRoute: Binding<AddSourceRoute?> {
        Binding(
            get: { navigation.addSourceRoute },
            set: { navigation.addSourceRoute = $0 }
        )
    }
}

private struct ExperienceLibraryRoot: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Binding var addSourceRoute: AddSourceRoute?
    @State private var pendingTrashItem: LibraryItemRow?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ExperiencePageHeader(
                        eyebrow: "YOUR LISTENING LIFE",
                        title: "Library",
                        subtitle: "Return to what matters, without losing your place."
                    )
                    if model.shouldShowOnboardingCard {
                        starterChoices
                    }
                    if let continueItem {
                        continueCard(continueItem)
                    }
                    libraryControls
                    libraryItems
                }
                .padding(20)
                .frame(maxWidth: horizontalSizeClass == .regular ? 920 : .infinity)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("home.screen")
            }
            .background(AppColors.bone)
            .accessibilityIdentifier("library.screen")
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack {
                        Button(action: model.openSettings) {
                            Image(systemName: "gearshape")
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Settings")
                        .accessibilityIdentifier("home.settings.button")
                        Button(action: model.openHelp) {
                            Image(systemName: "questionmark.circle")
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Help")
                        .accessibilityIdentifier("home.help.button")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(action: model.openBatchExport) {
                        Image(systemName: "square.and.arrow.up.on.square")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Export sessions")
                    .accessibilityIdentifier("home.batchExport.button")
                    Button {
                        addSourceRoute = .linkOrPodcast
                    } label: {
                        Label("Add Source", systemImage: "plus")
                    }
                    .accessibilityIdentifier("home.addSource.button")
                }
            }
            .alert(
                "Move to Recently Deleted?",
                isPresented: Binding(
                    get: { pendingTrashItem != nil },
                    set: { if !$0 { pendingTrashItem = nil } }
                ),
                presenting: pendingTrashItem
            ) { item in
                Button("Cancel", role: .cancel) {}
                Button("Move to Recently Deleted", role: .destructive) {
                    model.moveItemToTrash(id: item.id)
                    pendingTrashItem = nil
                }
            } message: { item in
                Text("\(item.title) can be restored from Settings.")
            }
        }
    }

    private var continueItem: LibraryItemRow? {
        LibraryPresentation.continueItem(
            in: model.libraryItems,
            activeItemId: model.activePlaybackItemId
        )
    }

    private var starterChoices: some View {
        ExperienceCard(tint: AppColors.ochre) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Choose a first listen")
                            .font(.title3.weight(.semibold))
                        Text("Both choices use the same Library, player, recording, and Timeline you’ll use for your own sources.")
                            .font(.subheadline)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    Spacer(minLength: 12)
                    Button(action: model.dismissOnboardingCard) {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Skip starter choices")
                }
                starterButton(
                    title: "What Spoken Margins is for",
                    detail: "A concise product overview",
                    systemImage: "book.pages",
                    action: { model.startItem(id: Gate1AppModel.welcomeSampleItemId) }
                )
                starterButton(
                    title: "Practice a Margin",
                    detail: "A guided, hands-on listening session",
                    systemImage: "quote.bubble",
                    action: model.startGuidedOnboarding
                )
            }
        }
        .accessibilityIdentifier("library.onboarding.starters")
    }

    private func starterButton(
        title: String,
        detail: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(AppColors.evergreen)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                }
                Spacer()
                Image(systemName: "play.fill")
                    .foregroundStyle(AppColors.evergreen)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(AppColors.panel.opacity(0.8))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func continueCard(_ item: LibraryItemRow) -> some View {
        ExperienceCard(tint: AppColors.evergreen) {
            VStack(alignment: .leading, spacing: 14) {
                Label("Continue listening", systemImage: "play.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.evergreen)
                HStack(alignment: .center, spacing: 16) {
                    Button {
                        model.openItem(id: item.id)
                    } label: {
                        HStack(alignment: .center, spacing: 16) {
                            ExperienceTypeCover(row: item, size: 76)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.title)
                                    .font(.system(.title2, design: .serif).weight(.semibold))
                                    .foregroundStyle(AppColors.text)
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(3)
                                if let source = item.sourceTitle ?? item.author {
                                    Text(source)
                                        .font(.subheadline)
                                        .foregroundStyle(AppColors.secondaryText)
                                        .lineLimit(1)
                                }
                                if let progress = item.continuationProgressPercent {
                                    ProgressView(value: Double(progress), total: 100)
                                        .tint(AppColors.ochre)
                                        .accessibilityValue("\(progress) percent complete")
                                }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("library.row.\(item.id)")
                    Spacer(minLength: 4)
                    Button {
                        model.startItem(id: item.id)
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(AppColors.evergreen)
                            .clipShape(Circle())
                    }
                    .accessibilityLabel("Continue \(item.title)")
                    .accessibilityIdentifier("library.continue.\(item.id)")
                }
            }
        }
    }

    private var libraryControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search title, source, or author", text: $model.libraryQuery.query)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)
                .accessibilityIdentifier("library.search.field")
            ViewThatFits(in: .horizontal) {
                HStack { filterMenu; sortMenu; Spacer() }
                VStack(alignment: .leading) { filterMenu; sortMenu }
            }
            .onChange(of: model.libraryQuery) { _, _ in model.libraryQueryChanged() }
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Content Type", selection: $model.libraryQuery.contentType) {
                ForEach(LibraryContentTypeFilter.allCases, id: \.self) {
                    Text(displayName($0.rawValue)).tag($0)
                }
            }
            Picker("Listening", selection: $model.libraryQuery.listeningState) {
                ForEach(LibraryListeningStateFilter.allCases, id: \.self) {
                    Text(displayName($0.rawValue)).tag($0)
                }
            }
            Picker("Offline", selection: $model.libraryQuery.offlineState) {
                ForEach(LibraryOfflineStateFilter.allCases, id: \.self) {
                    Text(displayName($0.rawValue)).tag($0)
                }
            }
        } label: {
            Label(model.libraryFilterDescription, systemImage: "line.3.horizontal.decrease.circle")
                .frame(minHeight: 44)
        }
        .accessibilityIdentifier("library.filter.menu")
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $model.libraryQuery.sort) {
                ForEach(LibrarySort.allCases, id: \.self) {
                    Text(displayName($0.rawValue)).tag($0)
                }
            }
        } label: {
            Label(model.librarySortDescription, systemImage: "arrow.up.arrow.down")
                .frame(minHeight: 44)
        }
        .accessibilityIdentifier("library.sort.menu")
    }

    @ViewBuilder
    private var libraryItems: some View {
        if model.libraryItems.isEmpty {
            ExperienceEmptyState(
                systemImage: "books.vertical",
                title: "Your library is ready for a first source",
                detail: "Add a link, paste text, choose a document or book, or import an audiobook.",
                actionTitle: "Add Source"
            ) {
                addSourceRoute = .linkOrPodcast
            }
        } else {
            let rows = LibraryPresentation.compactItems(model.visibleLibraryItems, excluding: continueItem)
            if rows.isEmpty {
                ExperienceEmptyState(
                    systemImage: "magnifyingglass",
                    title: "No matches",
                    detail: "Try a different search or clear one of the filters.",
                    actionTitle: "Clear Filters"
                ) {
                    model.libraryQuery = LibraryQuery()
                    model.libraryQueryChanged()
                }
            } else {
                ForEach(rows) { row in
                    ExperienceLibraryRow(row: row) {
                        model.openItem(id: row.id)
                    } onPlay: {
                        model.startItem(id: row.id)
                    } onDelete: {
                        pendingTrashItem = row
                    }
                }
            }
        }
    }

    private func displayName(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private struct ExperienceLibraryRow: View {
    let row: LibraryItemRow
    let onOpen: () -> Void
    let onPlay: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ExperienceCard {
            HStack(spacing: 14) {
                ExperienceTypeCover(row: row, size: 58)
                Button(action: onOpen) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(row.title)
                            .font(.headline)
                            .foregroundStyle(AppColors.text)
                            .multilineTextAlignment(.leading)
                            .lineLimit(3)
                        Text(metadata)
                            .font(.subheadline)
                            .foregroundStyle(AppColors.secondaryText)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                        if let progress = row.continuationProgressPercent {
                            Text("\(progress)% complete")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppColors.evergreen)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("library.row.\(row.id)")

                Button(action: onPlay) {
                    Image(systemName: "play.fill")
                        .frame(width: 44, height: 44)
                        .background(AppColors.softGreen)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .accessibilityLabel(row.hasContinuationSession ? "Continue \(row.title)" : "Start \(row.title)")
                .accessibilityIdentifier("queue.start.\(row.id)")
            }
        }
        .contextMenu {
            Button("Open", systemImage: "arrow.right", action: onOpen)
            Button(row.hasContinuationSession ? "Continue" : "Start", systemImage: "play", action: onPlay)
            if row.canDelete {
                Button("Move to Recently Deleted", systemImage: "trash", role: .destructive, action: onDelete)
            }
        }
        .accessibilityAction(named: "Move to Recently Deleted", onDelete)
    }

    private var metadata: String {
        [row.sourceTitle ?? row.author, row.mediaType == "text" ? nil : row.mediaType.capitalized, row.status]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")
    }
}

private struct ExperienceSourcesRoot: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Binding var addSourceRoute: AddSourceRoute?
    @State private var isExpanded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ExperiencePageHeader(
                        eyebrow: "EXPLICITLY FOLLOWED",
                        title: "New from Sources",
                        subtitle: "A quiet inbox for feeds and files you chose. Nothing enters Library until you add it."
                    )
                    if model.selectedProfileId.contains("offline") {
                        Label("Showing the last available local snapshot", systemImage: "wifi.slash")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    followSource
                    SourceFollowSuggestionCard()
                    sourceInbox
                }
                .padding(20)
                .frame(maxWidth: horizontalSizeClass == .regular ? 920 : .infinity)
                .frame(maxWidth: .infinity)
            }
            .background(AppColors.bone)
            .accessibilityIdentifier("sources.screen")
            .navigationTitle("Sources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: model.openSettings) {
                        Image(systemName: "gearshape").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Settings")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        model.refreshQuickAddFeed()
                    } label: {
                        if model.isRefreshingQuickAddFeed { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(model.isRefreshingQuickAddFeed)
                    .accessibilityLabel("Refresh Sources")
                    .accessibilityIdentifier("quickAdd.refresh.button")
                    Button {
                        addSourceRoute = .linkOrPodcast
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .accessibilityIdentifier("sources.add.button")
                }
            }
            .task { model.refreshQuickAddFeed(force: false) }
        }
    }

    private var followSource: some View {
        ExperienceCard(tint: AppColors.evergreen) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Follow a feed")
                    .font(.headline)
                Text("Following only adds future entries to this inbox. It does not import, download, or prepare them.")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
                HStack {
                    TextField("HTTPS feed URL", text: $model.followedSourceURL)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .accessibilityIdentifier("sources.follow.url")
                    Button("Follow", action: model.followSource)
                        .buttonStyle(.borderedProminent)
                        .tint(AppColors.evergreen)
                        .disabled(model.followedSourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("sources.follow.button")
                }
                ForEach(model.followedSourceCandidates) { candidate in
                    Button {
                        model.followSourceCandidate(candidate)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(candidate.source.title ?? candidate.source.host).font(.headline)
                            Text(candidate.source.canonicalURL)
                                .font(.caption)
                                .foregroundStyle(AppColors.secondaryText)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }
                if !model.followedSourceCandidates.isEmpty {
                    Button("Cancel", action: model.cancelFollowSourceCandidates)
                }
            }
        }
    }

    @ViewBuilder
    private var sourceInbox: some View {
        let candidates = model.quickAddCandidates
        HStack {
            Text("Inbox")
                .font(.system(.title2, design: .serif).weight(.semibold))
            Spacer()
            if model.hasQuickAccessFolder {
                Label(model.quickAccessFolderName, systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
                    .lineLimit(1)
            }
            if !model.feedSubscriptions.isEmpty {
                sourceManagementMenu
            }
        }
        if candidates.isEmpty {
            ExperienceEmptyState(
                systemImage: "tray",
                title: "You’re caught up",
                detail: "Follow a feed or choose a Quick Folder. New entries will wait here for an explicit Add or Dismiss choice.",
                actionTitle: "Choose Quick Folder"
            ) {
                addSourceRoute = .quickFolder
            }
        } else {
            ForEach(candidates.prefix(isExpanded ? candidates.count : 8)) { candidate in
                ExperienceSourceCandidateRow(candidate: candidate)
            }
            if candidates.count > 8 {
                Button(isExpanded ? "Show fewer" : "Show \(candidates.count - 8) more") {
                    withAnimation(.snappy) { isExpanded.toggle() }
                }
                .frame(minHeight: 44)
            }
        }
    }

    private var sourceManagementMenu: some View {
        Menu {
            ForEach(model.feedSubscriptions) { subscription in
                Button(subscription.state == .muted ? "Unmute \(subscription.source.title ?? subscription.source.host)" : "Mute \(subscription.source.title ?? subscription.source.host)") {
                    model.toggleMuteSource(id: subscription.id)
                }
                Button("Unfollow \(subscription.source.title ?? subscription.source.host)", role: .destructive) {
                    model.unfollowSource(id: subscription.id)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Manage Sources")
    }
}

private struct ExperienceSourceCandidateRow: View {
    @EnvironmentObject private var model: Gate1AppModel
    let candidate: QuickAddCandidate

    var body: some View {
        ExperienceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: systemImage)
                        .font(.title2)
                        .foregroundStyle(AppColors.evergreen)
                        .frame(width: 44, height: 44)
                        .background(AppColors.softGreen)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.headline).lineLimit(3)
                        Text(provenance)
                            .font(.subheadline)
                            .foregroundStyle(AppColors.secondaryText)
                        if let summary, !summary.isEmpty {
                            Text(summary)
                                .font(.subheadline)
                                .foregroundStyle(AppColors.secondaryText)
                                .lineLimit(3)
                        }
                    }
                    Spacer(minLength: 0)
                }
                HStack {
                    Button("Dismiss", role: .cancel, action: dismiss)
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)
                    Spacer()
                    Button("Add", action: add)
                        .buttonStyle(.borderedProminent)
                        .tint(AppColors.evergreen)
                        .frame(minHeight: 44)
                        .disabled(isImporting)
                }
            }
        }
        .accessibilityIdentifier(identifier)
    }

    private var title: String {
        switch candidate {
        case .localFile(let file): file.name
        case .followedSource(let entry): entry.title
        }
    }

    private var summary: String? {
        switch candidate {
        case .localFile: nil
        case .followedSource(let entry): entry.summary
        }
    }

    private var provenance: String {
        switch candidate {
        case .localFile(let file):
            return "Quick Folder · \(model.quickAccessFolderName) · \(file.modifiedAtDescription)"
        case .followedSource(let entry):
            let source = model.feedSubscriptions.first(where: { $0.id == entry.subscriptionId })?.source
            return "Followed feed · \(source?.title ?? source?.host ?? entry.author ?? "Source")"
        }
    }

    private var systemImage: String {
        switch candidate {
        case .localFile: "folder"
        case .followedSource: "dot.radiowaves.left.and.right"
        }
    }

    private var identifier: String {
        switch candidate {
        case .localFile(let file): "quickAdd.folder.\(file.id)"
        case .followedSource(let entry): "sources.entry.\(entry.id)"
        }
    }

    private var isImporting: Bool {
        switch candidate {
        case .localFile: model.isImportingSources
        case .followedSource(let entry): model.importingFollowedSourceEntryIds.contains(entry.id)
        }
    }

    private func add() {
        switch candidate {
        case .localFile(let file): model.importQuickAccessFile(file)
        case .followedSource(let entry): model.importFollowedSourceEntry(entry)
        }
    }

    private func dismiss() {
        switch candidate {
        case .localFile(let file): model.dismissQuickAccessFile(file)
        case .followedSource(let entry): model.dismissFollowedSourceEntry(id: entry.id)
        }
    }
}

private struct ExperienceMarginsRoot: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedMargin: MarginRow?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ExperiencePageHeader(
                        eyebrow: "YOUR PRIVATE COMMENTARY",
                        title: "Margins",
                        subtitle: "Find the thoughts you saved across listening sessions."
                    )
                    if model.marginRows.isEmpty {
                        ExperienceEmptyState(
                            systemImage: "quote.bubble",
                            title: "No Margins yet",
                            detail: "While listening, tap Interject and speak what you want to remember.",
                            actionTitle: "Open Now Playing"
                        ) {
                            model.openPlayback()
                        }
                    } else {
                        let attention = model.marginRows.filter(\.needsAttention)
                        if !attention.isEmpty {
                            marginSection("Needs attention", rows: attention, tint: AppColors.coral)
                        }
                        ForEach(groupedItems, id: \.title) { group in
                            marginSection(group.title, rows: group.rows, tint: AppColors.ochre)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: horizontalSizeClass == .regular ? 920 : .infinity)
                .frame(maxWidth: .infinity)
            }
            .background(AppColors.bone)
            .accessibilityIdentifier("margins.screen")
            .navigationTitle("Margins")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: model.openSettings) {
                        Image(systemName: "gearshape").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: model.refreshMarginRows) {
                        Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Refresh Margins")
                }
            }
            .task { model.refreshMarginRows() }
            .sheet(item: $selectedMargin) { row in
                ExperienceMarginDetailView(row: row)
                    .environmentObject(model)
            }
        }
    }

    private var groupedItems: [(title: String, rows: [MarginRow])] {
        let attentionIDs = Set(model.marginRows.filter(\.needsAttention).map(\.id))
        let ordinary = model.marginRows.filter { !attentionIDs.contains($0.id) }
        let order = ordinary.reduce(into: [String]()) { result, row in
            if !result.contains(row.itemTitle) { result.append(row.itemTitle) }
        }
        let groups = Dictionary(grouping: ordinary, by: \.itemTitle)
        return order.map { ($0, groups[$0, default: []]) }
    }

    @ViewBuilder
    private func marginSection(_ title: String, rows: [MarginRow], tint: Color) -> some View {
        Text(title)
            .font(.system(.title2, design: .serif).weight(.semibold))
        ForEach(rows) { row in
            Button {
                selectedMargin = row
            } label: {
                ExperienceCard(tint: tint) {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: row.needsAttention ? "exclamationmark.bubble" : "quote.bubble.fill")
                            .font(.title2)
                            .foregroundStyle(tint)
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(row.preview)
                                .font(.headline)
                                .foregroundStyle(AppColors.text)
                                .multilineTextAlignment(.leading)
                                .lineLimit(4)
                            Text(row.needsAttention ? row.attentionDescription : "\(row.targetDescription) · \(row.itemTitle)")
                                .font(.subheadline)
                                .foregroundStyle(AppColors.secondaryText)
                            if let date = row.sessionDate {
                                Text("Session updated \(date.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption)
                                    .foregroundStyle(AppColors.secondaryText)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .foregroundStyle(AppColors.secondaryText)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("My Margin. \(row.preview). \(row.itemTitle)")
            .accessibilityIdentifier("margins.row.\(row.id)")
        }
    }
}

struct ExperienceRecordingView: View {
    @EnvironmentObject private var model: Gate1AppModel

    var body: some View {
        ZStack {
            AppColors.watchBackground.ignoresSafeArea()
            VStack(spacing: 28) {
                Spacer()
                Image(systemName: "quote.bubble.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(AppColors.coral)
                    .accessibilityHidden(true)
                Text("Recording a Margin")
                    .font(.system(.largeTitle, design: .serif).weight(.bold))
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("recording.screen")
                VStack(spacing: 8) {
                    Text(context.itemTitle)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Text(context.locationTitle)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.watchSecondary)
                        .multilineTextAlignment(.center)
                    Text("Anchored at \(context.progressPercent)%")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColors.watchSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Recording anchor. \(context.itemTitle), \(context.locationTitle), \(context.progressPercent) percent")
                .accessibilityIdentifier("recording.anchor")

                TimelineView(.periodic(from: context.startedAt, by: 1)) { timeline in
                    Text(elapsedDescription(at: timeline.date))
                        .font(.system(.title, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.white)
                        .accessibilityLabel("Recording duration \(elapsedDescription(at: timeline.date))")
                }

                if let error = model.lastError {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(AppColors.coral.opacity(0.8))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    Text("Your listening position is held until you finish or cancel.")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.watchSecondary)
                        .multilineTextAlignment(.center)
                }
                Spacer()
                VStack(spacing: 12) {
                    Button(action: model.finishInterjection) {
                        Label("Finish Margin", systemImage: "checkmark")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 56)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppColors.ochre)
                    .foregroundStyle(AppColors.interjectText)
                    .accessibilityIdentifier("recording.finish.button")
                    Button(role: .destructive, action: model.cancelInterjection) {
                        Label("Cancel", systemImage: "xmark")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .accessibilityIdentifier("recording.cancel.button")
                }
                .padding(.bottom, 20)
            }
            .padding(24)
            .frame(maxWidth: 560)
        }
        .accessibilityAction(.escape, model.cancelInterjection)
    }

    private var context: RecordingPresentationContext {
        model.recordingPresentationContext ?? RecordingPresentationContext(
            itemTitle: model.selectedItem.title.isEmpty ? "Current item" : model.selectedItem.title,
            locationTitle: model.snapshot.chapterTitle ?? "Current listening position",
            progressPercent: model.snapshot.currentPlaybackProgressPercent,
            startedAt: Date()
        )
    }

    private func elapsedDescription(at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(context.startedAt)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

struct ExperienceOfflineStorageScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @State private var confirmsClear = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ExperiencePageHeader(
                        eyebrow: "ONE HONEST LEDGER",
                        title: "Offline Storage",
                        subtitle: "Prepared media can be recreated. Your imported audio, recordings, and Margins stay protected."
                    )
                    ExperienceCard(tint: AppColors.evergreen) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(bytes(snapshot.usedBytes))
                                    .font(.system(.title, design: .serif).weight(.semibold))
                                Text("used")
                                    .foregroundStyle(AppColors.secondaryText)
                                Spacer()
                                Text("of \(bytes(snapshot.budgetBytes))")
                                    .font(.subheadline.weight(.semibold))
                            }
                            ProgressView(
                                value: Double(snapshot.totalCommittedAndReservedBytes),
                                total: Double(max(1, snapshot.budgetBytes))
                            )
                            .tint(snapshot.currentOverageBytes > 0 ? AppColors.coral : AppColors.evergreen)
                            if snapshot.reservedBytes > 0 {
                                LabeledContent("Reserved for work in progress", value: bytes(snapshot.reservedBytes))
                            }
                            if snapshot.currentOverageBytes > 0 {
                                Text("Currently \(bytes(snapshot.currentOverageBytes)) over budget.")
                                    .foregroundStyle(AppColors.coral)
                            }
                            if snapshot.residualOverageBytes > 0 {
                                Text("After every safely reproducible asset is cleared, \(bytes(snapshot.residualOverageBytes)) remains because protected work is never evicted automatically.")
                                    .font(.subheadline)
                                    .foregroundStyle(AppColors.secondaryText)
                            }
                        }
                    }
                    Picker("Storage Budget", selection: $model.offlineStorageLimitGB) {
                        ForEach(OfflineStorageBudget.allowedGigabytes, id: \.self) {
                            Text("\($0) GB").tag($0)
                        }
                    }
                    .onChange(of: model.offlineStorageLimitGB) { _, _ in model.offlineStorageBudgetChanged() }
                    .accessibilityIdentifier("offlineStorage.budget.picker")

                    ExperienceCard {
                        VStack(alignment: .leading, spacing: 10) {
                            LabeledContent("Protected or irreplaceable", value: bytes(snapshot.protectedBytes))
                                .accessibilityIdentifier("offlineStorage.protected.row")
                            LabeledContent("Reproducible", value: bytes(snapshot.reproducibleBytes))
                                .accessibilityIdentifier("offlineStorage.reproducible.row")
                            LabeledContent("Safe to clear now", value: bytes(snapshot.clearableBytes))
                                .accessibilityIdentifier("offlineStorage.clearable.row")
                        }
                    }
                    if !snapshot.categories.isEmpty {
                        Text("By category")
                            .font(.system(.title2, design: .serif).weight(.semibold))
                        ForEach(snapshot.categories) { row in
                            ExperienceCard {
                                LabeledContent(row.title, value: bytes(row.byteCount))
                            }
                        }
                    }
                    Button(role: .destructive) {
                        confirmsClear = true
                    } label: {
                        Label("Clear Reproducible Offline Audio", systemImage: "trash")
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.bordered)
                    .disabled(snapshot.clearableBytes == 0)
                    .accessibilityIdentifier("offlineStorage.clear.button")
                }
                .padding(20)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .background(AppColors.bone)
            .accessibilityIdentifier("offlineStorage.screen")
            .navigationTitle("Offline Storage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: model.returnToSettingsFromOfflineStorage) {
                        Label("Settings", systemImage: "arrow.left")
                    }
                }
            }
            .alert("Clear reproducible audio?", isPresented: $confirmsClear) {
                Button("Cancel", role: .cancel) {}
                Button("Clear Audio", role: .destructive, action: model.clearReproducibleOfflineAudio)
            } message: {
                Text("Up to \(bytes(snapshot.clearableBytes)) can be recreated later. Imported audiobooks, recordings, Margins, and other protected work will remain.")
            }
            .task { model.refreshOfflineStoragePresentation() }
        }
    }

    private var snapshot: OfflineStorageSnapshot { model.offlineStorageSnapshot }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

private struct ExperienceAddSourceFlow: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedRoute: AddSourceRoute
    @State private var fileRequest: FileRequest?
    @State private var showsFileImporter = false
    @FocusState private var focusedField: Field?

    private enum Field { case link, title, text }
    private enum FileRequest { case textOrPDF, epub, audiobook, quickFolder }

    init(initialRoute: AddSourceRoute) {
        _selectedRoute = State(initialValue: initialRoute)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let review = model.sourceLinkCandidateReview {
                        candidateReview(review)
                    } else {
                        routePicker
                        routeContent
                    }
                }
                .padding(20)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .background(AppColors.bone)
            .navigationTitle("Add Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
            .fileImporter(
                isPresented: $showsFileImporter,
                allowedContentTypes: allowedContentTypes,
                allowsMultipleSelection: fileRequest == .textOrPDF,
                onCompletion: handleFileImport
            )
            .onChange(of: model.sourceLinkImportState) { _, state in
                if state == "success" { dismiss() }
            }
            .onAppear { model.resetSourceLinkImportState() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("addSource.sheet")
    }

    private var routePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What are you adding?")
                .font(.system(.title2, design: .serif).weight(.semibold))
            ForEach(AddSourceRoute.allCases) { route in
                Button {
                    selectedRoute = route
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: route.systemImage)
                            .frame(width: 44, height: 44)
                            .foregroundStyle(selectedRoute == route ? .white : AppColors.evergreen)
                            .background(selectedRoute == route ? AppColors.evergreen : AppColors.softGreen)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(route.title).font(.headline)
                            Text(route.detail)
                                .font(.caption)
                                .foregroundStyle(AppColors.secondaryText)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer()
                        if selectedRoute == route { Image(systemName: "checkmark") }
                    }
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("addSource.route.\(route.rawValue)")
            }
        }
    }

    @ViewBuilder
    private var routeContent: some View {
        Divider().padding(.vertical, 4)
        switch selectedRoute {
        case .linkOrPodcast: linkSource
        case .pastedText: pastedTextSource
        case .documentOrBook: documentSource
        case .audiobook: audiobookSource
        case .quickFolder: quickFolderSource
        }
    }

    private var linkSource: some View {
        ExperienceCard(tint: AppColors.evergreen) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Link or Podcast").font(.headline)
                TextField("Podcast, RSS, audio, or web URL", text: $model.sourceLinkURL)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .focused($focusedField, equals: .link)
                    .accessibilityIdentifier("sourceLink.url.field")
                HStack {
                    Button {
                        model.pasteSourceLinkFromClipboard()
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Button {
                        focusedField = nil
                        _ = model.beginSourceLinkImportFromForm(startSession: false)
                    } label: {
                        if model.isResolvingSourceLink {
                            ProgressView()
                        } else {
                            Label("Add to Library", systemImage: "plus")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppColors.evergreen)
                    .disabled(model.sourceLinkURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isResolvingSourceLink)
                    .accessibilityIdentifier("sourceLink.import.button")
                }
                if let message = model.sourceLinkImportMessage {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(model.sourceLinkImportState == "failure" ? AppColors.coral : AppColors.secondaryText)
                        .accessibilityIdentifier("sourceLink.import.status")
                }
                Text("Adding a source never replaces the item already in Now Playing.")
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
            }
        }
    }

    private var pastedTextSource: some View {
        ExperienceCard(tint: AppColors.ochre) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Title (optional)", text: $model.importTitle)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .title)
                    .accessibilityIdentifier("create.title.field")
                TextEditor(text: $model.importText)
                    .frame(minHeight: 150)
                    .padding(8)
                    .background(AppColors.inputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppColors.border))
                    .focused($focusedField, equals: .text)
                    .accessibilityLabel("Source text")
                    .accessibilityIdentifier("create.text.editor")
                HStack {
                    Button("Paste", systemImage: "doc.on.clipboard", action: model.pasteImportTextFromClipboard)
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Add to Library", systemImage: "plus") {
                        model.importTextItem(startListening: false)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppColors.evergreen)
                    .disabled(model.importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("create.start.button")
                }
            }
        }
    }

    private var documentSource: some View {
        ExperienceCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Documents and books stay local and retain authored structure when the format provides it.")
                    .foregroundStyle(AppColors.secondaryText)
                Button("Choose Text, Markdown, or PDF", systemImage: "doc.badge.plus") {
                    presentFileImporter(.textOrPDF)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.evergreen)
                .frame(minHeight: 44)
                .accessibilityIdentifier("obsidian.import.button")
                Button("Choose DRM-free EPUB", systemImage: "book.closed") {
                    presentFileImporter(.epub)
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .accessibilityIdentifier("epub.import.button")
            }
        }
    }

    private var audiobookSource: some View {
        ExperienceCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Audiobooks are copied into app-owned storage and protected from automatic eviction.")
                    .foregroundStyle(AppColors.secondaryText)
                Button("Choose Audiobook", systemImage: "headphones") {
                    presentFileImporter(.audiobook)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.evergreen)
                .frame(minHeight: 44)
                .accessibilityIdentifier("audiobook.import.button")
            }
        }
    }

    private var quickFolderSource: some View {
        ExperienceCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Quick Folder").font(.headline)
                Text(model.quickAccessFolderName)
                    .foregroundStyle(AppColors.secondaryText)
                Button("Choose Folder", systemImage: "folder.badge.plus") {
                    presentFileImporter(.quickFolder)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.evergreen)
                .accessibilityIdentifier("quickFolder.choose.button")
                if !model.quickAccessRecentFiles.isEmpty {
                    Divider()
                    ForEach(model.quickAccessRecentFiles) { file in
                        Button {
                            model.importQuickAccessFile(file)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "doc.text")
                                VStack(alignment: .leading) {
                                    Text(file.name).font(.headline)
                                    Text(file.modifiedAtDescription)
                                        .font(.caption)
                                        .foregroundStyle(AppColors.secondaryText)
                                }
                                Spacer()
                                Image(systemName: "plus")
                            }
                            .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func candidateReview(_ review: SourceLinkCandidateReviewState) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ExperiencePageHeader(
                eyebrow: "MATCH NEEDS REVIEW",
                title: "Choose the episode",
                subtitle: "Spoken Margins will not guess when more than one public episode is plausible."
            )
            .accessibilityIdentifier("sourceLink.candidateReview.sheet")
            ForEach(Array(review.result.candidates.enumerated()), id: \.offset) { index, candidate in
                Button {
                    model.selectSourceLinkCandidate(candidate)
                } label: {
                    ExperienceCard {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(candidate.title).font(.headline)
                            if let show = candidate.showTitle { Text(show).foregroundStyle(AppColors.secondaryText) }
                            Text("\(Int((candidate.confidence * 100).rounded()))% match")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(AppColors.secondaryText)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sourceLink.candidate.\(index)")
            }
            Button("Cancel", role: .cancel, action: model.cancelSourceLinkCandidateReview)
                .frame(minHeight: 44)
        }
    }

    private var allowedContentTypes: [UTType] {
        switch fileRequest {
        case .textOrPDF, .none:
            [UTType(filenameExtension: "md") ?? .plainText, .plainText, .pdf]
        case .epub:
            [UTType(filenameExtension: "epub") ?? .data]
        case .audiobook:
            [.mp3, .mpeg4Audio, .mpeg4Movie, UTType(filenameExtension: "m4b") ?? .audio]
        case .quickFolder:
            [.folder]
        }
    }

    private func presentFileImporter(_ request: FileRequest) {
        focusedField = nil
        fileRequest = request
        showsFileImporter = true
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        let request = fileRequest
        fileRequest = nil
        switch result {
        case .success(let urls):
            switch request {
            case .textOrPDF:
                model.importObsidianMarkdownFiles(urls: urls)
                dismiss()
            case .epub:
                if let url = urls.first { model.importEPUBFile(url: url, openWhenFinished: false); dismiss() }
            case .audiobook:
                if let url = urls.first { model.importAudiobookFile(url: url, openWhenFinished: false); dismiss() }
            case .quickFolder:
                if let url = urls.first { model.configureQuickAccessFolder(url: url) }
            case .none:
                model.reportImportFailure(ExperienceFileImportError.missingRequest)
            }
        case .failure(let error):
            model.reportImportFailure(error)
        }
    }
}

private enum ExperienceFileImportError: LocalizedError {
    case missingRequest
    var errorDescription: String? { "File import completed without an active request." }
}

struct ExperienceMarginDetailView: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dismiss) private var dismiss
    let row: MarginRow

    var body: some View {
        NavigationStack {
            List {
                Section("My Margin") {
                    Text(row.preview).textSelection(.enabled)
                    LabeledContent("Item", value: row.itemTitle)
                    LabeledContent("Attached to", value: row.targetDescription)
                    if row.needsAttention {
                        Label(row.attentionDescription, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(AppColors.coral)
                    }
                }
                Section("Actions") {
                    Button("Copy with Context", systemImage: "doc.on.doc") {
                        model.copyInterjectionWithContext(row.interjection)
                    }
                    if row.interjection.audioPath != nil {
                        Button(
                            model.playingInterjectionAudioId == row.interjection.id ? "Stop Recording" : "Play Recording",
                            systemImage: model.playingInterjectionAudioId == row.interjection.id ? "stop.fill" : "play.fill"
                        ) {
                            model.toggleInterjectionAudioPlayback(row.interjection)
                        }
                    }
                    if !["transcribed", "complete"].contains(row.interjection.transcriptionStatus) {
                        Button("Retry Transcription", systemImage: "arrow.clockwise") {
                            model.retryInterjectionTranscription(row.interjection)
                        }
                        .disabled(row.interjection.audioPath == nil)
                    }
                    if row.interjection.anchorContextStatus == .unavailable {
                        Button("Retry Context", systemImage: "arrow.clockwise") {
                            model.retryAnchorContext(row.interjection)
                        }
                    }
                    Button("Open in Timeline", systemImage: "list.bullet.rectangle") {
                        dismiss()
                        model.openMarginInTimeline(row)
                    }
                }
            }
            .navigationTitle("Margin")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onDisappear { model.stopInterjectionAudioPlayback() }
        }
    }
}

struct ExperienceTimelineScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @State private var selectedMargin: MarginRow?
    private let isAdjacent: Bool

    init(isAdjacent: Bool = false) {
        self.isAdjacent = isAdjacent
    }

    @ViewBuilder
    var body: some View {
        if isAdjacent {
            timelineColumn
                .padding(20)
                .background(AppColors.bone)
                .sheet(item: $selectedMargin) { row in
                    ExperienceMarginDetailView(row: row)
                        .environmentObject(model)
                }
        } else {
            routedTimeline
        }
    }

    private var routedTimeline: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    timelineColumn
                    .padding(20)
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                }
                .background(AppColors.bone)
                .onAppear { focusRequestedMargin(using: proxy) }
            }
            .accessibilityIdentifier("timeline.screen")
            .navigationTitle("Timeline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: model.openPlayback) {
                        Label("Now Playing", systemImage: "arrow.left")
                    }
                    .accessibilityIdentifier("timeline.nowPlaying.button")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: model.openExport) {
                        Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Export session")
                }
            }
            .sheet(item: $selectedMargin) { row in
                ExperienceMarginDetailView(row: row)
                    .environmentObject(model)
            }
        }
    }

    private var timelineColumn: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            if isAdjacent {
                timelineHeader
                    .accessibilityIdentifier("playback.timeline.adjacent")
            } else {
                timelineHeader
            }
            sourceSection
            marginSection
            reflectionSection
        }
    }

    private var timelineHeader: some View {
        ExperiencePageHeader(
            eyebrow: "SESSION REFLECTION",
            title: "Timeline",
            subtitle: model.selectedItem.title
        )
    }

    private var sourceSection: some View {
        ExperienceTimelineSection(title: "Source") {
            if !model.selectedItem.navigation.isEmpty {
                ExperienceCanonicalNavigationTree(
                    nodes: model.selectedItem.navigation,
                    chapters: model.selectedItem.chapters,
                    action: { model.jumpToChapter($0, fromTimeline: true) }
                )
            } else if !model.selectedItem.chapters.isEmpty {
                ForEach(model.selectedItem.chapters, id: \.id) { chapter in
                    ExperienceTimelineButton(
                        provenance: .source,
                        title: chapter.title,
                        detail: "Starts around \(chapter.percent)%"
                    ) { model.jumpToChapter(chapter, fromTimeline: true) }
                }
            } else if !model.selectedItem.mediaChapters.isEmpty {
                ForEach(model.selectedItem.mediaChapters, id: \.id) { chapter in
                    ExperienceTimelineButton(
                        provenance: .source,
                        title: chapter.title,
                        detail: "Starts at \(formatTime(chapter.startMs))"
                    ) { model.jumpToMediaChapter(chapter, fromTimeline: true) }
                }
            } else {
                Text("This source is mapless. Playback remains available from the beginning.")
                    .foregroundStyle(AppColors.secondaryText)
            }
        }
    }

    private var marginSection: some View {
        ExperienceTimelineSection(title: "My Margins") {
            let rows = currentSessionMargins
            if rows.isEmpty {
                Text("No Margins in this session yet.")
                    .foregroundStyle(AppColors.secondaryText)
            } else {
                ForEach(rows) { row in
                    ExperienceTimelineButton(
                        provenance: .myMargin,
                        title: row.preview,
                        detail: row.needsAttention ? row.attentionDescription : "Anchored at \(row.interjection.roughPercent)%"
                    ) {
                        model.recordTimelineInterjectionViewed(interjectionId: row.interjection.id)
                        selectedMargin = row
                    }
                    .id(row.id)
                    .accessibilityIdentifier("timeline.interjection.\(row.interjection.id)")
                }
            }
        }
    }

    private var reflectionSection: some View {
        ExperienceTimelineSection(title: "Reflection") {
            if model.canSummarizeInterjections {
                Button(model.canRetryLocalSummary ? "Retry Margin Summary" : "Summarize Margins on Device", systemImage: "sparkles", action: model.summarize)
                    .buttonStyle(.borderedProminent)
                    .tint(AppColors.plum)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("timeline.summary.button")
            }
            if model.selectedItem.turns.isEmpty {
                Text("Eligible on-device summaries and pasted responses will appear here. Listening and Margins work without them.")
                    .foregroundStyle(AppColors.secondaryText)
            } else {
                ForEach(model.selectedItem.turns, id: \.id) { turn in
                    ExperienceTimelineButton(
                        provenance: turn.role == "user" ? .userResponse : .assistantResponse,
                        title: turn.role == "user" ? "My response" : "Assistant response",
                        detail: turn.summary ?? turn.text ?? turn.status.replacingOccurrences(of: "_", with: " ").capitalized
                    ) { model.playTurn(turn, fromTimeline: true) }
                    if let chapters = turn.chapters {
                        ForEach(chapters, id: \.id) { chapter in
                            ExperienceTimelineButton(
                                provenance: turn.role == "user" ? .userResponse : .assistantResponse,
                                title: chapter.title,
                                detail: "Chapter in \(turn.role == "user" ? "my response" : "the assistant response") · \(chapter.percent)%"
                            ) {
                                model.jumpToTurnChapter(turn: turn, chapter: chapter, fromTimeline: true)
                            }
                            .padding(.leading, 20)
                            .accessibilityIdentifier("timeline.turnChapter.jump.\(turn.id).\(chapter.id)")
                        }
                    }
                }
            }
            TextEditor(text: $model.pastedAssistantResponse)
                .frame(minHeight: 88)
                .padding(8)
                .background(AppColors.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppColors.border))
                .accessibilityLabel("Paste assistant response")
            Button("Import Pasted Response", systemImage: "plus") {
                model.importPastedAssistantResponse(autoPlay: false)
            }
            .buttonStyle(.bordered)
            .disabled(model.pastedAssistantResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var currentSessionMargins: [MarginRow] {
        let sessionID = model.snapshot.sessionId
        let sessionDate = model.selectedItem.sessions.first(where: { $0.id == sessionID })?.updatedAt
        return model.selectedItem.interjections
            .filter { $0.status == "active" }
            .map { MarginRow(interjection: $0, itemTitle: model.selectedItem.title, sessionDate: sessionDate) }
    }

    private func focusRequestedMargin(using proxy: ScrollViewProxy) {
        guard let id = model.requestedTimelineFocusMarginID else { return }
        DispatchQueue.main.async {
            withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) }
            model.requestedTimelineFocusMarginID = nil
        }
    }

    private func formatTime(_ milliseconds: Int) -> String {
        let seconds = max(0, milliseconds / 1_000)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct ExperienceCanonicalNavigationTree: View {
    let nodes: [CanonicalNavigationNode]
    let chapters: [Chapter]
    let action: (Chapter) -> Void
    var depth = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(nodes) { node in
                VStack(alignment: .leading, spacing: 8) {
                    if let chapter = chapters.first(where: { $0.id == node.id }), node.children.isEmpty {
                        Button {
                            action(chapter)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(AppColors.evergreen)
                                Text(node.title)
                                    .foregroundStyle(AppColors.text)
                                    .multilineTextAlignment(.leading)
                                Spacer()
                                Text("\(chapter.percent)%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(AppColors.secondaryText)
                            }
                            .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("chapter.jump.\(chapter.id)")
                    } else {
                        Label(node.title, systemImage: depth == 0 ? "books.vertical" : "folder")
                            .font(depth == 0 ? .headline : .subheadline.weight(.semibold))
                            .frame(minHeight: 44)
                    }
                    if !node.children.isEmpty {
                        ExperienceCanonicalNavigationTree(
                            nodes: node.children,
                            chapters: chapters,
                            action: action,
                            depth: depth + 1
                        )
                        .padding(.leading, 20)
                    }
                }
            }
        }
    }
}

private struct ExperienceTimelineSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        ExperienceCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.system(.title2, design: .serif).weight(.semibold))
                content
            }
        }
    }
}

private struct ExperienceTimelineButton: View {
    let provenance: TimelineProvenance
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: provenance.systemImage)
                    .foregroundStyle(provenanceColor)
                    .frame(width: 32, height: 32)
                    .background(provenanceColor.opacity(0.14))
                    .clipShape(provenance == .myMargin ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 8)))
                VStack(alignment: .leading, spacing: 4) {
                    Text(provenance.label)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(provenanceColor)
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(AppColors.text)
                        .multilineTextAlignment(.leading)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                        .multilineTextAlignment(.leading)
                        .lineLimit(4)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .foregroundStyle(AppColors.secondaryText)
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(provenance.label). \(title). \(detail)")
    }

    private var provenanceColor: Color {
        switch provenance {
        case .source: AppColors.evergreen
        case .myMargin: AppColors.coral
        case .userResponse: AppColors.ochre
        case .assistantResponse: AppColors.plum
        }
    }
}

private struct ExperiencePageHeader: View {
    let eyebrow: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(eyebrow)
                .font(.caption.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(AppColors.evergreen)
            Text(title)
                .font(.system(.largeTitle, design: .serif).weight(.bold))
                .foregroundStyle(AppColors.text)
            Text(subtitle)
                .font(.body)
                .foregroundStyle(AppColors.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ExperienceCard<Content: View>: View {
    @Environment(\.colorSchemeContrast) private var contrast
    var tint: Color = AppColors.border
    @ViewBuilder let content: Content

    init(tint: Color = AppColors.border, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(AppColors.text)
            .background(AppColors.panel)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(tint, lineWidth: contrast == .increased ? 2 : 1)
            )
    }
}

private struct ExperienceTypeCover: View {
    let row: LibraryItemRow
    let size: CGFloat

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.34, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            .accessibilityHidden(true)
    }

    private var systemImage: String {
        let type = row.mediaType.lowercased()
        if type.contains("podcast") || type.contains("audio") { return "waveform" }
        if type.contains("epub") || type.contains("book") { return "book.closed" }
        if type.contains("pdf") { return "doc.richtext" }
        if row.sourceReferenceType == "url" { return "safari" }
        return "doc.text"
    }

    private var background: Color {
        let seed = stableSeed
        return switch seed {
        case 0: AppColors.softGreen
        case 1: AppColors.ochre.opacity(0.24)
        default: AppColors.plum.opacity(0.18)
        }
    }

    private var foreground: Color {
        let seed = stableSeed
        return switch seed {
        case 0: AppColors.evergreen
        case 1: AppColors.ochre
        default: AppColors.plum
        }
    }

    private var stableSeed: Int {
        row.id.utf8.reduce(0) { partial, byte in
            (partial &* 31 &+ Int(byte)) % 3
        }
    }
}

private struct ExperienceEmptyState: View {
    let systemImage: String
    let title: String
    let detail: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        ExperienceCard {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title)
                    .foregroundStyle(AppColors.evergreen)
                Text(title).font(.headline)
                Text(detail).foregroundStyle(AppColors.secondaryText)
                Button(action: action) {
                    Label(actionTitle, systemImage: "arrow.right")
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.evergreen)
                .frame(minHeight: 44)
            }
        }
    }
}
