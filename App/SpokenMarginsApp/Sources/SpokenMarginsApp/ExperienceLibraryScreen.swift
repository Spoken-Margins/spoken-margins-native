import SwiftUI
import SessionKit
#if canImport(UIKit)
import UIKit
#endif

struct ExperienceLibraryScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Binding var addSourceRoute: AddSourceRoute?
    /// The place in the list, kept by the root view because opening an item destroys this screen (#2395).
    @Binding var scrollMemory: FollowingScrollMemory
    @State private var scrollTracker = ListScrollTracker()
    @State private var restoredScroll = false
    @State private var isAudioPreparationQueuePresented = false
    /// The item whose Continue is waiting on the "hear new Margins first?" question (#474).
    @State private var newMarginsOfferItemId: String?
    @State private var collectionItem: LibraryItemRow?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isEdgeSwipePreview) private var isEdgeSwipePreview
    /// A copied link on offer at the top of the Library (#1379).
    @StateObject private var clipboardLink = ClipboardLinkOfferModel()

    private var continueItem: LibraryItemRow? {
        LibraryPresentation.continueItem(in: model.libraryItems, activeItemId: model.activePlaybackItemId)
    }

    /// One identity per item, the Continue row included, so completing the top row removes that row (#585).
    private var listEntries: [LibraryListEntry<LibraryItemRow>] {
        LibraryListRows.entries(visible: model.visibleLibraryItems, currentId: continueItem?.id)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            List {
                if clipboardLink.showsCard {
                    ClipboardLinkOfferCard(clipboard: clipboardLink)
                        .experienceListBlock(horizontalSizeClass: horizontalSizeClass, verticalPadding: 4)
                }

                LiveSessionLiveRows() // a running or quick live session, on top (#2487 slice 1a)
                    .experienceListBlock(horizontalSizeClass: horizontalSizeClass, verticalPadding: 4)

                controls
                    .experienceListBlock(horizontalSizeClass: horizontalSizeClass, verticalPadding: 4)

                if model.sourceLinksWaitingForNetwork > 0 {
                    PendingLinksWaitingLine(count: model.sourceLinksWaitingForNetwork)
                        .experienceListBlock(horizontalSizeClass: horizontalSizeClass, verticalPadding: 4)
                }

                items

                if !model.audioPreparationQueue.isEmpty || !model.recentlyPreparedAudio.isEmpty {
                    preparationSummary
                        .experienceListBlock(horizontalSizeClass: horizontalSizeClass, verticalPadding: 6)
                }

                if model.shouldShowOnboardingCard, screenState.allowsAddingContent {
                    onboardingStrip
                        .experienceListBlock(horizontalSizeClass: horizontalSizeClass)
                }
            }
            .onChange(of: listEntries.map(\.id), initial: true) { _, ids in
                scrollTracker.order = ids
                restoreScroll(in: ids, using: proxy)
            }
            .onAppear { if restoredScroll { scrollTracker.thaw() } }
            .onDisappear { rememberScroll() }
            .background(AppColors.bone)
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .motionAnimation(.smooth(duration: 0.24), value: listEntries.map(\.id))
            .accessibilityIdentifier("home.screen")
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .miniPlayerKeepOut()
            }
        }
        .accessibilityIdentifier("library.screen")
        .sheet(isPresented: $isAudioPreparationQueuePresented) {
            ExperienceAudioPreparationQueueScreen()
                .environmentObject(model)
        }
        .sheet(item: $collectionItem) { item in
            ItemCollectionSheet(item: item)
                .environmentObject(model)
        }
        .newMarginsOffer(itemId: $newMarginsOfferItemId)
        .task { if !isEdgeSwipePreview { await clipboardLink.refresh() } } // the swipe's preview reads nothing (#106)
        .onCompatibleChange(of: scenePhase) { phase in
            if phase == .active { Task { await clipboardLink.refresh() } }
        }
        #if canImport(UIKit)
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            Task { await clipboardLink.refresh() }
        }
        #endif
        // The Add sheet has its own Paste & go, so opening it settles this copy.
        .onCompatibleChange(of: addSourceRoute) { route in
            if route != nil { clipboardLink.markHandled() }
        }
        .onCompatibleChange(of: model.sourceLinkImportState) { state in
            if clipboardLink.isAdding, state == "success" || state == "review" { clipboardLink.markHandled() }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Button("Help", systemImage: "questionmark.circle", action: model.openHelp)
                Divider()
                Button("Preparing Audio", systemImage: "waveform.badge.magnifyingglass") {
                    isAudioPreparationQueuePresented = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Library options")
            .accessibilityIdentifier("home.settings.button")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                addSourceRoute = .linkOrPodcast
            } label: {
                Label("Add", systemImage: "plus")
            }
            .disabled(!screenState.allowsAddingContent)
            .accessibilityIdentifier("home.addSource.button")
        }
    }

    private var preparationSummary: some View {
        Button {
            isAudioPreparationQueuePresented = true
        } label: {
            ExperienceSurface(tint: AppColors.ochre.opacity(0.65)) {
                HStack(spacing: 12) {
                    Image(systemName: model.audioPreparationQueue.isEmpty ? "checkmark.circle.fill" : "waveform.badge.magnifyingglass")
                        .font(.title3)
                        .foregroundStyle(AppColors.ochre)
                        .frame(width: 40, height: 40)
                        .background(AppColors.ochre.opacity(0.12), in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Preparing audio")
                            .font(.headline)
                        Text(preparationSummaryDetail)
                            .font(.subheadline)
                            .foregroundStyle(AppColors.secondaryText)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .foregroundStyle(AppColors.secondaryText)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library.offlineRendering.button")
    }

    private var preparationSummaryDetail: String {
        let queued = Set(model.audioPreparationQueue.map(\.itemId)).count // items, not jobs (#883)
        let recent = model.recentlyPreparedAudio.count
        if queued > 0, recent > 0 {
            return "\(queued) queued · \(recent) recently ready"
        }
        if queued > 0 { return "\(queued) item\(queued == 1 ? "" : "s") queued" }
        return "\(recent) item\(recent == 1 ? "" : "s") recently ready"
    }

    private var onboardingIcon: some View {
        Image(systemName: "sparkles")
            .foregroundStyle(AppColors.ochre)
            .frame(width: 36, height: 36)
            .background(AppColors.ochre.opacity(0.12), in: Circle())
            .accessibilityHidden(true)
    }

    private var onboardingContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Start with a two-minute tour")
                .font(.headline)
            Text("Hear the core loop, then practice making a Margin.")
                .font(.subheadline)
                .foregroundStyle(AppColors.secondaryText)
            // The two buttons stack when they don't fit side by side in the narrowed column (#1937).
            ViewThatFits(in: .horizontal) {
                HStack { onboardingActions }
                VStack(alignment: .leading) { onboardingActions }
            }
        }
    }

    @ViewBuilder private var onboardingActions: some View {
        // A label wider than the column wraps to a second line rather than being cut off (#2056).
        Button { model.startItem(id: Gate1AppModel.welcomeSampleItemId) } label: {
            Text("Hear overview").multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(PrimaryButtonStyle())
        Button { model.startGuidedOnboarding() } label: {
            Text("Practice").multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.bordered)
    }

    private var onboardingDismiss: some View {
        Button(action: model.dismissOnboardingCard) {
            Image(systemName: "xmark")
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss getting started")
    }

    private var onboardingStrip: some View {
        ExperienceSurface(tint: AppColors.ochre.opacity(0.7)) {
            if dynamicTypeSize.isAccessibilitySize {
                // The icon and the dismiss button share a line so the text gets the whole width (#1937).
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        onboardingIcon
                        Spacer(minLength: 0)
                        onboardingDismiss
                    }
                    onboardingContent
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    onboardingIcon
                    onboardingContent
                    Spacer(minLength: 0)
                    onboardingDismiss
                }
            }
        }
        .accessibilityIdentifier("library.onboarding.starters")
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AppColors.secondaryText)
                    .accessibilityHidden(true)
                TextField("Search title, source, or author", text: $model.libraryQuery.query)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .accessibilityIdentifier("library.search.field")
                if !model.libraryQuery.query.isEmpty {
                    Button {
                        model.libraryQuery.query = ""
                    } label: {
                        TapTargetIcon(systemName: "xmark.circle.fill")
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .background(AppColors.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(AppColors.border) }

            HStack(spacing: 8) {
                libraryFiltersMenu
                sortMenu
            }

            HStack(alignment: .top) {
                Text(model.libraryFilterDescription)
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
                    .accessibilityIdentifier("library.filter.summary")
                Spacer()
                if hasActiveFilters {
                    Button("Reset filters", action: model.resetLibraryFilters)
                        .font(.caption)
                        .expandedHitArea(horizontal: 8, vertical: 14)
                        .accessibilityIdentifier("library.filters.reset")
                }
            }
            if model.libraryHidesCompleted {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Text("Completed items hidden")
                        completedVisibilityButton
                    }
                    VStack(alignment: .leading) {
                        Text("Completed items hidden")
                        completedVisibilityButton
                    }
                }
                .font(.subheadline)
                .foregroundStyle(AppColors.evergreen)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("library.completed.visibility")
            }
        }
        .onChange(of: model.libraryQuery) { _, _ in model.libraryQueryChanged() }
    }

    /// The text alone is about 20 pt tall, and a text-only button's hit area is only its text, so its hit area grows to
    /// 44 pt without moving the row's layout (#2899).
    private var completedVisibilityButton: some View {
        Button {
            if model.libraryQuery.query.isEmpty { model.showCompletedLibraryItems() }
            else { model.libraryQuery.listeningState = .all }
        } label: {
            Text(model.libraryQuery.query.isEmpty ? "Show completed" : "Include in search")
                .expandedHitArea(horizontal: 8, vertical: 12)
        }
    }

    private var libraryFiltersMenu: some View {
        Menu {
            Section("Content type") {
                Picker("Content type", selection: $model.libraryQuery.contentType) {
                    ForEach(LibraryContentTypeFilter.allCases, id: \.self) { option in
                        Text(displayName(option.rawValue)).tag(option)
                    }
                }
            }
            Section("Listening") {
                Picker("Listening", selection: $model.libraryQuery.listeningState) {
                    ForEach(LibraryListeningStateFilter.allCases, id: \.self) { option in
                        Text(displayName(option.rawValue)).tag(option)
                    }
                }
            }
            Section("Offline") {
                Picker("Offline", selection: $model.libraryQuery.offlineState) {
                    ForEach(LibraryOfflineStateFilter.allCases, id: \.self) { option in
                        Text(displayName(option.rawValue)).tag(option)
                    }
                }
            }
            Section("Shared Margins") {
                Picker("Shared Margins", selection: $model.libraryQuery.sharedMargins) {
                    ForEach(LibrarySharedMarginsFilter.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
            }
        } label: {
            if dynamicTypeSize.isAccessibilitySize {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.title2)
                    .frame(minWidth: 52, minHeight: 52)
                    .foregroundStyle(AppColors.evergreen)
            } else {
                ExperienceFilterChip(isActive: hasActiveFilters) {
                    Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .accessibilityLabel(hasActiveFilters ? "Filter Library, active filters" : "Filter Library")
        .accessibilityIdentifier("library.filter.menu")
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $model.libraryQuery.sort) {
                ForEach(LibrarySort.allCases, id: \.self) { option in
                    Text(displayName(option.rawValue)).tag(option)
                }
            }
        } label: {
            if dynamicTypeSize.isAccessibilitySize {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.title2)
                    .frame(minWidth: 52, minHeight: 52)
                    .foregroundStyle(AppColors.evergreen)
            } else {
                ExperienceFilterChip(isActive: model.libraryQuery.sort != .recentlyAdded) {
                    Label(displayName(model.libraryQuery.sort.rawValue), systemImage: "arrow.up.arrow.down")
                }
            }
        }
        .accessibilityLabel("Sort Library")
        .accessibilityValue(displayName(model.libraryQuery.sort.rawValue))
        .accessibilityIdentifier("library.sort.menu")
    }

    private var hasActiveFilters: Bool {
        model.libraryQuery.contentType != .all
            || model.libraryQuery.listeningState != .unfinished
            || model.libraryQuery.offlineState != .all
            || model.libraryQuery.sharedMargins != .all
    }

    /// A build that can't open the Library shows that, never the empty state (#1969).
    private var screenState: LibraryScreenState {
        LibraryScreenState.resolve(
            accessError: model.libraryAccessError,
            itemCount: model.libraryItems.count,
            isCaughtUp: model.libraryIsCaughtUp,
            visibleCount: model.visibleLibraryItems.count
        )
    }

    @ViewBuilder
    private var items: some View {
        switch screenState {
        case .cannotOpen(let note):
            LibraryCannotOpenNote(note: note) { model.retryLibraryOpen() }
                .experienceListBlock(horizontalSizeClass: horizontalSizeClass)
        case .empty:
            SMExperienceEmptyState(
                systemImage: "books.vertical",
                title: "Your Library is ready",
                detail: "Add a link, text, document, book, or audiobook to begin.",
                actionTitle: "Add Source"
            ) { addSourceRoute = .linkOrPodcast }
            .experienceListBlock(horizontalSizeClass: horizontalSizeClass)
        case .caughtUp:
            SMExperienceEmptyState(
                systemImage: "checkmark.circle",
                title: "You’re caught up",
                detail: "Your completed items and Margins are still here.",
                actionTitle: "Show completed"
            ) { model.showCompletedLibraryItems() }
            .experienceListBlock(horizontalSizeClass: horizontalSizeClass)
        case .noMatches:
            SMExperienceEmptyState(
                systemImage: "magnifyingglass",
                title: "No matches",
                detail: "Change the search or clear the active filters.",
                actionTitle: "Reset search and filters"
            ) {
                model.libraryQuery = LibraryQuery()
                model.libraryQueryChanged()
            }
            .experienceListBlock(horizontalSizeClass: horizontalSizeClass)
        case .list:
            ForEach(listEntries) { entry in
                let row = entry.row
                ExperienceLibraryCompactRow(
                    row: row,
                    isCurrentItem: entry.isCurrent,
                    playbackSpeed: model.speechPlaybackRateMultiplier,
                    onOpen: { model.openItem(id: row.id) },
                    onPlay: { model.continueListening(itemId: row.id) { newMarginsOfferItemId = $0 } },
                    onComplete: { model.markItemCompleted(id: row.id) },
                    onMarkUnfinished: { model.markItemUnfinished(id: row.id) },
                    onPrepareOffline: { model.prioritizeOfflinePreparation(id: row.id) },
                    onPlayNext: { model.queuePlayNext(itemId: row.id) },
                    onAddToQueue: { model.queueAppend(itemId: row.id) },
                    onAddToCollection: { collectionItem = row },
                    onDelete: { model.moveItemToTrash(id: row.id) }
                )
                .libraryRowLayout(horizontalSizeClass: horizontalSizeClass)
                .onAppear { scrollTracker.rowChanged(row.id, isVisible: true) }
                .onDisappear { scrollTracker.rowChanged(row.id, isVisible: false) }
            }
        }
    }

    /// Hands the place to the root view, which outlives this screen.
    private func rememberScroll() {
        scrollTracker.freeze()
        guard let top = scrollTracker.topEntryID else { return }
        scrollMemory = FollowingScrollMemory(topEntryId: top, order: listEntries.map(\.id))
    }

    /// Scrolls back to the remembered row once, the first time the list has rows. The tracker stays
    /// frozen until then, so the rows that appear at the top first don't overwrite the place.
    private func restoreScroll(in ids: [String], using proxy: ScrollViewProxy) {
        guard !restoredScroll, !ids.isEmpty else { return }
        restoredScroll = true
        guard let target = scrollMemory.restoreTarget(in: ids) else {
            scrollTracker.thaw()
            return
        }
        Task { @MainActor in
            // After the list's first layout, or the scroll finds nothing to move.
            try? await Task.sleep(for: .milliseconds(150))
            proxy.scrollTo(target, anchor: .top)
            try? await Task.sleep(for: .milliseconds(150))
            scrollTracker.thaw()
        }
    }

    private func displayName(_ rawValue: String) -> String {
        LibraryQueryEngine.displayName(rawValue)
    }
}

private struct ExperienceLibraryCompactRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    // The icon tile scales with the text, up to twice its size, so a large glyph is not cut by a fixed frame (#1937).
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 38
    @ScaledMetric(relativeTo: .body) private var iconHeight: CGFloat = 44

    let row: LibraryItemRow
    var isCurrentItem = false
    /// The listener's speech speed, for a text item's estimated length (#305).
    var playbackSpeed: Double = 1
    let onOpen: () -> Void
    let onPlay: () -> Void
    let onComplete: () -> Void
    let onMarkUnfinished: () -> Void
    let onPrepareOffline: () -> Void
    let onPlayNext: () -> Void
    let onAddToQueue: () -> Void
    let onAddToCollection: () -> Void
    let onDelete: () -> Void

    /// At accessibility sizes the title gets its own full-width line, with the icon and the play button together on a line
    /// below it. Beside them the title was left about half the row and broke letter by letter (#2056). The open button
    /// stays ahead of the play button, so the VoiceOver order is the same at every size.
    @ViewBuilder private var rowLayout: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                openButton
                HStack(spacing: 12) {
                    iconTile
                    Spacer(minLength: 0)
                    playButton
                }
            }
        } else {
            HStack(alignment: .center, spacing: 12) {
                iconTile
                openButton
                playButton
            }
        }
    }

    private var iconTile: some View {
        Image(systemName: mediaSymbol)
            .font(.body.weight(.semibold))
            .foregroundStyle(AppColors.evergreen)
            .frame(width: min(max(iconWidth, 38), 76), height: min(max(iconHeight, 44), 88))
            .background(AppColors.softGreen.opacity(isCurrentItem ? 0.85 : 0.55))
            // The row's own text already says the kind (`LibraryRowDetail`), so the icon is not a third stop per row.
            .accessibilityHidden(true)
    }

    private var openButton: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 3) {
                if isCurrentItem {
                    Label(currentItemLabel, systemImage: "play.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColors.evergreen)
                }
                Text(row.title)
                    .font(.headline)
                    .foregroundStyle(AppColors.text)
                    .multilineTextAlignment(.leading)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                detailLineView
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
                    .multilineTextAlignment(.leading)
                ownMarginsLine
                sharedMarginsLine
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library.row.\(row.id)")
    }

    private var playButton: some View {
        Button(action: onPlay) {
            LibraryRowPlayLabel(isReadyOffline: row.offlineState == .readyOffline, isPreparing: row.startupAudioState == .preparing)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playActionTitle)
        .accessibilityValue(
            row.startupAudioState == .preparing
                ? "Preparing audio, \(startupProgressDescription). Playback can start now."
                : row.startupAudioState == .waiting ? "Waiting to prepare audio. Playback can start now."
                : (row.offlineState == .readyOffline ? "Ready offline" : "Ready to start")
        )
        .accessibilityIdentifier("queue.start.\(row.id)")
    }

    var body: some View {
        rowLayout
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .contentShape(Rectangle())
        .background(AppColors.bone)
        .overlay(alignment: .leading) {
            if isCurrentItem {
                Rectangle()
                    .fill(AppColors.evergreen)
                    .frame(width: 3)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppColors.border.opacity(0.8))
                .frame(height: 1)
        }
        .contextMenu {
            Button("Open", systemImage: "arrow.right", action: onOpen)
            Button(playActionTitle, systemImage: "play", action: onPlay)
            if !row.isCompleted {
                Button("Mark Complete", systemImage: "checkmark.circle", action: onComplete)
            } else if row.canMarkUnfinished {
                Button("Mark Unfinished", systemImage: "arrow.uturn.backward.circle", action: onMarkUnfinished)
            }
            if row.offlineState != .readyOffline {
                Button("Prepare Offline", systemImage: "arrow.down.circle", action: onPrepareOffline)
            }
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward", action: onPlayNext)
                .accessibilityIdentifier("library.playNext.\(row.id)")
            Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward", action: onAddToQueue)
                .accessibilityIdentifier("library.addToQueue.\(row.id)")
            Button("Add to Collection…", systemImage: "folder.badge.plus", action: onAddToCollection)
                .accessibilityIdentifier("library.addToCollection.\(row.id)")
            if row.canDelete {
                Button("Move to Recently Deleted", systemImage: "trash", role: .destructive, action: onDelete)
            }
        }
        // One long swipe completes again (#584): Undo and Mark Unfinished (#273) recover a stray one.
        // Mark Unfinished on a completed row still takes a tap.
        .swipeActions(edge: .leading, allowsFullSwipe: !row.isCompleted) {
            if !row.isCompleted {
                Button(action: onComplete) { Label("Complete", systemImage: "checkmark.circle.fill") }
                    .tint(AppColors.evergreen)
                    .accessibilityIdentifier("library.complete.\(row.id)")
            } else if row.canMarkUnfinished {
                Button(action: onMarkUnfinished) { Label("Unfinished", systemImage: "arrow.uturn.backward.circle.fill") }
                    .tint(AppColors.ochre)
                    .accessibilityIdentifier("library.unfinished.\(row.id)")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if row.canDelete {
                Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
            }
            if row.offlineState != .readyOffline {
                Button(action: onPrepareOffline) { Label("Offline", systemImage: "arrow.down.circle") }
                    .tint(AppColors.ochre)
            }
        }
        .accessibilityAction(named: playActionTitle, onPlay)
        .accessibilityActions {
            if !row.isCompleted {
                Button("Mark Complete", action: onComplete)
            } else if row.canMarkUnfinished {
                Button("Mark Unfinished", action: onMarkUnfinished)
            }
            Button("Play Next", action: onPlayNext)
            Button("Add to Queue", action: onAddToQueue)
        }
        // The same guards as the context menu and swipe actions above (#1917).
        .accessibilityActions {
            if row.offlineState != .readyOffline {
                Button("Prepare Offline", action: onPrepareOffline)
            }
            Button("Add to Collection", action: onAddToCollection)
            if row.canDelete {
                Button("Move to Recently Deleted", action: onDelete)
            }
        }
    }

    private var detail: LibraryRowDetail {
        LibraryRowDetail(byline: sourceByline, kind: mediaLabel, length: lengthLabel, listening: listeningLabel, status: statusDetail)
    }

    /// One line, except at the largest non-accessibility size, where a status such as "Opening audio unavailable ·
    /// Live voice available" may take two instead of being cut off (#1937). Default sizes keep the compact row.
    private var detailLineLimit: Int { dynamicTypeSize >= .xxxLarge ? 2 : 1 }

    /// The length keeps its room on the line; a long byline or status truncates instead (#305).
    @ViewBuilder private var detailLineView: some View {
        let detail = detail
        if dynamicTypeSize.isAccessibilitySize {
            Text(detail.fullLine)
        } else if let length = detail.length {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(length).fixedSize().layoutPriority(1)
                Text(detail.restAfterLength).lineLimit(detailLineLimit)
            }
        } else {
            Text(detail.rest).lineLimit(detailLineLimit)
        }
    }

    /// How many Margins the listener has made here, so a nearly-finished item can be cleared without opening it to look (#2394).
    /// Quiet at zero. The count is words; the icon is only a hint.
    @ViewBuilder private var ownMarginsLine: some View {
        if let line = LibraryRowWording.marginCountLine(row.marginCount) {
            Label(line, systemImage: "bubble.left")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppColors.secondaryText)
                .accessibilityIdentifier("library.margins.\(row.id)")
        }
    }

    /// Where a friend left Margins, and whether any are new (#1792). The words carry it, not the color.
    @ViewBuilder private var sharedMarginsLine: some View {
        if let line = row.sharedMargins.libraryLine {
            HStack(spacing: 6) {
                Image(systemName: "person.2.fill")
                    .accessibilityHidden(true)
                Text(line)
                if row.sharedMargins.new > 0 { NewMarginBadge() }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppColors.evergreen)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.sharedMargins.accessibilityLine ?? line)
            .accessibilityIdentifier("library.sharedMargins.\(row.id)")
        }
    }

    private var sourceByline: String? {
        LibraryRowWording.byline(sourceTitle: row.sourceTitle, author: row.author, title: row.title)
    }

    private var playActionTitle: String {
        if (row.continuationProgressPercent ?? 0) >= 100 { return "Replay \(row.title)" }
        return row.hasContinuationSession ? "Continue \(row.title)" : "Start \(row.title)"
    }

    private var currentItemLabel: String {
        if (row.continuationProgressPercent ?? 0) >= 100 { return "Finished" }
        return row.hasContinuationSession ? (dynamicTypeSize.isAccessibilitySize ? "Resume" : "Continue listening") : "Current item"
    }

    private var mediaSymbol: String { row.mediaSymbol }

    /// "about 25 min" for a text item at the listener's speed (#305); podcasts show none.
    private var lengthLabel: String? {
        ListeningTimeEstimator.libraryTotalText(textCharacterCount: row.textCharacterCount, playbackSpeed: playbackSpeed)
    }

    private var listeningLabel: String? {
        if row.isCompleted {
            "Completed"
        } else if let progress = row.continuationProgressPercent {
            "\(progress)%"
        } else {
            nil
        }
    }

    private var mediaLabel: String {
        LibraryRowWording.kindLabel(
            mediaType: row.mediaType,
            sourceReference: row.sourceReference,
            sourceReferenceType: row.sourceReferenceType,
            usesNewReader: row.usesNewReader
        )
    }

    private var offlineDetailLabel: String? {
        switch row.startupAudioState {
        case .waiting:
            return "Waiting"
        case .preparing:
            return "Preparing audio · \(startupProgressDescription)"
        case .ready where row.offlineState != .readyOffline:
            return "Ready to start"
        case .paused:
            return "Opening audio paused"
        case .failed:
            return "Opening audio unavailable · Live voice available"
        case .notRequired, .ready:
            break
        }
        return switch row.offlineState {
        case .readyOffline: "Offline"
        case .preparing: "Preparing"
        case .needsRepreparation: "Needs update"
        case .onlineOnly, .all: nil
        }
    }

    private var statusDetail: String? {
        offlineDetailLabel
    }

    private var startupProgressDescription: String {
        let target = max(1, row.startupAudioTargetChunkCount)
        return "\(min(row.startupAudioCompletedChunkCount, target)) of \(target)"
    }
}

private extension View {
    func libraryRowLayout(horizontalSizeClass: UserInterfaceSizeClass?) -> some View {
        listRowInsets(EdgeInsets(
            top: 0,
            leading: horizontalSizeClass == .regular ? 28 : 16,
            bottom: 0,
            trailing: horizontalSizeClass == .regular ? 28 : 16
        ))
        .listRowBackground(AppColors.bone)
        .listRowSeparator(.hidden)
    }
}

/// The Library row's play button face: a 40 pt circle inside a 44 pt hit area (#151).
struct LibraryRowPlayLabel: View {
    // The circle grows with its glyph, up to twice its size, and never below the 44 pt hit area (#1937).
    @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = 40
    let isReadyOffline: Bool
    let isPreparing: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: isReadyOffline ? "play.fill" : "play")
                .foregroundStyle(AppColors.evergreen)
                .frame(width: min(max(diameter, 40), 80), height: min(max(diameter, 40), 80))
                .background(AppColors.softGreen, in: Circle())
            if isPreparing {
                ProgressView()
                    .controlSize(.mini)
                    .tint(AppColors.evergreen)
                    .padding(2)
                    .background(AppColors.panel, in: Circle())
            }
        }
        .minimumTapTarget()
    }
}
