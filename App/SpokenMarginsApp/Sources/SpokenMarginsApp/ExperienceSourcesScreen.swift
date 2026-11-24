import SessionKit
import SwiftUI

/// Following (#1865): one row per followed show, newest episode first, with "N new", a play button for the
/// newest unplayed episode and a chevron into the show's own screen. Quiet shows sit in a collapsed group
/// at the bottom. The plus opens the Follow sheet (#3205): Paste, Browse and Import from another app.
///
/// It does not watch `Gate1AppModel`: it reads what it shows through a `ScreenInputsFeed`, so a model publish that
/// leaves the list as it was does not rebuild it while the listener scrolls (#4028). The tab bar redraws on every publish
/// and shows it with `.equatable()`: it is equal to its last copy while the model is the same one, so the tab bar's
/// redraw stops here. Without that, a hosted run drew it once per publish all the same (36 runs for 20).
struct ExperienceSourcesScreen: View, Equatable {
    let model: Gate1AppModel
    @StateObject private var feed: ScreenInputsFeed<Inputs>
    @Environment(\.isEdgeSwipePreview) private var isEdgeSwipePreview
    @EnvironmentObject private var catalogDrawer: CatalogDrawerModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// A show row's queue button reads the queue as it is now (#4044).
    @ObservedObject private var playQueue = PlayQueueState.shared
    /// The shows the listener's own AI suggested (#4683): its own object, so a new suggestion redraws the row.
    @ObservedObject private var aiSuggestions: AIFollowSuggestionsModel

    /// Following's follow flow lives on its own sheet so this tab stays a list of shows (#141, #3205).
    @State private var isShowingFollowSheet = false
    /// Browse opens the catalog sheet, which sits on the root view: the Follow sheet closes first.
    @State private var opensCatalogAfterFollowSheet = false
    @State private var isShowingQuickFolder = false
    @State private var path: [String] = []
    @State private var isQuietExpanded = false
    /// The follow lists (#4046). Empty until the first read finishes, so Following then shows All with no chips.
    @ObservedObject private var listsState = FollowListsState.shared
    /// The chip that is selected: a list's id, or nil for All. It lives here, not in `Gate1AppModel`, lasts while the
    /// app runs, and returns to All at launch and when its list is deleted (Default 15 of #4046).
    @State private var selectedListID: String?
    /// The show whose "Lists for <show>" sheet is open.
    @State private var listsSheetShow: FeedSubscription?
    /// The Lists screen is pushed from the toolbar's Lists button, and a list's own screen from a chip's Edit list (PR 3).
    @State private var isShowingLists = false
    @State private var editingList: FollowListEditTarget?
    /// The empty list whose "Add shows to <list>" sheet is open.
    @State private var addingShowsToList: FollowList?
    /// Each followed show's artwork (#773), read from the coordinator's side file.
    @State private var artwork = FollowingArtworkCache()

    /// A friend with Margins on more than one item, whose items are open.
    @State private var openFriend: FollowingFriends.Friend?

    /// The shows are pushed inside this stack, so the list is not destroyed when one opens and keeps its own place
    /// (#2395). It takes no scroll binding from the root: the tab bar redraws on every model publish, and a fresh binding
    /// each time could count as a change and redraw this screen anyway (#4028).
    init(model: Gate1AppModel) {
        self.model = model
        _feed = StateObject(wrappedValue: ScreenInputsFeed(model: model, read: Inputs.init))
        _aiSuggestions = ObservedObject(wrappedValue: model.aiFollowSuggestionsModel)
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        #if DEBUG
        ScreenRedrawProbe.recordEqualityCheck("following")
        #endif
        return lhs.model === rhs.model
    }

    /// Everything the list shows from the model. A publish that changes none of it leaves the screen alone.
    struct Inputs: Equatable {
        var list: FollowingShowList
        var feedRows: [FollowingFeed.Row]
        var showsEmptyState: Bool
        var hasFollowCandidates: Bool
        var isOfflineSnapshot: Bool
        var quickFolderFileCount: Int
        /// The folder's name, location and problem (#3770), so the row redraws when it is renamed, moved or can't be opened.
        var quickFolderName: String?
        var quickFolderPath: String?
        var quickFolderProblem: QuickFolderStatus.Problem?
        var isRefreshingQuickAddFeed: Bool
        var importingEntryIds: Set<String>
        var subscriptionIDs: [String]
        /// What `FollowingByList` needs to tell which rows are in a list.
        var subscriptions: [FeedSubscription]
        var isRefreshingFollowedSources: Bool

        /// The words for the Quick Folder row. It shows no check time, so the clock doesn't matter here.
        var quickFolderStatus: QuickFolderStatus {
            QuickFolderStatus(name: quickFolderName, path: quickFolderPath, problem: quickFolderProblem, newCount: quickFolderFileCount)
        }

        @MainActor init(_ model: Gate1AppModel) {
            let friends = model.followingFriends
            list = model.followingShowListCache
            feedRows = model.followingFeedRows(friends: friends)
            showsEmptyState = model.followingShowsEmptyState(friends: friends)
            hasFollowCandidates = !model.followedSourceCandidates.isEmpty
            isOfflineSnapshot = model.selectedProfileId.contains("offline")
            // New files in the Quick Folder. They used to arrive in Following's stream; the folder is a place to open now.
            quickFolderFileCount = model.quickFolderNewFiles.count
            let folder = model.quickAccess.status()
            quickFolderName = folder.name
            quickFolderPath = folder.path
            quickFolderProblem = folder.problem
            isRefreshingQuickAddFeed = model.isRefreshingQuickAddFeed
            importingEntryIds = model.importingFollowedSourceEntryIds
            subscriptionIDs = model.feedSubscriptions.map(\.id)
            subscriptions = model.feedSubscriptions
            isRefreshingFollowedSources = model.isRefreshingFollowedSources
        }
    }

