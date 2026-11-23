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
    @State private var isPlayQueuePresented = false
    @ObservedObject private var playQueue = PlayQueueState.shared
    /// The thumbnail each row shows in place of its icon, when the item's feed or page gave one (#3864).
    @ObservedObject private var itemArtwork = ItemArtworkModel.shared
    /// The item whose Continue is waiting on the "hear new Margins first?" question (#474).
    @State private var pendingNewMarginsOffer: NewMarginsOfferRequest?
    @State private var collectionItem: LibraryItemRow?
    /// The collection whose screen is pushed (#3769).
    @State private var openedCollection: LibraryCollectionRoute?
    @State private var renamingCollection: ItemCollection?
    @State private var collectionRenameText = ""
    /// The collection waiting on Delete Collection's confirmation.
    @State private var deletingCollection: LibraryCollectionRow?
    /// What a collection row's rename could not do, shown under the controls until the view changes.
    @State private var collectionProblem: String?
    /// Select (#4720): whether the rows show tick circles, and which are ticked.
    @State private var isSelecting = false
    @State private var selection = LibrarySelection()
    /// A spoken note opened from its row: it has its own screen, not the text item screen (#3108).
    @State private var openedNote: SpokenNoteOpening?
    /// Export of a spoken note from its row: its words alone, or its audio and words, through the share sheet (#3660).
    @StateObject private var noteExport = SpokenNoteExportModel()
    /// A spoken note whose name is being changed from its row (#3663).
    @State private var renamingNote: SpokenNoteRenameTarget?
    /// Play on a spoken note's row plays the whole note (#3662).
    @StateObject private var notePlay = SpokenNoteWholePlayModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isEdgeSwipePreview) private var isEdgeSwipePreview
    /// A copied link on offer at the top of the Library (#1379).
    @StateObject private var clipboardLink = ClipboardLinkOfferModel()

    private var continueItem: LibraryItemRow? {
        LibraryPresentation.continueItem(in: model.libraryItems, activeItemId: model.activePlaybackItemId)
    }

    /// The play queue's rows (#1990); empty while nothing is queued, which is when the Library shows no entry.
    private var queuedRows: [PlayQueueRow] {
        PlayQueueRows.rows(for: PlayQueue(itemIds: playQueue.itemIds), items: model.libraryItems)
    }

    /// One identity per row, the Continue row included, so completing the top row removes that row (#585). In the
    /// Collections view a collection is one row standing for its items (#3769).
    private var listEntries: [LibraryCollectionEntry] {
        model.libraryListing(currentItemID: continueItem?.id)
    }

    /// The item rows Select can tick, in the list's order; collection rows are not ticked.
    private var selectableIDs: [String] { LibrarySelection.selectableIDs(listEntries) }

    private var selectedRows: [LibraryItemRow] {
        let ordered = selection.ordered(in: selectableIDs)
        let rows = Dictionary(listEntries.compactMap(\.itemRow).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ordered.compactMap { rows[$0] }
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

                // One row, always in the list, so the queue's entry can come and go without moving the items below it
                // (#1990). A list leaves a row's height alone while the row is off screen and takes the new one when the
                // row comes back into view, with no jump. A new row, by contrast, pushes everything below it down by its
                // height, and a list running that update overrode every offset set to hold its place. The spacing here
                // equals the gap two rows with this block's padding had, so the screen looks the same.
                VStack(alignment: .leading, spacing: 8) {
                    controls

                    if model.sourceLinksWaitingForNetwork > 0 {
                        PendingLinksWaitingLine(count: model.sourceLinksWaitingForNetwork)
                    }

                    if !queuedRows.isEmpty {
                        PlayQueueSummaryRow(rows: queuedRows) { isPlayQueuePresented = true }
                    }

                    // Above the items while audio is queued, so a listener sees it without scrolling past the list
                    // (#3215), and gone once nothing is, however much finished recently (#3764). It sits in this
                    // always-present row, so it comes and goes without a new row shifting the items.
                    if let line = AudioPreparationQueueProjection.libraryStatusLine(queue: model.audioPreparationQueue) {
                        LibraryPreparationLine(line: line) { isAudioPreparationQueuePresented = true }
                    }
                }
                .experienceListBlock(horizontalSizeClass: horizontalSizeClass, verticalPadding: 4)

                items

                if model.shouldShowOnboardingCard, screenState.allowsAddingContent {
                    onboardingStrip
                        .experienceListBlock(horizontalSizeClass: horizontalSizeClass)
                }
            }
            .onChange(of: listEntries.map(\.id), initial: true) { _, ids in
                scrollTracker.order = ids
                restoreScroll(in: ids, using: proxy)
                selection.keepOnly(selectableIDs)
            }
            .onAppear { if restoredScroll { scrollTracker.thaw() } }
            .onDisappear { rememberScroll() }
            .background(AppColors.bone)
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .scrollDismissesKeyboard(.interactively) // the search box's keyboard goes down on a drag (#4636)
            .searchKeyboardDoneBar()
            .motionAnimation(.smooth(duration: 0.24), value: listEntries.map(\.id))
            .accessibilityIdentifier("home.screen")
            .navigationTitle(isSelecting ? selection.title : "Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .librarySelectActions(isSelecting: isSelecting, selectedRows: selectedRows, done: endSelecting)
            .navigationDestination(item: $openedCollection) { route in
                LibraryCollectionScreen(collectionID: route.id)
                    .environmentObject(model)
                    .miniPlayerKeepOut()
            }
            .miniPlayerKeepOut()
            }
        }
        .accessibilityIdentifier("library.screen")
        .trackedSheet(isPresented: $isAudioPreparationQueuePresented) {
            ExperienceAudioPreparationQueueScreen()
                .environmentObject(model)
        }
        .playQueueSheet(isPresented: $isPlayQueuePresented, model: model)
        .onAppear { model.loadPlayQueue() }
        .trackedFullScreenCover(item: $openedNote) { opening in
            SpokenNoteRecordingView(opening: opening).environmentObject(model)
        }
        .spokenNoteExportFlow(noteExport)
        .spokenNoteRenameAlert($renamingNote)
        .spokenNotePlayFlow(notePlay)
        .overlay {
            if noteExport.isPreparing { SpokenNoteExportProgress() }
            if notePlay.isPreparing { SpokenNotePlayProgress() }
        }
        .trackedSheet(item: $collectionItem) { item in
            ItemCollectionSheet(item: item)
                .environmentObject(model)
        }
        // On the screen, not on the collection row: the row lives in a list cell the list may recycle.
        .collectionRenameAlert(collection: $renamingCollection, text: $collectionRenameText, commit: commitCollectionRename)
        .confirmationDialog(
            "Delete “\(deletingCollection?.name ?? "")”?",
            isPresented: Binding(get: { deletingCollection != nil }, set: { if !$0 { deletingCollection = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Collection", role: .destructive) {
                if let id = deletingCollection?.collectionID { Task { _ = await model.deleteCollection(collectionID: id) } }
                deletingCollection = nil
            }
            Button("Cancel", role: .cancel) { deletingCollection = nil }
        } message: {
            Text(ItemCollectionEditing.Wording.deleteKeepsEverything)
        }
        .newMarginsOffer($pendingNewMarginsOffer)
        .task { if !isEdgeSwipePreview { await clipboardLink.refresh() } } // the swipe's preview reads nothing (#106)
        // Pictures of items from followed feeds: recorded off the main thread, and again whenever the Library's items change (#3864).
        .task(id: model.libraryItems.map(\.id)) { if !isEdgeSwipePreview { await itemArtwork.refresh(using: model.followedSourceCoordinator) } }
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
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button(selection.selectAllTitle(visible: selectableIDs)) { selection.toggleAll(selectableIDs) }
                    .disabled(selectableIDs.isEmpty)
                    .accessibilityIdentifier("library.select.all")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Cancel", action: endSelecting)
                    .accessibilityIdentifier("library.select.cancel")
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Select") { isSelecting = true }
                    .disabled(selectableIDs.isEmpty || !screenState.allowsAddingContent)
                    .accessibilityIdentifier("library.select.button")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    addSourceRoute = .linkOrPodcast
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .disabled(!screenState.allowsAddingContent)
                .accessibilityLabel("Add to Library")
                .accessibilityIdentifier("home.addSource.button")
            }
        }
    }

    private func endSelecting() {
        isSelecting = false
        selection.deselectAll()
    }

    private var onboardingIcon: some View {
        Image(systemName: "sparkles")
            .foregroundStyle(AppColors.ochreText)
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
            // A column at accessibility sizes or when the labels don't fit on one line each, never a word split (#1939).
            AdaptiveStack { onboardingActions }
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
            AppSearchField("Search title, source, author, or friend", text: $model.libraryQuery.query, identifier: "library.search.field")

            LibraryChipRowLayout(spacing: 8, forcesColumn: dynamicTypeSize.isAccessibilitySize) {
                libraryFiltersMenu
                sortMenu
            }

            if showsViewPicker {
                viewPicker
            }

            // The everyday view (Unfinished, nothing else set) has nothing between the chips and the first row (#4698). A
            // filter the listener chose says what it is, with the way back; the hidden finished items are counted at the
            // end of the list instead.
            if hasActiveFilters {
                HStack(alignment: .top) {
                    Text(model.libraryFilterDescription)
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                        .accessibilityIdentifier("library.filter.summary")
                    Spacer()
                    Button(action: model.resetLibraryFilters) {
                        Text("Reset filters").expandedHitArea(horizontal: 8, vertical: 14)
                    }
                        .font(.caption)
                        .accessibilityIdentifier("library.filters.reset")
                }
            }
        }
        .onChange(of: model.libraryQuery) { _, _ in model.libraryQueryChanged() }
    }

    // MARK: Collections | All Items (#3769)

    /// Once any collection exists: with none, the two views list the same rows.
    private var showsViewPicker: Bool { !model.libraryCollections.collections.isEmpty }

    private var viewPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("View", selection: Binding(
                get: { model.libraryCollections.viewMode },
                set: { model.libraryCollections.viewMode = $0 }
            )) {
                ForEach(LibraryViewMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .segmentedUnlessLargeText()
            .frame(minHeight: 44)
            .accessibilityIdentifier("library.viewMode")
            if let collectionProblem {
                Text(collectionProblem)
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
                    .accessibilityIdentifier("library.collections.problem")
            }
        }
        .onChange(of: model.libraryCollections.viewMode) { _, _ in collectionProblem = nil }
    }

    private func beginCollectionRename(_ row: LibraryCollectionRow) {
        guard let collection = model.libraryCollections.collections.first(where: { $0.id == row.collectionID }) else { return }
        collectionRenameText = collection.name
        renamingCollection = collection
    }

    private func commitCollectionRename() {
        guard let collection = renamingCollection else { return }
        renamingCollection = nil
        let name = collectionRenameText
        Task { collectionProblem = await model.renameCollection(collectionID: collection.id, to: name) }
    }

    /// The text alone is about 20 pt tall, and a text-only button's hit area is only its text, so its hit area grows to
    /// 44 pt without moving the row's layout (#2899).
    private var completedVisibilityButton: some View {
        Button {
            // The rule is in SessionKit (#5006); the screen's onChange of the query saves the new Listening choice.
            model.libraryQuery = LibraryQueryEngine.queryRevealingFinished(model.libraryQuery)
            // Keyboard down too, so the finished rows aren't left under it: the same resign the Done bar sends
            // (ExperienceDesignSystem.swift:417). The search text and filters stay.
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        } label: {
            Text(LibraryQueryEngine.revealsFinishedWithinSearch(query: model.libraryQuery) ? "Include in search" : "Show")
                .expandedHitArea(horizontal: 8, vertical: 12)
        }
    }

    /// "3 finished hidden · Show": one line after the last row, in place of the lines that sat under the chips (#4698).
    @ViewBuilder private var completedHiddenFooter: some View {
        let hidden = model.libraryHidesCompleted ? model.libraryCompletedHiddenCount : 0
        if hidden > 0 {
            HStack(spacing: 6) {
                Text("\(hidden) finished hidden")
                    .foregroundStyle(AppColors.secondaryText)
                Text("·").foregroundStyle(AppColors.secondaryText).accessibilityHidden(true)
                completedVisibilityButton
                    .foregroundStyle(AppColors.evergreen)
                Spacer(minLength: 0)
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("library.completed.visibility")
            .libraryRowLayout(horizontalSizeClass: horizontalSizeClass)
        }
    }

    // The chip names what narrows the list, from the query alone (#4762); the summary line below the chips keeps its own
    // rule (`hasActiveFilters`), so the everyday Unfinished view stays quiet (#4698).
    private var libraryFiltersMenu: some View {
        let chip = LibraryQueryEngine.libraryFilterChip(query: model.libraryQuery)
        return Menu {
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
            // Words at every text size, so the fill never carries the state alone (#4762).
            ExperienceFilterChip(isActive: chip.isNarrowing, allowsWrapping: true) {
                Label(
                    chip.title,
                    systemImage: chip.isNarrowing ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
                )
            }
        }
        .accessibilityLabel("Filter Library")
        .accessibilityValue(chip.accessibilityValue)
        // A Menu may not pass its label's selected trait through to VoiceOver, so it is repeated here.
        .accessibilityAddTraits(chip.isNarrowing ? .isSelected : [])
        .accessibilityInputLabels(["Filter", chip.title, "Filter Library"])
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
            ExperienceFilterChip(isActive: model.libraryQuery.sort != .recentlyAdded, allowsWrapping: true) {
                Label(displayName(model.libraryQuery.sort.rawValue), systemImage: "arrow.up.arrow.down")
            }
        }
        .accessibilityLabel("Sort Library")
        .accessibilityValue(displayName(model.libraryQuery.sort.rawValue))
        .accessibilityInputLabels(["Sort", displayName(model.libraryQuery.sort.rawValue), "Sort Library"])
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
            itemCount: model.libraryItems.count + model.libraryCollections.collections.count,
            isCaughtUp: model.libraryIsCaughtUp,
            visibleCount: listEntries.count
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
                actionTitle: "Add to Library"
            ) { addSourceRoute = .linkOrPodcast }
            .experienceListBlock(horizontalSizeClass: horizontalSizeClass)
        case .caughtUp:
            SMExperienceEmptyState(
                systemImage: "checkmark.circle",
                title: "You’re caught up",
                detail: "Everything you completed, and your Margins, are still here.",
                actionTitle: "Show completed"
            ) { model.showCompletedLibraryItems() }
            .experienceListBlock(horizontalSizeClass: horizontalSizeClass)
        case .noMatches:
            // Above the empty card, not after it: with the keyboard up the end of this short list sat against the
            // keyboard's top edge and the "Include in search" tap was lost there (#5006). A search that only finished
            // items match says so here, with the way to include them.
            completedHiddenFooter
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
                listRow(entry)
                    .onAppear { scrollTracker.rowChanged(entry.id, isVisible: true) }
                    .onDisappear { scrollTracker.rowChanged(entry.id, isVisible: false) }
            }
            completedHiddenFooter
        }
    }

    @ViewBuilder
    private func listRow(_ entry: LibraryCollectionEntry) -> some View {
        switch entry {
        case .collection(let collection, let isCurrent):
            LibraryCollectionRowView(
                row: collection,
                isCurrent: isCurrent,
                open: { openedCollection = LibraryCollectionRoute(id: collection.collectionID) },
                play: {
                    if let plan = collection.playPlan {
                        model.playCollection(plan, name: collection.name) { pendingNewMarginsOffer = $0 }
                    }
                },
                addToQueue: { model.queueCollection(collection.progress) },
                rename: { beginCollectionRename(collection) },
                exportMargins: { model.exportCollectionMargins(collectionID: collection.collectionID) },
                delete: { deletingCollection = collection }
            )
            .disabled(isSelecting)
            .libraryRowLayout(horizontalSizeClass: horizontalSizeClass)
        case .item(let row, let isCurrent):
            if isSelecting {
                LibrarySelectableRow(
                    isSelected: selection.contains(row.id),
                    label: row.title,
                    toggle: { selection.toggle(row.id) }
                ) { itemRow(row, isCurrent: isCurrent) }
                .libraryRowLayout(horizontalSizeClass: horizontalSizeClass)
            } else {
                itemRow(row, isCurrent: isCurrent)
                    .libraryRowLayout(horizontalSizeClass: horizontalSizeClass)
            }
        }
    }

    private func itemRow(_ row: LibraryItemRow, isCurrent: Bool) -> some View {
                ExperienceLibraryCompactRow(
                    row: row,
                    artworkURL: itemArtwork.url(forItem: row.id),
                    isLoadedItem: isCurrent && model.activePlaybackItemId == row.id,
                    isPlayingNow: isCurrent && model.activePlaybackItemId == row.id && model.activePlaybackIsPlaying,
                    showsFinishedCheck: model.libraryQuery.listeningState != .unfinished,
                    matchedSender: LibraryQueryEngine.matchedSenderLine(row, query: model.libraryQuery),
                    matchedSenderSpoken: LibraryQueryEngine.matchedSenderLine(row, query: model.libraryQuery, spoken: true),
                    playbackSpeed: model.speechPlaybackRateMultiplier,
                    spokenNoteFolders: model.marginOutput.spokenNotes,
                    onOpen: { openRow(row) },
                    onPlay: {
                        // The item sounding now pauses, as the mini player's button does (#4698).
                        if isCurrent && model.activePlaybackItemId == row.id && model.activePlaybackIsPlaying {
                            model.playPauseTapped()
                            return
                        }
                        // A note plays whole, start to finish, like any item; its own screen is where a sentence is picked.
                        if let noteId = row.spokenNoteId { notePlay.play(noteId: noteId, app: model) } else { model.continueListening(itemId: row.id) { pendingNewMarginsOffer = $0 } }
                    },
                    onComplete: { model.markItemCompleted(id: row.id) },
                    onMarkUnfinished: { model.markItemUnfinished(id: row.id) },
                    onMarkMarginsHeard: { model.markItemMarginsHeard(id: row.id) },
                    onPrepareOffline: { model.prioritizeOfflinePreparation(id: row.id) },
                    onPlayNext: { model.queuePlayNext(itemId: row.id) },
                    queueAction: QueueRowAction.action(forItem: row.id, queuedItemIds: playQueue.itemIds),
                    onAddToQueue: { model.toggleQueue(itemId: row.id) },
                    onAddToCollection: { collectionItem = row },
                    onExport: row.spokenNoteId.map { noteId -> () -> Void in
                        { noteExport.export(noteId: noteId, title: row.title, applicationSupport: try? model.applicationSupportDirectory()) }
                    },
                    onRename: row.spokenNoteId.map { _ -> () -> Void in
                        { renamingNote = SpokenNoteRenameTarget(itemId: row.id, currentTitle: row.title) }
                    },
                    onSaveToFolder: row.spokenNoteId.flatMap { noteId -> (() -> Void)? in
                        guard row.isCompleted else { return nil }
                        return { model.saveSpokenNoteToExportFolder(noteId: noteId, title: row.title) }
                    },
                    onDelete: { model.moveItemToTrash(id: row.id) }
                )
    }

    private func openRow(_ row: LibraryItemRow) {
        if let noteId = row.spokenNoteId {
            openedNote = SpokenNoteOpening(noteId: noteId, title: row.title, createdAt: row.addedAt)
        } else {
            model.openItemFromTap(id: row.id)
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

/// A Library row. Internal so the app-hosted height test can lay it out (#4062); the screen is its only caller.
struct ExperienceLibraryCompactRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    // The icon tile scales with the text, up to twice its size, so a large glyph is not cut by a fixed frame (#1937).
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 38
    @ScaledMetric(relativeTo: .body) private var iconHeight: CGFloat = 44
    // The Margins tag, the unread dot and the finished check scale with the tile, by the same factor and to the same
    // cap, so they keep their proportion to the artwork at every text size (#4698).
    @ScaledMetric(relativeTo: .body) private var tagFontSize: CGFloat = 10
    @ScaledMetric(relativeTo: .body) private var badgeSize: CGFloat = 11

    let row: LibraryItemRow
    /// The item's thumbnail, from its own feed entry or its show; nil keeps the icon (#3864).
    var artworkURL: URL?
    /// The item has a session loaded in the player now, not only the one the Continue card offers: only it carries the
    /// "Now playing" value (#4062).
    var isLoadedItem = false
    /// The loaded item is sounding now, so its play button is a pause button inside the ring (#4698).
    var isPlayingNow = false
    /// The list shows finished items on purpose (Everything, Completed), so a finished row carries a check. Under
    /// Unfinished a finished row is listed only for a friend's new Margins, and its unread dot says why (#4698).
    var showsFinishedCheck = false
    /// Why a search listed this row when only who sent its Margins matches: "From Sam and 2 friends" (#4649). Nil when
    /// there is no search or the title, source or author matched. `matchedSenderSpoken` is the same with the whole name.
    var matchedSender: String?
    var matchedSenderSpoken: String?
    /// The listener's speech speed, for a text item's estimated length (#305).
    var playbackSpeed: Double = 1
    /// Which spoken notes were saved to the export folder, for the "Exported" word on a finished note (#3661).
    @ObservedObject var spokenNoteFolders: SpokenNoteFolderLedger
    let onOpen: () -> Void
    let onPlay: () -> Void
    let onComplete: () -> Void
    let onMarkUnfinished: () -> Void
    /// The second mark complete: a finished row with a friend's new Margins (#4289).
    let onMarkMarginsHeard: () -> Void
    let onPrepareOffline: () -> Void
    let onPlayNext: () -> Void
    /// Add to Queue, or Remove from Queue when the item is queued: one name on the swipe, the menu and VoiceOver (#4044).
    /// The state is read from `PlayQueueState` by the screen, never kept on the row.
    var queueAction: QueueRowAction = .add
    /// Does what `queueAction` says: puts the item last in the queue, or takes it out.
    let onAddToQueue: () -> Void
    let onAddToCollection: () -> Void
    /// A spoken note's Export (#3660); nil for every other row.
    var onExport: (() -> Void)?
    /// A spoken note's Rename… (#3663); nil for every other row.
    var onRename: (() -> Void)?
    /// A finished spoken note's "Save to Export Folder" (#3661), the way to try again after the folder was set up.
    var onSaveToFolder: (() -> Void)?
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

    /// The tile, with the Margins tag hanging off its bottom edge, the unread dot on its top corner and, where the list
    /// shows finished items on purpose, a check on the other top corner (#4698). Nothing here adds a line to the row.
    /// The tile stays hidden from VoiceOver; the open button reads the count and who the new ones are from.
    private var iconTile: some View {
        let width = min(max(iconWidth, 38), 76)
        let height = min(max(iconHeight, 44), 88)
        let scale = width / 38
        // The artwork is a square centred in the tile; the symbol tile fills it. The badges sit on the picture's corners.
        let pictureInset = artworkURL == nil ? 0 : (height - width) / 2
        let tagHeight = 15 * scale
        let badge = min(max(badgeSize, 11), 22)
        return iconTileArtwork
            .overlay(alignment: .bottom) {
                if let tag = lines.marginTag {
                    marginTag(tag, height: tagHeight)
                        .offset(y: tagHeight / 2 - pictureInset)
                }
            }
            .overlay(alignment: .topTrailing) {
                if lines.hasNewMargins {
                    Circle()
                        .fill(AppColors.unread)
                        .overlay(Circle().strokeBorder(AppColors.bone, lineWidth: 2 * scale))
                        .frame(width: badge + 4 * scale, height: badge + 4 * scale)
                        .offset(x: 4 * scale, y: pictureInset - 4 * scale)
                        .accessibilityIdentifier("library.newMargins.\(row.id)")
                }
            }
            .overlay(alignment: .topLeading) {
                if showsFinishedCheck && row.isCompleted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: badge + 3 * scale, weight: .semibold))
                        .foregroundStyle(AppColors.bone, AppColors.secondaryText)
                        .background(Circle().fill(AppColors.bone).padding(-1.5 * scale))
                        .offset(x: -4 * scale, y: pictureInset - 4 * scale)
                        .accessibilityIdentifier("library.finished.\(row.id)")
                }
            }
            .accessibilityHidden(true)
    }

    /// A small grey tag: the Margins glyph and the count. It is grey whether or not the Margins were heard; only the
    /// unread dot is coloured. Outlined in the row's background so it never runs into the picture.
    private func marginTag(_ count: String, height: CGFloat) -> some View {
        let size = min(max(tagFontSize, 10), 20)
        return HStack(spacing: size * 0.2) {
            Image(systemName: "quote.bubble.fill")
                .font(.system(size: size * 0.85, weight: .semibold))
            Text(count)
                .font(.system(size: size, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(AppColors.bone)
        .padding(.horizontal, size * 0.4)
        .frame(height: height)
        .background(AppColors.secondaryText, in: RoundedRectangle(cornerRadius: height * 0.34, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: height * 0.34, style: .continuous).strokeBorder(AppColors.bone, lineWidth: size * 0.18))
        .fixedSize()
    }

    @ViewBuilder private var iconTileArtwork: some View {
        let width = min(max(iconWidth, 38), 76)
        let height = min(max(iconHeight, 44), 88)
        if let artworkURL {
            // The item's thumbnail in the icon's place: a square the tile's width, centred in the tile's height, so the
            // row's height rules are unchanged. While it loads, or when it can't, the icon shows in the same square (#3864).
            ArtworkThumbnail(url: artworkURL, fallback: AnyView(symbolTile(width: width, height: width)))
                .frame(width: width, height: width)
                .clipShape(RoundedRectangle(cornerRadius: width * 0.22, style: .continuous))
                .frame(width: width, height: height)
                .accessibilityHidden(true)
        } else {
            symbolTile(width: width, height: height)
        }
    }

    private func symbolTile(width: CGFloat, height: CGFloat) -> some View {
        Image(systemName: mediaSymbol)
            .font(.body.weight(.semibold))
            .foregroundStyle(AppColors.evergreen)
            .frame(width: width, height: height)
            .background(AppColors.softGreen.opacity(0.55))
            // The row's own text already says the kind (`LibraryRowDetail`), so the icon is not a third stop per row.
            .accessibilityHidden(true)
    }

    private var openButton: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(.headline)
                    .foregroundStyle(AppColors.text)
                    .multilineTextAlignment(.leading)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                detailLineView
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
                    .multilineTextAlignment(.leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Title, length, byline and kind, Margins, then whether it is the item playing (#4062).
        .accessibilityLabel(openAccessibilityLabel)
        .accessibilityValue(isLoadedItem ? "Now playing" : "")
        .accessibilityIdentifier("library.row.\(row.id)")
    }

    private var playButton: some View {
        Button(action: onPlay) {
            LibraryRowPlayLabel(
                isReadyOffline: row.offlineState == .readyOffline, isPreparing: row.startupAudioState == .preparing,
                progress: lines.ringFraction, isPlaying: isPlayingNow)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playActionTitle)
        .accessibilityValue(playAccessibilityValue)
        .accessibilityIdentifier("queue.start.\(row.id)")
    }

    var body: some View {
        rowLayout
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .contentShape(Rectangle())
        .background(AppColors.bone)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppColors.border.opacity(0.8))
                .frame(height: 1)
        }
        .contextMenu {
            Button("Open", systemImage: "arrow.right", action: onOpen)
            Button(playActionTitle, systemImage: "play", action: onPlay)
            ForEach(ItemQuickAction.completionActions(for: row), id: \.self) { action in
                switch action {
                case .markComplete: Button("Mark Complete", systemImage: "checkmark.circle", action: onComplete)
                case .markMarginsHeard:
                    Button("Mark Margins Heard", systemImage: "checkmark.bubble", action: onMarkMarginsHeard)
                        .accessibilityIdentifier("library.markMarginsHeard.\(row.id)")
                default: Button("Mark Unfinished", systemImage: "arrow.uturn.backward.circle", action: onMarkUnfinished)
                }
            }
            if row.offlineState != .readyOffline {
                Button("Prepare Offline", systemImage: "arrow.down.circle", action: onPrepareOffline)
            }
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward", action: onPlayNext)
                .accessibilityIdentifier("library.playNext.\(row.id)")
            Button(queueAction.title, systemImage: queueAction.systemImage, action: onAddToQueue)
                .accessibilityIdentifier("library.addToQueue.\(row.id)")
            Button("Add to Collection…", systemImage: "folder.badge.plus", action: onAddToCollection)
                .accessibilityIdentifier("library.addToCollection.\(row.id)")
            if let onExport {
                Button("Export…", systemImage: "doc.text", action: onExport)
                    .accessibilityIdentifier("library.export.\(row.id)")
            }
            if let onRename {
                Button("Rename…", systemImage: "pencil", action: onRename)
                    .accessibilityIdentifier("library.rename.\(row.id)")
            }
            if let onSaveToFolder {
                Button("Save to Export Folder", systemImage: "folder.badge.plus", action: onSaveToFolder)
                    .accessibilityIdentifier("library.saveToFolder.\(row.id)")
            }
            if row.canDelete {
                Button("Move to Recently Deleted", systemImage: "trash", role: .destructive, action: onDelete)
            }
        }
        // One long swipe completes again (#584): Undo and Mark Unfinished (#273) recover a stray one.
        // Mark Unfinished on a completed row still takes a tap.
        .swipeActions(edge: .leading, allowsFullSwipe: !row.isCompleted) {
            if !row.isCompleted {
                Button(action: onComplete) { Label("Complete", systemImage: "checkmark.circle.fill") }
                    .tint(AppColors.swipeEvergreen)
                    .accessibilityIdentifier("library.complete.\(row.id)")
            } else {
                if ItemQuickAction.completionActions(for: row).contains(.markMarginsHeard) {
                    Button(action: onMarkMarginsHeard) { Label("Margins Heard", systemImage: "checkmark.bubble.fill") }
                        .tint(AppColors.swipeEvergreen)
                        .accessibilityIdentifier("library.marginsHeard.\(row.id)")
                }
                if row.canMarkUnfinished {
                    Button(action: onMarkUnfinished) { Label("Unfinished", systemImage: "arrow.uturn.backward.circle.fill") }
                        .tint(AppColors.swipeOchre)
                        .accessibilityIdentifier("library.unfinished.\(row.id)")
                }
            }
            // Second, so a long swipe still takes the first button; on a row with no other button it is the only one and
            // allowsFullSwipe is false (#4044).
            Button(action: onAddToQueue) { Label(queueAction.title, systemImage: queueAction.systemImage) }
                .tint(AppColors.swipeSlate)
                .accessibilityIdentifier("library.queueSwipe.\(row.id)")
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if row.canDelete {
                Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
            }
            if let onExport {
                Button(action: onExport) { Label("Export", systemImage: "doc.text") }
                    .tint(AppColors.swipeEvergreen)
                    .accessibilityIdentifier("library.exportSwipe.\(row.id)")
            }
            if row.offlineState != .readyOffline {
                Button(action: onPrepareOffline) { Label("Offline", systemImage: "arrow.down.circle") }
                    .tint(AppColors.swipeOchre)
            }
        }
        .accessibilityAction(named: playActionTitle, onPlay)
        .accessibilityActions {
            ForEach(ItemQuickAction.completionActions(for: row), id: \.self) { action in
                switch action {
                case .markComplete: Button("Mark Complete", action: onComplete)
                case .markMarginsHeard: Button("Mark Margins Heard", action: onMarkMarginsHeard)
                default: Button("Mark Unfinished", action: onMarkUnfinished)
                }
            }
            Button("Play Next", action: onPlayNext)
            Button(queueAction.title, action: onAddToQueue)
        }
        // The same guards as the context menu and swipe actions above (#1917).
        .accessibilityActions {
            if row.offlineState != .readyOffline {
                Button("Prepare Offline", action: onPrepareOffline)
            }
            Button("Add to Collection", action: onAddToCollection)
            if let onExport {
                Button("Export", action: onExport)
            }
            if let onRename {
                Button("Rename", action: onRename)
            }
            if let onSaveToFolder {
                Button("Save to Export Folder", action: onSaveToFolder)
            }
            if row.canDelete {
                Button("Move to Recently Deleted", action: onDelete)
            }
        }
    }

    /// The words of the row's progress and Margins lines: time left, the ring's fraction, yours and a friend's (#4062).
    /// Worked out from the row alone, which the one Library read already filled, never from the store.
    private var lines: LibraryRowLines {
        LibraryRowLines(row: row, playbackSpeed: playbackSpeed, isExported: isSavedToExportFolder)
    }

    /// The progress words come first ("about 24 min left", "Completed"), then byline, kind and status as before. The
    /// separate percent is gone: the words say how much is left and the ring shows the fraction (#4062).
    private var detail: LibraryRowDetail { detail(matched: matchedSender) }

    private func detail(matched: String?) -> LibraryRowDetail {
        // "· in Daily Brief" on the end while a search or filter lists a collection's items on their own (#3769).
        LibraryRowDetail(byline: sourceByline, kind: mediaLabel, length: lines.progress, listening: nil,
                         status: LibraryCollectionListEngine.detailLine(statusDetail ?? "", collectionNames: row.collectionNames),
                         matched: matched)
    }

    private var openAccessibilityLabel: String {
        let rest = detail(matched: matchedSenderSpoken).rest
        return [row.title, lines.progressSpoken, rest.isEmpty ? nil : rest, lines.marginsSpoken]
            .compactMap { $0 }.joined(separator: ". ")
    }

    private var playAccessibilityValue: String {
        let readiness = row.startupAudioState == .preparing
            ? "Preparing audio, \(startupProgressDescription). Playback can start now."
            : row.startupAudioState == .waiting ? "Waiting to prepare audio. Playback can start now."
            : (row.offlineState == .readyOffline ? "Ready offline" : "Ready to start")
        // A row not started or finished keeps its value as it was; an item in progress says how far along it is.
        guard lines.ringFraction != nil, let spoken = lines.progressSpoken else { return readiness }
        return "\(spoken). \(readiness)"
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

    private var sourceByline: String? {
        LibraryRowWording.byline(sourceTitle: row.sourceTitle, author: row.author, title: row.title)
    }

    private var playActionTitle: String {
        if isPlayingNow { return "Pause \(row.title)" }
        if (row.continuationProgressPercent ?? 0) >= ItemFinishedRule.atEndPercent { return "Replay \(row.title)" }
        return row.hasContinuationSession ? "Continue \(row.title)" : "Start \(row.title)"
    }

    private var mediaSymbol: String { row.mediaSymbol }

    /// A finished spoken note that was saved to the export folder says so, in words (#3661).
    private var isSavedToExportFolder: Bool {
        guard let noteId = row.spokenNoteId else { return false }
        return !spokenNoteFolders.savedFolders(forNoteId: noteId).isEmpty
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
    /// How far the listener is through an item in progress, 0...1; nil draws no ring (#4062). The ring sits inside the
    /// circle's own edge, so the button keeps its size and the 44 pt hit area. The row's words say the same thing.
    var progress: Double?
    /// The item is sounding now: the face is a pause glyph inside the same ring (#4698).
    var isPlaying = false

    private static let ringWidth: CGFloat = 2.5

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: isPlaying ? "pause.fill" : (isReadyOffline ? "play.fill" : "play"))
                .foregroundStyle(AppColors.evergreen)
                .frame(width: min(max(diameter, 40), 80), height: min(max(diameter, 40), 80))
                .background(AppColors.softGreen, in: Circle())
                .overlay { ring }
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

    /// A thin full track in the separator colour and an arc for the fraction listened, from the top, clockwise.
    @ViewBuilder private var ring: some View {
        if let progress {
            ZStack {
                Circle().strokeBorder(AppColors.border, lineWidth: Self.ringWidth)
                Circle()
                    .inset(by: Self.ringWidth / 2)
                    .trim(from: 0, to: min(max(progress, 0), 1))
                    .stroke(AppColors.evergreen, style: StrokeStyle(lineWidth: Self.ringWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .accessibilityHidden(true)
        }
    }
}

/// The Library's Filter and Sort chips: side by side when both fit at their natural width, otherwise stacked, Filter
/// above Sort, each as wide as its words and aligned to the leading edge; always stacked at accessibility sizes (#4762).
/// It is a `Layout`, not `ViewThatFits` or `AdaptiveStack`, so each `Menu` keeps one identity: a pick that changes a
/// label's width (such as `Needs Repreparation`) then never rebuilds the chip under VoiceOver focus as its menu closes.
/// Internal for its test.
struct LibraryChipRowLayout: Layout {
    var spacing: CGFloat
    var forcesColumn: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        if isRow(ideal: ideal, width: proposal.width) {
            let width = ideal.reduce(0) { $0 + $1.width } + gaps(subviews.count)
            return CGSize(width: width, height: ideal.map(\.height).max() ?? 0)
        }
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) }
        var width = sizes.map(\.width).max() ?? 0
        if let limit = proposal.width { width = min(width, limit) }
        return CGSize(width: width, height: sizes.reduce(0) { $0 + $1.height } + gaps(subviews.count))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        if isRow(ideal: ideal, width: bounds.width) {
            var x = bounds.minX
            for (subview, size) in zip(subviews, ideal) {
                subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            return
        }
        // Never `.unspecified` here: a label only wraps when it is offered the column's width.
        let offer = ProposedViewSize(width: bounds.width, height: nil)
        var y = bounds.minY
        for subview in subviews {
            let size = subview.sizeThatFits(offer)
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: offer)
            y += size.height + spacing
        }
    }

    private func isRow(ideal: [CGSize], width: CGFloat?) -> Bool {
        !forcesColumn && ideal.reduce(0) { $0 + $1.width } + gaps(ideal.count) <= (width ?? .infinity)
    }

    private func gaps(_ count: Int) -> CGFloat {
        spacing * CGFloat(max(count - 1, 0))
    }
}
