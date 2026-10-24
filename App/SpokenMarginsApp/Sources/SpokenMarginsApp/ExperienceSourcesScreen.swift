import SessionKit
import SwiftUI

struct ExperienceSourcesScreen: View {
    private enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case feeds = "Feeds"
        case folder = "Quick Folder"
        var id: String { rawValue }
    }

    @EnvironmentObject private var model: Gate1AppModel
    @EnvironmentObject private var catalogDrawer: CatalogDrawerModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var filter: Filter = .all
    /// Kind chip and subject menu (#485); subjects hidden on this device live in its preferences.
    @State private var kind: SourceContentKind?
    @State private var subject: String?
    @AppStorage("following.hiddenSubjects") private var hiddenSubjectsStorage = ""
    /// Feed management lives on its own screen so Following opens on the new entries (#141).
    @State private var isManagingFeeds = false
    @State private var focusFeedURLOnManage = false
    /// Each followed show's artwork (#773), read from the coordinator's side file.
    @State private var artwork = FollowingArtworkCache()
    /// The swipe hint shows once, ever (#478); a per-viewer flag. It stays up for the rest of that visit.
    @AppStorage("following.swipeHintSeen") private var swipeHintSeen = false
    @State private var swipeHintShownThisVisit = false
    /// The place in the list, kept by the root view because opening an entry destroys this screen (#479).
    @Binding var scrollMemory: FollowingScrollMemory
    /// Follows the top entry without redrawing the screen on every row that scrolls by (#479).
    @State private var scrollTracker = ListScrollTracker()
    @State private var restoredScroll = false
    /// "Clear" on the New list asks first: it dismisses everything listed (#1589).
    @State private var isConfirmingClear = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    // An item's Follow can find several feeds; the choice shows here too, not only on Manage Feeds.
                    if !model.followedSourceCandidates.isEmpty {
                        VStack(alignment: .leading, spacing: 10) { FollowCandidateChoices() }
                            .experienceListBlock(horizontalSizeClass: horizontalSizeClass)
                    }
                    manageFeedsRow
                        .experienceListBlock(horizontalSizeClass: horizontalSizeClass, verticalPadding: 4)
                    filterBar
                        .experienceListBlock(horizontalSizeClass: horizontalSizeClass, verticalPadding: 4)
                    inbox
                }
                .onChange(of: candidateIDs, initial: true) { _, ids in
                    scrollTracker.order = ids
                    restoreScroll(in: ids, using: proxy)
                }
                .onAppear { if restoredScroll { scrollTracker.thaw() } }
                .onDisappear { rememberScroll() }
                .background(AppColors.bone)
                .scrollContentBackground(.hidden)
                .listStyle(.plain)
                .refreshable { await model.pullToRefreshFollowing() }
                .motionAnimation(.smooth(duration: 0.24), value: orderedCandidates.map(\.id))
                .confirmationDialog(
                    "Clear the \(clearableEntryIDs.count) entries listed in New?",
                    isPresented: $isConfirmingClear,
                    titleVisibility: .visible
                ) {
                    Button("Clear \(clearableEntryIDs.count) entries", role: .destructive) {
                        model.clearFollowedSourceEntries(ids: clearableEntryIDs)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Nothing is added to your Library. You can undo right after.")
                }
                .accessibilityIdentifier("sources.screen")
                .navigationTitle("Following")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: model.openSettings) {
                            Image(systemName: "gearshape").frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Settings")
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button(action: { model.refreshQuickAddFeed() }) {
                            if model.isRefreshingQuickAddFeed { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                        }
                        .frame(minWidth: 44, minHeight: 44)
                        .disabled(model.isRefreshingQuickAddFeed)
                        .accessibilityLabel("Refresh Sources")
                        .accessibilityIdentifier("quickAdd.refresh.button")
                    }
                }
                .navigationDestination(isPresented: $isManagingFeeds) {
                    ManageFeedsScreen(focusFeedURLOnAppear: focusFeedURLOnManage)
                        .miniPlayerKeepOut()
                }
                .task { model.refreshQuickAddFeed(force: false) }
                // The catalog tags followed shows with a kind and subjects (I2), and gives their artwork (#773).
                .task { await catalogDrawer.loadSnapshot() }
                // Re-read the artwork when the shows, the catalog or a refresh changes it (#773).
                .task(id: ArtworkKey(
                    subscriptionIDs: model.feedSubscriptions.map(\.id),
                    hasCatalog: catalogDrawer.catalog != nil,
                    isRefreshing: model.isRefreshingFollowedSources
                )) {
                    guard let coordinator = model.followedSourceCoordinator else { return }
                    artwork = await coordinator.followingArtwork(catalog: catalogDrawer.catalog)
                }
            }
            .miniPlayerKeepOut()
        }
    }

    /// One compact row instead of the feed field, links and feed list (#141).
    private var manageFeedsRow: some View {
        Button(action: { openManageFeeds(focusingFeedURL: false) }) {
            HStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(AppColors.evergreen)
                    .accessibilityHidden(true)
                Text(manageFeedsTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.text)
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
        .accessibilityIdentifier("sources.manageFeeds")
        .accessibilityHint("Follow a feed, browse podcasts and writers, or manage the feeds you follow.")
    }

    private var manageFeedsTitle: String {
        let count = model.feedSubscriptions.count
        if count == 0 { return "Follow a feed" }
        return "\(count) \(count == 1 ? "feed" : "feeds") · Manage"
    }

    private func openManageFeeds(focusingFeedURL: Bool) {
        focusFeedURLOnManage = focusingFeedURL
        isManagingFeeds = true
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Filter.allCases) { option in
                    Button {
                        filter = option
                        if option == .all { kind = nil; subject = nil }
                    } label: {
                        ExperienceFilterChip(isActive: filter == option && (option != .all || !isNarrowed)) { Text(option.rawValue) }
                    }
                    .buttonStyle(.plain)
                }
                ForEach(FollowingFilter.kinds(in: inboxCategories), id: \.self) { option in
                    Button { kind = kind == option ? nil : option } label: {
                        ExperienceFilterChip(isActive: kind == option) { Text(Self.title(of: option)) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("sources.filter.kind.\(option.rawValue)")
                }
                subjectMenu
            }
        }
    }

    @ViewBuilder
    private var subjectMenu: some View {
        let subjects = FollowingFilter.subjects(in: inboxCategories, catalog: catalogDrawer.catalog)
        if !subjects.isEmpty || !hiddenSubjects.isEmpty {
            Menu {
                Picker("Subject", selection: $subject) {
                    Text("All subjects").tag(String?.none)
                    ForEach(subjects) { option in
                        Text(option.title).tag(Optional(option.id))
                    }
                }
                let hideable = subjects.filter { !hiddenSubjects.contains($0.id) }
                if !hideable.isEmpty {
                    Menu("Hide a subject") {
                        ForEach(hideable) { option in
                            Button(option.title) { setHidden(option.id, true) }
                        }
                    }
                }
                if !hiddenSubjects.isEmpty {
                    Section("Hidden") {
                        ForEach(hiddenSubjects.sorted(), id: \.self) { id in
                            Button("Show \(subjectTitle(id))") { setHidden(id, false) }
                        }
                    }
                }
            } label: {
                ExperienceFilterChip(isActive: subject != nil) {
                    Label(subject.map(subjectTitle) ?? "Subject", systemImage: "line.3.horizontal.decrease")
                }
            }
            .accessibilityIdentifier("sources.filter.subject")
        }
    }

    @ViewBuilder
    private var inbox: some View {
        Section {
            if model.selectedProfileId.contains("offline") {
                Label("Showing the last local snapshot", systemImage: "wifi.slash")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.secondaryText)
                    .experienceListBlock(horizontalSizeClass: horizontalSizeClass, verticalPadding: 4)
            }

            if orderedCandidates.isEmpty {
                SMExperienceEmptyState(
                    systemImage: "tray",
                    title: "You’re caught up",
                    detail: emptyDetail,
                    actionTitle: "Paste a feed link"
                ) {
                    // Paste when the clipboard holds a link; otherwise leave the field ready for typing.
                    openManageFeeds(focusingFeedURL: !model.pasteFollowedSourceFromClipboard())
                }
                .experienceListBlock(horizontalSizeClass: horizontalSizeClass)
            } else {
                if showsSwipeHint {
                    swipeHint
                        .experienceListBlock(horizontalSizeClass: horizontalSizeClass, verticalPadding: 4)
                }
                ForEach(orderedCandidates) { row in
                    SourceInboxRow(candidate: row.candidate, artwork: artwork)
                    .listRowInsets(EdgeInsets(
                        top: 0,
                        leading: horizontalSizeClass == .regular ? 28 : 16,
                        bottom: 0,
                        trailing: horizontalSizeClass == .regular ? 28 : 16
                    ))
                    .listRowSeparator(.hidden)
                    .listRowBackground(AppColors.bone)
                    .onAppear { scrollTracker.rowChanged(row.id, isVisible: true) }
                    .onDisappear { scrollTracker.rowChanged(row.id, isVisible: false) }
                }
            }
        } header: {
            HStack {
                Text("New")
                    .font(.headline)
                    .foregroundStyle(AppColors.text)
                Spacer()
                if clearableEntryIDs.count > 1 {
                    Button("Clear") { isConfirmingClear = true }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppColors.evergreen)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("sources.clearNew")
                        .accessibilityHint("Dismisses every followed entry listed, with Undo.")
                }
                Text("\(orderedCandidates.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(AppColors.secondaryText)
            }
            .textCase(nil)
            .experienceListBlock(horizontalSizeClass: horizontalSizeClass, verticalPadding: 8)
        }
    }

    /// The followed entries listed now, which Clear dismisses. Quick Folder files keep their own dismissal.
    private var clearableEntryIDs: [String] {
        orderedCandidates.compactMap { row -> String? in
            guard case .followedSource(let entry) = row.candidate else { return nil }
            return entry.id
        }
    }

    private struct OrderedCandidate: Identifiable {
        var candidate: QuickAddCandidate
        var id: String { candidate.id }
    }

    /// The filtered inbox, newest first as the model lists it. The Top order (#484) is off until it
    /// picks entries worth listening to (#1440); `FollowingRanker` stays in SessionKit for it.
    private var orderedCandidates: [OrderedCandidate] {
        filteredCandidates.map { OrderedCandidate(candidate: $0) }
    }

    private var filteredCandidates: [QuickAddCandidate] {
        let narrowing = FollowingFilter(kind: kind, subject: subject, hiddenSubjects: hiddenSubjects)
        let categories = subscriptionCategories
        return model.quickAddCandidates.filter { candidate in
            switch (filter, candidate) {
            case (.all, _), (.feeds, .followedSource), (.folder, .localFile): narrowing.includes(category(of: candidate, in: categories))
            default: false
            }
        }
    }

    /// Shown the first time Following lists entries, and for the rest of that visit (#478).
    private var showsSwipeHint: Bool { !swipeHintSeen || swipeHintShownThisVisit }

    private var swipeHint: some View {
        Label(FollowingRowActions.swipeHint, systemImage: "hand.draw")
            .font(.footnote)
            .foregroundStyle(AppColors.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("sources.swipeHint")
            .onAppear {
                swipeHintShownThisVisit = true
                swipeHintSeen = true
            }
    }

    private var isNarrowed: Bool { kind != nil || subject != nil }

    private var candidateIDs: [String] { orderedCandidates.map(\.id) }

    /// Hands the place to the root view, which outlives this screen.
    private func rememberScroll() {
        scrollTracker.freeze()
        guard let top = scrollTracker.topEntryID else { return }
        scrollMemory = FollowingScrollMemory(topEntryId: top, order: candidateIDs)
    }

    /// Scrolls back to the remembered entry once, the first time the list has entries. The tracker
    /// stays frozen until then, so the rows that appear at the top first don't overwrite the place.
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
            // Not at the very top: the pinned "New" header covers the first row there.
            proxy.scrollTo(target, anchor: UnitPoint(x: 0.5, y: 0.06))
            try? await Task.sleep(for: .milliseconds(150))
            scrollTracker.thaw()
        }
    }

    private struct ArtworkKey: Equatable {
        var subscriptionIDs: [String]
        var hasCatalog: Bool
        var isRefreshing: Bool
    }

    private var hiddenSubjects: Set<String> {
        Set(hiddenSubjectsStorage.split(separator: "\n").map(String.init))
    }

    private func setHidden(_ id: String, _ hidden: Bool) {
        var ids = hiddenSubjects
        if hidden { ids.insert(id) } else { ids.remove(id) }
        hiddenSubjectsStorage = ids.sorted().joined(separator: "\n")
        if hidden, subject == id { subject = nil }
    }

    /// Categories of the inbox's followed-feed entries, for the chips and menu.
    private var inboxCategories: [FollowedSourceCategory] {
        let categories = subscriptionCategories
        return model.quickAddCandidates.compactMap { category(of: $0, in: categories) }
    }

    /// One lookup per followed feed, not per inbox entry: feeds keep up to 200 entries each.
    private var subscriptionCategories: [String: FollowedSourceCategory] {
        FollowedSourceCategory.bySubscription(model.feedSubscriptions, catalog: catalogDrawer.catalog)
    }

    /// nil for a Quick Folder file. A feed entry whose subscription is gone is classed by its audio.
    private func category(of candidate: QuickAddCandidate, in categories: [String: FollowedSourceCategory]) -> FollowedSourceCategory? {
        guard case .followedSource(let entry) = candidate else { return nil }
        return categories[entry.subscriptionId] ?? FollowedSourceCategory(contentKind: entry.audioURL == nil ? .article : .podcast)
    }

    private func subjectTitle(_ id: String) -> String {
        catalogDrawer.catalog?.subjects.first { $0.id == id }?.title ?? id
    }

    private static func title(of kind: SourceContentKind) -> String {
        switch kind {
        case .podcast: "Podcasts"
        case .article: "Articles"
        case .newsletter: "Newsletters"
        case .paper: "Papers"
        case .news: "News"
        case .video: "Videos"
        default: kind.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private var emptyDetail: String {
        if isNarrowed { return "Nothing new matches this filter." }
        return switch filter {
        case .all: "Follow a feed or connect a Quick Folder. New entries will wait for an explicit choice."
        case .feeds: "No new entries from followed feeds."
        case .folder: "No new eligible files in your Quick Folder."
        }
    }
}

/// Adding and managing followed feeds, pushed from Following's "N feeds · Manage" row (#141).
private struct ManageFeedsScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @EnvironmentObject private var catalogDrawer: CatalogDrawerModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Following's empty state found no link on the clipboard, so the field opens ready for typing.
    let focusFeedURLOnAppear: Bool
    @State private var pendingUnfollowID: String?
    private var pendingUnfollowTitle: String? {
        model.feedSubscriptions.first { $0.id == pendingUnfollowID }.map { $0.source.title ?? $0.source.host }
    }
    @State private var didFocusOnAppear = false
    @FocusState private var feedURLIsFocused: Bool

    var body: some View {
        List {
            intakeHeader
                .experienceListBlock(horizontalSizeClass: horizontalSizeClass)
            Section {
                Button {
                    catalogDrawer.present()
                } label: {
                    Label("Browse podcasts and writers", systemImage: "square.grid.2x2")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .accessibilityIdentifier("sources.browseCatalog")
                if let makeOPMLImport = catalogDrawer.makeOPMLImport {
                    NavigationLink {
                        OPMLImportScreen(importer: makeOPMLImport())
                            .miniPlayerKeepOut()
                    } label: {
                        Label("Import from another app", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .accessibilityIdentifier("sources.importOPML")
                }
                NavigationLink("Read Later Services") { ReadLaterScreen().miniPlayerKeepOut() }
                NavigationLink("Import Listening Edition") { ListeningEditionImportScreen().miniPlayerKeepOut() }
            }
            sourceSetup
                .experienceListBlock(horizontalSizeClass: horizontalSizeClass)
        }
        .background(AppColors.bone)
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        .accessibilityIdentifier("sources.manageFeeds.screen")
        .navigationTitle("Manage Feeds")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(FollowingRowActions.unfollowQuestion(showTitle: pendingUnfollowTitle), isPresented: Binding(
            get: { pendingUnfollowID != nil },
            set: { if !$0 { pendingUnfollowID = nil } }
        ), titleVisibility: .visible) {
            Button("Unfollow", role: .destructive) {
                // The dialog clears pendingUnfollowID as it closes, so its title keeps the show's name.
                if let id = pendingUnfollowID { model.unfollowSource(id: id) }
            }
        } message: {
            Text("Items already in your Library will be kept.")
        }
        .task {
            // Once: coming back from Read Later shouldn't raise the keyboard again.
            guard focusFeedURLOnAppear, !didFocusOnAppear else { return }
            didFocusOnAppear = true
            // Focus after the push settles; a field focused mid-transition can drop the keyboard.
            try? await Task.sleep(for: .milliseconds(450))
            feedURLIsFocused = true
        }
    }

    private var intakeHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    feedURLField
                    followButton
                }
                VStack(alignment: .leading, spacing: 10) {
                    feedURLField
                    followButton
                }
            }
            FollowCandidateChoices()
        }
    }

    private var feedURLField: some View {
        TextField("Paste an RSS feed link", text: $model.followedSourceURL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.URL)
            .keyboardType(.URL)
            .submitLabel(.go)
            .focused($feedURLIsFocused)
            .onSubmit(model.followSource)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(AppColors.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(AppColors.border) }
            .accessibilityIdentifier("sources.follow.url")
    }

    private var followButton: some View {
        Button("Follow", action: model.followSource)
            .frame(minHeight: 46)
            .filledActionButton()
            .disabled(model.followedSourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("sources.follow.button")
    }

    @ViewBuilder
    private var sourceSetup: some View {
        if !model.feedSubscriptions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Followed feeds").font(.headline)
                VStack(spacing: 0) {
                    ForEach(model.feedSubscriptions) { subscription in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(subscription.source.title ?? subscription.source.host).font(.headline)
                                Text(subscription.state.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                                    .font(.caption)
                                    .foregroundStyle(AppColors.secondaryText)
                            }
                            Spacer()
                            Menu {
                                Picker("New items", selection: Binding(
                                    get: { subscription.newItemPolicy ?? .letMePick },
                                    set: { model.setFeedNewItemPolicy(id: subscription.id, policy: $0) }
                                )) {
                                    Text("Let me pick").tag(FeedNewItemPolicy.letMePick)
                                    Text("Add every new item").tag(FeedNewItemPolicy.addEveryNewItem)
                                }
                                Button(subscription.state == .muted ? "Unmute" : "Mute") {
                                    model.toggleMuteSource(id: subscription.id)
                                }
                                Button("Unfollow", role: .destructive) { pendingUnfollowID = subscription.id }
                            } label: {
                                Label("Manage", systemImage: "ellipsis")
                                    .frame(minHeight: 44)
                            }
                            .accessibilityLabel("Manage \(subscription.source.title ?? subscription.source.host)")
                        }
                        .padding(.top, 12)
                    }
                }
            }
            .padding(16)
            .background(AppColors.panel, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 17).stroke(AppColors.border) }
        }
    }
}