    var body: some View {
        #if DEBUG
        let _ = ScreenRedrawProbe.record("following")
        #endif
        let inputs = feed.inputs
        // Under a list chip only that list's shows are drawn; under All nothing changes (J13).
        let byList = FollowingByList.screen(
            selected: inputs.showsEmptyState ? nil : selectedListID, lists: listsState.lists, feedRows: inputs.feedRows, shows: inputs.list,
            subscriptions: inputs.subscriptions
        )
        NavigationStack(path: $path) {
            let list = FollowingShowList(rows: inputs.list.rows, quiet: byList.quiet)
            List {
                if !listsState.lists.isEmpty, !inputs.showsEmptyState {
                    listChipRow(lists: listsState.lists)
                }
                // An item's Follow can find several feeds; the choice shows here too, not only on the follow screen.
                if inputs.hasFollowCandidates {
                    VStack(alignment: .leading, spacing: 10) { FollowCandidateChoices() }
                        .experienceListBlock(horizontalSizeClass: horizontalSizeClass)
                }
                if inputs.isOfflineSnapshot {
                    Label("Showing the last local snapshot", systemImage: "wifi.slash")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppColors.secondaryText)
                        .experienceListBlock(horizontalSizeClass: horizontalSizeClass, verticalPadding: 4)
                }
                // Above the Quick Folder, in the same pinned spot, under any list chip and above the empty state (#4683).
                if let suggestionsRow = AIFollowSuggestionsRow.make(pending: aiSuggestions.pending(
                    excluding: Set(inputs.subscriptions.compactMap { FeedURLKey.make($0.source.canonicalURL) }))) {
                    aiSuggestionsRow(suggestionsRow)
                        .experienceListBlock(horizontalSizeClass: horizontalSizeClass, verticalPadding: 4)
                }
                // Listed with new files, and also when the folder can't be opened: a silent broken folder is what #3770 answers.
                let quickFolder = inputs.quickFolderStatus
                if quickFolder.isListedOnFollowing {
                    quickFolderRow(quickFolder)
                        .experienceListBlock(horizontalSizeClass: horizontalSizeClass, verticalPadding: 4)
                }
                if inputs.showsEmptyState {
                    SMExperienceEmptyState(
                        systemImage: "dot.radiowaves.left.and.right",
                        title: "You’re not following anything yet",
                        detail: "Follow a podcast or a writer. Each show is one row here, with how many episodes are new.",
                        actionTitle: "Paste a feed link"
                    ) {
                        // A copied link is followed at once; otherwise the sheet opens ready for a link.
                        if case .follow = model.clipboardFollowDecision {
                            Task {
                                // Several feeds behind one link: the choice is on the sheet.
                                if case .needsChoice = await model.followFromClipboard() { isShowingFollowSheet = true }
                            }
                        } else {
                            isShowingFollowSheet = true
                        }
                    }
                    .experienceListBlock(horizontalSizeClass: horizontalSizeClass)
                }
                if let emptyListText = byList.emptyListText {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(emptyListText)
                            .font(.subheadline)
                            .foregroundStyle(AppColors.secondaryText)
                            .accessibilityIdentifier("sources.list.empty")
                        if let emptyList = listsState.lists.first(where: { $0.id == selectedListID }) {
                            Button("Add shows") { addingShowsToList = emptyList }
                                .accessibilityIdentifier("sources.list.addShows")
                        }
                    }
                    .experienceListBlock(horizontalSizeClass: horizontalSizeClass)
                }
                if let allQuietNote = byList.allQuietNote {
                    Text(allQuietNote)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                        .accessibilityIdentifier("sources.list.allQuiet")
                        .experienceListBlock(horizontalSizeClass: horizontalSizeClass, verticalPadding: 4)
                }
                // Friends who sent Margins and followed shows in one list, newest first (#3291, #3343).
                ForEach(byList.rows) { row in
                    switch row {
                    case .friend(let friend): friendRow(friend)
                    case .show(let show): showRow(show)
                    }
                }
                if !list.quiet.isEmpty {
                    Section {
                        if isQuietExpanded {
                            ForEach(list.quiet) { row in showRow(row) }
                        }
                    } header: {
                        quietHeader(list)
                    }
                }
            }
            .background(AppColors.bone)
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .refreshable { await model.pullToRefreshFollowing() }
            .motionAnimation(.smooth(duration: 0.24), value: byList.rows.map(\.id))
            // A list of only Quiet shows opens its Quiet group, since that is all it has.
            .onChange(of: byList.opensQuietGroup) { _, opens in if opens { isQuietExpanded = true } }
            // Two all-Quiet lists in a row leave that value true, so a new selection opens the group too.
            .onChange(of: selectedListID) { _, _ in if byList.opensQuietGroup { isQuietExpanded = true } }
            // A deleted list can't stay selected.
            .onChange(of: listsState.lists) { _, lists in
                selectedListID = FollowingByList.resolvedSelection(selectedListID, in: lists)
            }
            .task { if !isEdgeSwipePreview { await model.reloadFollowLists() } }
            .accessibilityIdentifier("sources.screen")
            .navigationTitle("Following")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(action: { model.refreshQuickAddFeed(trigger: .refreshButton) }) {
                        Group {
                            if inputs.isRefreshingQuickAddFeed { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                        }
                        .minimumTapTarget()
                    }
                    .disabled(inputs.isRefreshingQuickAddFeed)
                    .accessibilityLabel("Refresh Following")
                    .accessibilityIdentifier("quickAdd.refresh.button")
                    // Hidden while the listener follows nothing, so the empty Following tab is unchanged.
                    if !inputs.showsEmptyState {
                        Button(action: { isShowingLists = true }) {
                            Image(systemName: "list.bullet").minimumTapTarget()
                        }
                        .accessibilityLabel(FollowListWords.listsTitle)
                        .accessibilityIdentifier("sources.lists.button")
                    }
                    Button(action: { isShowingFollowSheet = true }) {
                        Image(systemName: "plus").minimumTapTarget()
                    }
                    .accessibilityLabel("Follow a show")
                    .accessibilityHint("Follow a feed, browse podcasts and writers, or import from another app.")
                    .accessibilityIdentifier("sources.manageFeeds")
                }
            }
            .navigationDestination(for: String.self) { subscriptionID in
                ExperienceShowScreen(
                    subscriptionID: subscriptionID,
                    lookedAtOnOpen: model.followingLooked.lookedAt[subscriptionID],
                    artwork: artwork
                )
                .miniPlayerKeepOut()
            }
            .trackedSheet(isPresented: $isShowingFollowSheet, onDismiss: {
                guard opensCatalogAfterFollowSheet else { return }
                opensCatalogAfterFollowSheet = false
                catalogDrawer.present()
            }) {
                FollowSheet(browse: {
                    opensCatalogAfterFollowSheet = true
                    isShowingFollowSheet = false
                })
                .environmentObject(model)
                .environmentObject(catalogDrawer)
            }
            .trackedSheet(item: $listsSheetShow) { subscription in
                FollowListPickerSheet(subscription: subscription)
                    .environmentObject(model)
            }
            .trackedSheet(item: $addingShowsToList) { list in
                FollowListAddShowsSheet(model: model, subscriptions: feed.inputs.subscriptions, listID: list.id)
            }
            .navigationDestination(isPresented: $isShowingLists) {
                FollowListsScreen(model: model, subscriptions: inputs.subscriptions, artwork: artwork)
                    .miniPlayerKeepOut()
            }
            .navigationDestination(item: $editingList) { target in
                FollowListScreen(model: model, subscriptions: inputs.subscriptions, artwork: artwork, listID: target.id)
                    .miniPlayerKeepOut()
            }
            .navigationDestination(item: $openFriend) { friend in
                FollowingFriendItemsScreen(friend: friend)
                    .miniPlayerKeepOut()
            }
            .navigationDestination(isPresented: $isShowingQuickFolder) {
                QuickFolderFilesScreen(artwork: artwork)
                    .miniPlayerKeepOut()
            }
            .task { if !isEdgeSwipePreview { model.refreshQuickAddFeed(force: false, trigger: .tabAppear) } } // the swipe's preview fetches nothing (#106)
            // The catalog gives followed shows their artwork (#773).
            .task { if !isEdgeSwipePreview { await catalogDrawer.loadSnapshot() } }
            .background { FollowingShowRowsReload(model: model) }
            // Re-read the artwork when the shows, the catalog or a refresh changes it (#773).
            .task(id: ArtworkKey(
                subscriptionIDs: inputs.subscriptionIDs,
                hasCatalog: catalogDrawer.catalog != nil,
                isRefreshing: inputs.isRefreshingFollowedSources
            )) {
                guard let coordinator = model.followedSourceCoordinator else { return }
                artwork = await coordinator.followingArtwork(catalog: catalogDrawer.catalog)
            }
            .miniPlayerKeepOut()
        }
    }

    // MARK: Rows

    private func friendRow(_ friend: FollowingFriends.Friend) -> some View {
        FollowingFriendRowView(friend: friend) {
            if friend.items.count == 1, let item = friend.items.first {
                model.openItemFromTap(id: item.id)
            } else {
                openFriend = friend
            }
        }
        .listRowInsets(EdgeInsets(
            top: 0,
            leading: horizontalSizeClass == .regular ? 28 : 16,
            bottom: 0,
            trailing: horizontalSizeClass == .regular ? 28 : 16
        ))
        .listRowSeparator(.hidden)
        .listRowBackground(AppColors.bone)
    }

    /// What the show row's queue button does for its newest episode: Remove from Queue only when that episode is in the
    /// Library and queued; every other episode would be saved first, so it is Add to Queue (#4044).
    private func showRowQueueAction(_ row: FollowingShowRow) -> QueueRowAction? {
        if row.isNewestInLibrary {
            guard let itemId = row.playItemID else { return nil }
            return QueueRowAction.action(forItem: itemId, queuedItemIds: playQueue.itemIds)
        }
        return row.addEntryID == nil ? nil : .add
    }

    @ViewBuilder
    private func queueSwipeButton(_ row: FollowingShowRow) -> some View {
        if let action = showRowQueueAction(row) {
            Button { model.queueNewestEpisode(of: row) } label: {
                Label(action.title, systemImage: action.systemImage)
            }
            .tint(AppColors.swipeSlate)
            .accessibilityIdentifier("sources.show.\(row.id).queue")
        }
    }

    @ViewBuilder
    private func showRow(_ row: FollowingShowRow) -> some View {
        FollowingShowRowView(
            row: row,
            artworkURL: artwork.artworkURL(for: row.id),
            open: { path.append(row.id) },
            play: { model.playNewestEpisode(of: row) },
            add: { model.addPreviewedEpisode(of: row) },
            isPlayStarting: row.playEntryID.map { feed.inputs.importingEntryIds.contains($0) } ?? false,
            isAdding: row.newestEntryID.map { feed.inputs.importingEntryIds.contains($0) } ?? false,
            queueAction: showRowQueueAction(row),
            queue: { model.queueNewestEpisode(of: row) }
        )
        // Add the episode the row previews without opening the show (#2929), or Add to Queue, which saves it and queues it
        // (#4044). Once it is in the Library the second button is the only one: Add to Queue or Remove from Queue, and no
        // long swipe. A show with no episode offers no swipe.
        .swipeActions(edge: .leading, allowsFullSwipe: row.addEntryID != nil) {
            if row.addEntryID != nil {
                Button { model.addPreviewedEpisode(of: row) } label: {
                    Label("Add", systemImage: "plus.circle.fill")
                }
                .tint(AppColors.swipeEvergreen)
                .accessibilityIdentifier("sources.show.\(row.id).add")
                queueSwipeButton(row)
            } else if row.isNewestInLibrary, row.playItemID != nil {
                queueSwipeButton(row)
            } else if row.isNewestInLibrary {
                Button {} label: {
                    Label("In Library", systemImage: "checkmark.circle")
                }
                .disabled(true)
                .tint(AppColors.swipeSlate)
                .accessibilityIdentifier("sources.show.\(row.id).inLibrary")
            }
        }
        // Long press: the lists this show is in (#4046). The leading swipe actions above stay as they were.
        .contextMenu {
            if let subscription = followedSubscription(for: row) {
                Button { listsSheetShow = subscription } label: { Label("Lists…", systemImage: "list.bullet") }
            }
        }
        // The same action for VoiceOver and Switch Control, which can't long-press (#1917).
        .accessibilityActions {
            if let subscription = followedSubscription(for: row) {
                Button("Lists…") { listsSheetShow = subscription }
            }
        }
        .listRowInsets(EdgeInsets(
            top: 0,
            leading: horizontalSizeClass == .regular ? 28 : 16,
            bottom: 0,
            trailing: horizontalSizeClass == .regular ? 28 : 16
        ))
        .listRowSeparator(.hidden)
        .listRowBackground(AppColors.bone)
    }

    private func followedSubscription(for row: FollowingShowRow) -> FeedSubscription? {
        feed.inputs.subscriptions.first { $0.id == row.id }
    }

    // MARK: List chips (#4046)

    /// **All**, then the lists in alphabetical order, in the catalog drawer's chip style. The selected chip carries a
    /// checkmark, so colour is never the only signal. A long press on a list's chip offers Edit list, which opens the
    /// list's own screen: rename, delete and the rest live there (PR 3).
    private func listChipRow(lists: [FollowList]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button { selectedListID = nil } label: {
                    CatalogSubjectChipLabel(title: "All", isSelected: selectedListID == nil)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedListID == nil ? .isSelected : [])
                .accessibilityIdentifier("sources.list.chip.all")
                ForEach(FollowListName.chipOrder(lists)) { list in
                    let isSelected = selectedListID == list.id
                    Button { selectedListID = list.id } label: {
                        CatalogSubjectChipLabel(title: list.name, isSelected: isSelected)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(list.name)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityIdentifier("sources.list.chip.\(list.id)")
                    .contextMenu {
                        Button("Edit list", systemImage: "pencil") { editingList = FollowListEditTarget(id: list.id) }
                    }
                    .accessibilityActions {
                        Button("Edit list") { editingList = FollowListEditTarget(id: list.id) }
                    }
                }
            }
        }
        .accessibilityIdentifier("sources.list.chips")
        .experienceListBlock(horizontalSizeClass: horizontalSizeClass, verticalPadding: 4)
    }

    /// "Quiet (2)", a button that opens and closes the group. The count and the chevron say what it holds.
    private func quietHeader(_ list: FollowingShowList) -> some View {
        Button {
            isQuietExpanded.toggle()
        } label: {
            HStack {
                Text(list.quietTitle)
                    .font(.headline)
                    .foregroundStyle(AppColors.text)
                Spacer()
                Image(systemName: isQuietExpanded ? "chevron.down" : "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.secondaryText)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .accessibilityIdentifier("sources.quietGroup")
        .accessibilityLabel(list.quietTitle)
        .accessibilityValue(isQuietExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Shows you have set to Quiet.")
        .experienceListBlock(horizontalSizeClass: horizontalSizeClass, verticalPadding: 4)
    }

    /// "Suggested by your AI" (#4683, Design 2h): the Quick Folder row's look, two lines. A tap opens the follow preview
    /// titled for the AI; a swipe's Dismiss drops them all, with Undo.
    private func aiSuggestionsRow(_ row: AIFollowSuggestionsRow) -> some View {
        Button { model.openAIFollowSuggestions(row, in: catalogDrawer) } label: {
            HStack(spacing: 10) {
                Image(systemName: "text.bubble")
                    .foregroundStyle(AppColors.evergreen)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AIFollowSuggestionsRow.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppColors.text)
                    Text(row.detail)
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.secondaryText)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityHint(AIFollowSuggestionsRow.accessibilityHint)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Dismiss") { model.dismissAIFollowSuggestionsWithUndo() }
        .accessibilityIdentifier("sources.aiSuggestions")
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button { model.dismissAIFollowSuggestionsWithUndo() } label: {
                Label("Dismiss", systemImage: "xmark")
            }
            .tint(AppColors.swipePlum)
        }
    }

    /// The folder's name, with "Quick Folder · 3 new" (or "· can't open this folder", with its icon) under it (#3770).
    private func quickFolderRow(_ status: QuickFolderStatus) -> some View {
        Button { isShowingQuickFolder = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .foregroundStyle(AppColors.evergreen)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.followingTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppColors.text)
                    if let symbol = status.followingSymbol {
                        Label(status.followingSubtitle, systemImage: symbol)
                            .font(.caption)
                            .foregroundStyle(AppColors.text)
                    } else {
                        Text(status.followingSubtitle)
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.secondaryText)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.followingAccessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("sources.quickFolder")
    }

    struct ShowRowsKey: Equatable {
        var subscriptions: [String]
        var unplayedCount: Int
        var isRefreshing: Bool
        var libraryCount: Int
        var finishedCount: Int
        var listeningSteps: Int

        @MainActor init(_ model: Gate1AppModel) {
            subscriptions = model.feedSubscriptions.map { "\($0.id):\($0.state.rawValue)" }
            unplayedCount = model.followedSourceEntries.count
            isRefreshing = model.isRefreshingFollowedSources
            // Finishing an episode moves its show's row to the next unread one, so a change in what the Library
            // holds or has finished re-reads the rows.
            libraryCount = model.libraryItems.count
            finishedCount = model.libraryItems.filter(\.isCompleted).count
            // An episode counts as heard before the Library calls it finished (95%, or its last two minutes;
            // `FollowingHeardRule`), so each 1% of listening re-reads the rows too (#3691).
            listeningSteps = model.libraryItems.reduce(0) { $0 + ($1.continuationProgressPercent ?? 0) }
        }
    }

    private struct ArtworkKey: Equatable {
        var subscriptionIDs: [String]
        var hasCatalog: Bool
        var isRefreshing: Bool
    }
}

/// Re-reads the show rows' entries when the shows, the unplayed entries or a refresh change them. Played and Quiet
/// shows' entries aren't in `followedSourceEntries`, so the rows read the store. This empty view holds the key in its own
/// feed, so each 1% of listening wakes it and not the list (#4028); the rows redraw only if the re-read changes them.
private struct FollowingShowRowsReload: View {
    let model: Gate1AppModel
    @StateObject private var key: ScreenInputsFeed<ExperienceSourcesScreen.ShowRowsKey>

    init(model: Gate1AppModel) {
        self.model = model
        _key = StateObject(wrappedValue: ScreenInputsFeed(model: model, read: ExperienceSourcesScreen.ShowRowsKey.init))
    }

    var body: some View {
        Color.clear.task(id: key.inputs) { await model.reloadFollowingShowEntries() }
    }
}

/// One show on Following: artwork, name, the newest episode, "N new", ▶ and ›.
private struct FollowingShowRowView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let row: FollowingShowRow
    let artworkURL: URL?
    let open: () -> Void
    let play: () -> Void
    let add: () -> Void
    let isPlayStarting: Bool
    /// The previewed episode is being fetched into the Library after a swipe (#2929).
    let isAdding: Bool
    /// The row has no menu, so its queue action is a VoiceOver action only (#4044); nil when the show has no episode to queue.
    var queueAction: QueueRowAction?
    var queue: () -> Void = {}

    var body: some View {
        HStack(spacing: 0) {
            Button(action: open) {
                HStack(alignment: .center, spacing: 12) {
                    ShowArtworkView(url: artworkURL, title: row.title, size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.title)
                            .font(.headline)
                            .foregroundStyle(AppColors.text)
                            .multilineTextAlignment(.leading)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        if let episode = row.newestEpisodeTitle {
                            Text(episode)
                                .font(.subheadline)
                                .foregroundStyle(AppColors.secondaryText)
                                .multilineTextAlignment(.leading)
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        }
                        HStack(spacing: 8) {
                            if let label = row.countLabel {
                                Text(label)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(AppColors.onEvergreen)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(AppColors.evergreen, in: Capsule())
                            }
                            if let date = row.dateLabel {
                                Text(date)
                                    .font(.caption)
                                    .foregroundStyle(AppColors.secondaryText)
                            }
                            if isAdding && !isPlayStarting { // ▶ on the same episode shows its own spinner
                                HStack(spacing: 4) {
                                    ProgressView().controlSize(.mini)
                                    Text("Adding…")
                                        .font(.caption)
                                        .foregroundStyle(AppColors.secondaryText)
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityIdentifier("sources.show.\(row.id).adding")
                            } else if row.isNewestInLibrary {
                                Label("In Library", systemImage: "checkmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(AppColors.secondaryText)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.accessibilityLabel)
            .accessibilityHint("Opens the show.")
            .accessibilityAction(named: "Add newest episode to Library") { if row.addEntryID != nil { add() } }
            .accessibilityActions {
                if let queueAction { Button(queueAction.newestEpisodeTitle, action: queue) }
            }
            .accessibilityIdentifier("sources.show.\(row.id)")
            if row.playEntryID != nil {
                Button(action: play) {
                    Group {
                        if isPlayStarting {
                            ProgressView()
                        } else {
                            Image(systemName: "play.circle.fill").font(.title2)
                        }
                    }
                    .foregroundStyle(AppColors.evergreen)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isPlayStarting)
                .accessibilityLabel("Play \(row.newestEpisodeTitle ?? "next episode") from \(row.title)")
                .accessibilityIdentifier("sources.show.\(row.id).play")
            }
            Button(action: open) {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.secondaryText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AppColors.panel)
    }
}

/// A show's artwork, or its first letter on a tinted square.
struct ShowArtworkView: View {
    let url: URL?
    let title: String
    let size: CGFloat

    var body: some View {
        Group {
            if let url {
                ArtworkThumbnail(url: url, fallback: AnyView(initial))
            } else {
                initial
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .accessibilityHidden(true)
    }

    private var initial: some View {
        Text(title.first.map { String($0).uppercased() } ?? "?")
            .font(.title2.weight(.semibold))
            .foregroundStyle(AppColors.evergreen)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppColors.softGreen)
    }
}

/// New files in the Quick Folder, which used to arrive in Following's stream. Each keeps its row actions. Titled with the
/// folder's name, with where it is under it; when the folder can't be opened, the same section and buttons as Settings (#3770).
private struct QuickFolderFilesScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let artwork: FollowingArtworkCache

    var body: some View {
        let files = model.quickFolderNewFiles
        let status = model.quickAccess.status(newCount: files.count)
        List {
            Text(status.followingScreenFirstLine)
                .font(.subheadline)
                .foregroundStyle(AppColors.secondaryText)
                .listRowSeparator(.hidden)
                .listRowBackground(AppColors.bone)
                .accessibilityIdentifier("sources.quickFolder.location")
            if status.cantOpen {
                QuickFolderCantOpenSection(model: model, isChecking: model.quickAccess.isRefreshing)
                    .listRowBackground(AppColors.bone)
            }
            ForEach(files) { candidate in
                SourceInboxRow(candidate: candidate, artwork: artwork)
                    .listRowInsets(EdgeInsets(top: 0, leading: horizontalSizeClass == .regular ? 28 : 16, bottom: 0, trailing: horizontalSizeClass == .regular ? 28 : 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(AppColors.bone)
            }
        }
        .background(AppColors.bone)
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        .navigationTitle(status.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("sources.quickFolder.screen")
    }
}

/// The feeds a link or an item's Follow found, when there is more than one to choose from.
struct FollowCandidateChoices: View {
    @EnvironmentObject private var model: Gate1AppModel
    /// The Follow sheet takes the pick itself, to close and offer Undo; Following's list follows it as before.
    var choose: ((SourceCandidateEvidence) -> Void)? = nil

    var body: some View {
        ForEach(model.followedSourceCandidates) { candidate in
            Button {
                if let choose { choose(candidate) } else { model.followSourceCandidate(candidate) }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.source.title ?? candidate.source.host)
                        .font(.headline)
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

struct SourceInboxRow: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let candidate: QuickAddCandidate
    let artwork: FollowingArtworkCache
    /// The rule word that skipped this episode, on the Show screen's "Skipped by your rules" group (#4046 PR 10b): the row
    /// says so and its menu offers **Hear it anyway**. Nil everywhere else.
    var skippedWord: String? = nil
    /// A pick rule matched it: the star and the word "Pick" sit after the date.
    var isPick = false
    @State private var confirmsUnfollow = false

    /// A Quick Folder link list adds many links, so there is no one item to queue (#4044).
    private var canQueue: Bool {
        if case .localFile(let file) = candidate { !Gate1AppModel.isQuickFolderLinkList(file) } else { true }
    }

    var body: some View {
        // The row is a Button and a More menu side by side, so the menu is not nested inside the Button. A
        // listener who can't swipe precisely or hold for the context menu reaches the same actions from the menu (#1932).
        HStack(spacing: 0) {
            rowButton
            moreMenu
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AppColors.panel)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button(action: addInPlace) {
                Label("Add", systemImage: "plus.circle.fill")
            }
            .tint(AppColors.swipeEvergreen)
            // Second, so a long swipe still adds: Add to Queue saves the item and queues it once it lands (#4044).
            if canQueue {
                Button(action: addToQueue) {
                    Label(QueueRowAction.add.title, systemImage: QueueRowAction.add.systemImage)
                }
                .tint(AppColors.swipeSlate)
                .accessibilityIdentifier("\(identifier).queue")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(action: dismiss) {
                Label(dismissTitle, systemImage: dismissSystemImage)
            }
            .tint(AppColors.swipePlum)
            // Second and not a full swipe: the first button above is the one a long swipe takes.
            if subscription != nil {
                Button { confirmsUnfollow = true } label: {
                    Label("Unfollow", systemImage: "minus.circle")
                }
                .tint(AppColors.swipeSlate)
            }
        }
        .contextMenu { rowActions }
        .confirmationDialog(
            FollowingRowActions.unfollowQuestion(showTitle: subscriptionTitle),
            isPresented: $confirmsUnfollow,
            titleVisibility: .visible
        ) {
            Button("Unfollow", role: .destructive) {
                if let subscription { model.unfollowSource(id: subscription.id) }
            }
        } message: {
            Text(FollowListWords.unfollowMessage(inAList: isInAList))
        }
    }

    /// Unfollowing takes the show out of its lists (#4046), and the confirmation says so.
    private var isInAList: Bool {
        guard let subscription else { return false }
        return !FollowListsState.shared.lists(containing: subscription).isEmpty
    }

    private var rowButton: some View {
        Button(action: addAndOpen) {
            if dynamicTypeSize.isAccessibilitySize {
                // Artwork and the chevron share the top line so the text gets the whole row width (#1936).
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        leadingImage
                        Spacer(minLength: 8)
                        trailingIndicator
                    }
                    textColumn
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    leadingImage
                    textColumn
                    trailingIndicator
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isImporting)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Adds this entry to Library and opens it.")
        .accessibilityAction(named: "Add to Library", addAndOpen)
        .accessibilityAction(named: Text(dismissTitle), dismiss)
        .accessibilityActions {
            if canQueue { Button(QueueRowAction.add.title, action: addToQueue) }
            // A Quick Folder file has no show to play from, mute or unfollow.
            if let subscription {
                Button("Play now", action: playNow)
                Button("Mute this show") { model.toggleMuteSource(id: subscription.id) }
                Button("Unfollow this show") { confirmsUnfollow = true }
            }
        }
    }

    /// Every action the swipes and the long press offer, so the More menu and the context menu stay the same list.
    @ViewBuilder
    private var rowActions: some View {
        // Does what tapping the row does; the rule stays as it is.
        if skippedWord != nil {
            Button(action: addAndOpen) { Label("Hear it anyway", systemImage: "headphones") }
        }
        Button(action: addInPlace) { Label("Add to Library", systemImage: "plus.circle") }
        if canQueue {
            Button(action: addToQueue) { Label(QueueRowAction.add.title, systemImage: QueueRowAction.add.systemImage) }
        }
        if isFeedEntry {
            Button(action: playNow) { Label("Play now", systemImage: "play.fill") }
        }
        Button(action: dismiss) { Label(dismissTitle, systemImage: dismissSystemImage) }
        if let subscription {
            Button { model.toggleMuteSource(id: subscription.id) } label: {
                Label(FollowingRowActions.muteTitle(showTitle: subscriptionTitle), systemImage: "speaker.slash")
            }
            Button(role: .destructive) { confirmsUnfollow = true } label: {
                Label(FollowingRowActions.unfollowTitle(showTitle: subscriptionTitle), systemImage: "minus.circle")
            }
        }
    }

    /// A visible control for the row's actions, at least 44 pt, for a listener who can't swipe or hold precisely.
    private var moreMenu: some View {
        Menu { rowActions } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(AppColors.evergreen)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .disabled(isImporting)
        .accessibilityLabel("More actions")
        .accessibilityHint(title)
        .accessibilityIdentifier("\(identifier).more")
    }

    /// The followed show this entry came from; nil for a Quick Folder file.
    private var subscription: FeedSubscription? {
        guard case .followedSource(let entry) = candidate else { return nil }
        return model.feedSubscriptions.first { $0.id == entry.subscriptionId }
    }

    private var subscriptionTitle: String? {
        subscription.map { $0.source.title ?? $0.source.host }
    }

    private var isFeedEntry: Bool {
        if case .followedSource = candidate { true } else { false }
    }

    private var title: String {
        switch candidate {
        case .localFile(let file): file.name
        case .followedSource(let entry): entry.title
        }
    }

    private var provenanceLead: String {
        switch candidate {
        case .localFile(let file): model.quickAccess.status().fileCaption(dateText: file.modifiedAtDescription)
        case .followedSource(let entry): showTitle(of: entry) ?? "Followed feed"
        }
    }

    /// "12 min · Oct 12" after the show name, when there is a length or a date.
    private var provenanceTrail: String? { row?.trailingMetadata }

    private var provenance: String {
        provenanceTrail.map { "\(provenanceLead) · \($0)" } ?? provenanceLead
    }

    private func showTitle(of entry: FeedEntry) -> String? {
        let source = model.feedSubscriptions.first(where: { $0.id == entry.subscriptionId })?.source
        return source?.title ?? source?.host ?? entry.author
    }

    /// Artwork, length and the VoiceOver line for a followed entry (#773); nil for a Quick Folder file.
    private var row: FollowingEntryRow? {
        guard case .followedSource(let entry) = candidate else { return nil }
        return FollowingEntryRow(
            entry: entry,
            showTitle: showTitle(of: entry),
            artworkURL: artwork.artworkURL(for: entry.subscriptionId),
            rate: model.speechPlaybackRateMultiplier
        )
    }

    private var accessibilityLabel: String {
        let base = row?.accessibilityLabel ?? "\(title). \(provenance)"
        let extras = [isPick ? "Pick." : nil, skippedWord.map { ListeningRuleScreens.skippedLine(word: $0) + "." }].compactMap { $0 }
        return ([base] + extras).joined(separator: " ")
    }

    /// The row's text. At accessibility sizes the title and the show name wrap fully; the row grows with them (#1936).
    private var textColumn: some View {
        // At default sizes the row is about the artwork's height (#884): two title lines and one line of show and
        // length. A long title or show name truncates; it does not make the row taller.
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
                .foregroundStyle(AppColors.text)
                .multilineTextAlignment(.leading)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            // The show name gives way first: the length and date keep their space (#1443). At the
            // accessibility sizes there is no room for both on one line, so the length and date
            // take a line of their own under the show instead of being cut off.
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                : AnyLayout(HStackLayout(spacing: 0))
            layout {
                Text(provenanceLead)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .truncationMode(.tail)
                if let trail = provenanceTrail {
                    Text(dynamicTypeSize.isAccessibilitySize ? trail : " · \(trail)")
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                // A symbol and the word, never colour alone (#4046 PR 10b).
                if isPick {
                    Label("Pick", systemImage: "star.fill")
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                        .layoutPriority(1)
                        .padding(.leading, dynamicTypeSize.isAccessibilitySize ? 0 : 6)
                        .accessibilityIdentifier("\(identifier).pick")
                }
            }
            .font(.caption)
            .foregroundStyle(AppColors.secondaryText)
            if let skippedWord {
                Text(ListeningRuleScreens.skippedLine(word: skippedWord))
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .accessibilityIdentifier("\(identifier).skipped")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var trailingIndicator: some View {
        if isImporting {
            ProgressView()
                .frame(width: 44, height: 44)
        } else {
            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppColors.secondaryText)
                .frame(width: 44, height: 44)
        }
    }

    @ViewBuilder
    private var leadingImage: some View {
        if let row {
            Group {
                if let url = row.artworkURL {
                    ArtworkThumbnail(url: url, fallback: AnyView(placeholder(row.placeholder)))
                } else {
                    placeholder(row.placeholder)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .accessibilityHidden(true)
        } else {
            Image(systemName: "folder")
                .font(.title3)
                .foregroundStyle(AppColors.evergreen)
                .frame(width: 56, height: 56)
                .background(AppColors.softGreen, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
    }

    @ViewBuilder
    private func placeholder(_ placeholder: FollowingEntryRow.Placeholder) -> some View {
        switch placeholder {
        case .page:
            Image(systemName: "doc.text")
                .font(.title3)
                .foregroundStyle(AppColors.evergreen)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppColors.softGreen)
                .accessibilityHidden(true)
        case .initial(let letter):
            Text(letter)
                .font(.title2.weight(.semibold))
                .foregroundStyle(AppColors.evergreen)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppColors.softGreen)
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

    private func addAndOpen() {
        switch candidate {
        case .localFile(let file): model.importQuickAccessFile(file, openWhenFinished: true)
        case .followedSource(let entry): model.importFollowedSourceEntry(entry, openWhenFinished: true)
        }
    }

    /// Adds the entry and starts it, landing on the playback screen (#478).
    private func playNow() {
        guard case .followedSource(let entry) = candidate else { return }
        model.importFollowedSourceEntry(entry, playWhenFinished: true)
    }

    private func addInPlace() {
        switch candidate {
        case .localFile(let file): model.importQuickAccessFile(file)
        case .followedSource(let entry): model.importFollowedSourceEntry(entry)
        }
    }

    /// Saves the item and queues it once the import lands (#4044).
    private func addToQueue() {
        switch candidate {
        case .localFile(let file): model.addQuickFolderFileToQueue(file)
        case .followedSource(let entry): model.addEntryToQueue(entry)
        }
    }

    /// "Not for me" on a followed show's episode, "Dismiss" on a Quick Folder file (#4285).
    private var dismissTitle: String { FollowingDismissMessages.actionTitle(isFollowedEntry: isFeedEntry) }
    private var dismissSystemImage: String { FollowingDismissMessages.actionSystemImage(isFollowedEntry: isFeedEntry) }

    private func dismiss() {
        switch candidate {
        case .localFile(let file): model.dismissQuickAccessFileWithUndo(file)
        case .followedSource(let entry): model.dismissFollowedSourceEntry(entry)
        }
    }
}

/// Follows the entry at the top of Following's or the Library's list as rows scroll by (#479, #2395). It is a class that no
/// view observes, so a row coming and going costs a set update, not a redraw.
///
/// A change settles for a moment before it counts. The rows also disappear all at once when the
/// screen goes away (opening an entry, another tab, the feed manager), and those disappearances
/// must not slide the saved place down the list: `freeze` runs when the list disappears and drops
/// what hasn't settled. It starts frozen, until the saved place has been restored.
@MainActor
final class ListScrollTracker {
    var order: [String] = []
    private(set) var topEntryID: String?
    private var visible = Set<String>()
    private var isFrozen = true
    private var settling: Task<Void, Never>?

    func rowChanged(_ id: String, isVisible: Bool) {
        if isVisible { visible.insert(id) } else { visible.remove(id) }
        settling?.cancel()
        settling = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, !isFrozen,
                  let top = FollowingScrollMemory.topEntry(visible: visible, order: order) else { return }
            topEntryID = top
        }
    }

    func freeze() {
        isFrozen = true
        settling?.cancel()
    }

    func thaw() { isFrozen = false }
}

/// Not used while the Top order is off (#1440). Pin, "Less of this show" and the I4 signals behind Following's Top order (#484). The log is
/// read off the main thread; the preferences file is a few hundred bytes, read once when
/// Following first appears and written on each change.
@MainActor
final class FollowingRankingModel: ObservableObject {
    @Published private(set) var preferences = FollowingRankingModel.preferencesURL.map(FollowingPreferences.load(from:)) ?? FollowingPreferences()
    @Published private(set) var signals: [String: FollowingSourceSignals] = [:]

    /// The I4 log's directory: `ListeningSignalRecorder.defaultFileURL` (#483, PR #567) puts it
    /// in Application Support/SpokenMargins/ListeningSignals. Pin and Less sit next to it.
    nonisolated static var directory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "SpokenMargins/ListeningSignals", directoryHint: .isDirectory)
    }

    nonisolated static var preferencesURL: URL? {
        directory?.appending(path: FollowingPreferences.fileName, directoryHint: .notDirectory)
    }

    /// The I4 engagement log. Until #483's recorder writes it, there is no file, and Top is
    /// newest-first plus Pin and Less.
    nonisolated static var signalLogURL: URL? {
        directory?.appending(path: "i4-engagement.jsonl", directoryHint: .notDirectory)
    }

    /// Each time Following appears, since the log keeps growing.
    func load() async {
        signals = await Task.detached(priority: .utility) {
            Self.signalLogURL.map(FollowingSignalLog.signals(contentsOf:)) ?? [:]
        }.value
    }

    func setMark(_ mark: FollowingPreferences.Mark?, for sourceID: String) {
        preferences.setMark(mark, for: sourceID)
        guard let url = Self.preferencesURL else { return }
        try? preferences.save(to: url)
    }
}
