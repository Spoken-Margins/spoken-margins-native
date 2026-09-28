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
    @State private var pendingUnfollowID: String?
    @FocusState private var feedURLIsFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                intakeHeader
                    .experienceListBlock(horizontalSizeClass: horizontalSizeClass)
                filterBar
                    .experienceListBlock(horizontalSizeClass: horizontalSizeClass, verticalPadding: 4)
                Section {
                    Button {
                        catalogDrawer.present()
                    } label: {
                        Label("Browse top podcasts", systemImage: "square.grid.2x2")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .accessibilityIdentifier("sources.browseCatalog")
                    NavigationLink("Read Later Services") { ReadLaterScreen() }
                    NavigationLink("Import Listening Edition") { ListeningEditionImportScreen() }
                }
                sourceSetup
                    .experienceListBlock(horizontalSizeClass: horizontalSizeClass)
                inbox
            }
            .background(AppColors.bone)
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .animation(.smooth(duration: 0.24), value: filteredCandidates.map(\.id))
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
            .confirmationDialog("Unfollow this feed?", isPresented: Binding(
                get: { pendingUnfollowID != nil },
                set: { if !$0 { pendingUnfollowID = nil } }
            ), titleVisibility: .visible) {
                Button("Unfollow", role: .destructive) {
                    if let id = pendingUnfollowID { model.unfollowSource(id: id) }
                    pendingUnfollowID = nil
                }
            } message: {
                Text("Items already in your Library will be kept.")
            }
            .task { model.refreshQuickAddFeed(force: false) }
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
            .buttonStyle(.borderedProminent)
            .tint(AppColors.evergreen)
            .disabled(model.followedSourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("sources.follow.button")
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Filter.allCases) { option in
                    Button { filter = option } label: {
                        ExperienceFilterChip(isActive: filter == option) { Text(option.rawValue) }
                    }
                    .buttonStyle(.plain)
                }
            }
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

            if filteredCandidates.isEmpty {
                SMExperienceEmptyState(
                    systemImage: "tray",
                    title: "You’re caught up",
                    detail: emptyDetail,
                    actionTitle: "Paste a feed link"
                ) {
                    // Paste when the clipboard holds a link; otherwise leave the field ready for typing.
                    if !model.pasteFollowedSourceFromClipboard() { feedURLIsFocused = true }
                }
                .experienceListBlock(horizontalSizeClass: horizontalSizeClass)
            } else {
                ForEach(filteredCandidates) { candidate in
                    SourceInboxRow(candidate: candidate)
                        .listRowInsets(EdgeInsets(
                            top: 0,
                            leading: horizontalSizeClass == .regular ? 28 : 16,
                            bottom: 0,
                            trailing: horizontalSizeClass == .regular ? 28 : 16
                        ))
                        .listRowSeparator(.hidden)
                        .listRowBackground(AppColors.bone)
                }
            }
        } header: {
            HStack {
                Text("New")
                    .font(.headline)
                    .foregroundStyle(AppColors.text)
                Spacer()
                Text("\(filteredCandidates.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(AppColors.secondaryText)
            }
            .textCase(nil)
            .experienceListBlock(horizontalSizeClass: horizontalSizeClass, verticalPadding: 8)
        }
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

    private var filteredCandidates: [QuickAddCandidate] {
        model.quickAddCandidates.filter { candidate in
            switch (filter, candidate) {
            case (.all, _), (.feeds, .followedSource), (.folder, .localFile): true
            default: false
            }
        }
    }

    private var emptyDetail: String {
        switch filter {
        case .all: "Follow a feed or connect a Quick Folder. New entries will wait for an explicit choice."
        case .feeds: "No new entries from followed feeds."
        case .folder: "No new eligible files in your Quick Folder."
        }
    }
}

private struct SourceInboxRow: View {
    @EnvironmentObject private var model: Gate1AppModel
    let candidate: QuickAddCandidate

    var body: some View {
        Button(action: addAndOpen) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(AppColors.evergreen)
                    .frame(width: 46, height: 46)
                    .background(AppColors.softGreen, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(AppColors.text)
                        .multilineTextAlignment(.leading)
                    Text(provenance)
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                    if let summary, !summary.isEmpty {
                        Text(summary)
                            .font(.subheadline)
                            .foregroundStyle(AppColors.secondaryText)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
        }
        .buttonStyle(.plain)
        .disabled(isImporting)
        .padding(14)
        .background(AppColors.panel)
        .accessibilityIdentifier(identifier)
        .accessibilityHint("Adds this entry to Library and opens it.")
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
        }
        .accessibilityAction(named: "Add to Library", addAndOpen)
        .accessibilityAction(named: "Dismiss", dismiss)
    }

    private var title: String {
        switch candidate {
        case .localFile(let file): file.name
        case .followedSource(let entry): entry.title
        }
    }

    private var summary: String? {
        if case .followedSource(let entry) = candidate { return entry.summary }
        return nil
    }

    private var provenance: String {
        switch candidate {
        case .localFile(let file): return "Quick Folder · \(file.modifiedAtDescription)"
        case .followedSource(let entry):
            let source = model.feedSubscriptions.first(where: { $0.id == entry.subscriptionId })?.source
            return source?.title ?? source?.host ?? entry.author ?? "Followed feed"
        }
    }

    private var systemImage: String {
        if case .localFile = candidate { return "folder" }
        return "dot.radiowaves.left.and.right"
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

    private func addInPlace() {
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