/// The feeds a link or an item's Follow found, when there is more than one to choose from.
struct FollowCandidateChoices: View {
    @EnvironmentObject private var model: Gate1AppModel

    var body: some View {
        ForEach(model.followedSourceCandidates) { candidate in
            Button {
                model.followSourceCandidate(candidate)
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
    @State private var confirmsUnfollow = false

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
            .tint(AppColors.evergreen)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(action: dismiss) {
                Label("Dismiss", systemImage: "xmark")
            }
            .tint(AppColors.plum)
            // Second and not a full swipe: the first button above is the one a long swipe takes.
            if subscription != nil {
                Button { confirmsUnfollow = true } label: {
                    Label("Unfollow", systemImage: "minus.circle")
                }
                .tint(AppColors.secondaryText)
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
            Text("Items already in your Library will be kept.")
        }
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
        .accessibilityAction(named: "Dismiss", dismiss)
        .accessibilityActions {
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
        Button(action: addInPlace) { Label("Add to Library", systemImage: "plus.circle") }
        if isFeedEntry {
            Button(action: playNow) { Label("Play now", systemImage: "play.fill") }
        }
        Button(action: dismiss) { Label("Dismiss", systemImage: "xmark") }
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
        case .localFile(let file): "Quick Folder · \(file.modifiedAtDescription)"
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
        if let row { return row.accessibilityLabel }
        return "\(title). \(provenance)"
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
            }
            .font(.caption)
            .foregroundStyle(AppColors.secondaryText)
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

    private func dismiss() {
        switch candidate {
        case .localFile(let file): model.dismissQuickAccessFileWithUndo(file)
        case .followedSource(let entry): model.dismissFollowedSourceEntry(id: entry.id)
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
