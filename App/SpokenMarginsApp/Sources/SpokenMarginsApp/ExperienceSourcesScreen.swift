import SwiftUI

struct ExperienceSourcesScreen: View {
    private enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case feeds = "Feeds"
        case folder = "Quick Folder"
        var id: String { rawValue }
    }

    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @Binding var addSourceRoute: AddSourceRoute?
    @State private var filter: Filter = .all
    @State private var showsFollow = false
    @State private var showsManagement = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ExperienceEditorialHeader(
                        eyebrow: "Chosen sources only",
                        title: "Source inbox",
                        detail: "New entries wait here until you explicitly add them to Library."
                    )
                    consentBoundary
                    filterBar
                    inbox
                    sourceSetup
                }
                .padding(.horizontal, horizontalSizeClass == .regular ? 28 : 16)
                .padding(.vertical, 20)
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
                    Button(action: { model.refreshQuickAddFeed() }) {
                        if model.isRefreshingQuickAddFeed { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(model.isRefreshingQuickAddFeed)
                    .accessibilityLabel("Refresh Sources")
                    .accessibilityIdentifier("quickAdd.refresh.button")
                    Button { addSourceRoute = .linkOrPodcast } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .accessibilityIdentifier("sources.add.button")
                }
            }
            .task { model.refreshQuickAddFeed(force: false) }
        }
    }

    private var consentBoundary: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(AppColors.evergreen)
                .frame(width: 38, height: 38)
                .background(AppColors.softGreen, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text("Follow is not Add")
                    .font(.headline)
                Text("Following checks for future entries. Nothing is imported, downloaded, or prepared until you choose Add.")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.softGreen.opacity(0.58), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .accessibilityElement(children: .combine)
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
        HStack {
            Text("New entries")
                .font(.system(.title2, design: .serif).weight(.bold))
            Spacer()
            Text("\(filteredCandidates.count)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(AppColors.secondaryText)
        }

        if model.selectedProfileId.contains("offline") {
            Label("Showing the last local snapshot", systemImage: "wifi.slash")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppColors.secondaryText)
        }

        if filteredCandidates.isEmpty {
            SMExperienceEmptyState(
                systemImage: "tray",
                title: "You’re caught up",
                detail: emptyDetail,
                actionTitle: "Follow or add a source"
            ) { showsFollow = true }
        } else {
            VStack(spacing: 0) {
                ForEach(Array(filteredCandidates.enumerated()), id: \.element.id) { index, candidate in
                    if index > 0 { Divider().padding(.leading, 76) }
                    SourceInboxRow(candidate: candidate)
                }
            }
            .background(AppColors.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 20).stroke(AppColors.border) }
        }
    }

    private var sourceSetup: some View {
        VStack(spacing: 12) {
            DisclosureGroup("Follow a feed", isExpanded: $showsFollow) {
                VStack(alignment: .leading, spacing: 12) {
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
                .padding(.top, 12)
            }
            .padding(16)
            .background(AppColors.panel, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 17).stroke(AppColors.border) }

            if !model.feedSubscriptions.isEmpty {
                DisclosureGroup("Manage followed feeds", isExpanded: $showsManagement) {
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
                                    Button("Unfollow", role: .destructive) { model.unfollowSource(id: subscription.id) }
                                } label: {
                                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                                }
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
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(AppColors.evergreen)
                .frame(width: 46, height: 46)
                .background(AppColors.softGreen, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline).lineLimit(2)
                Text(provenance)
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
                if let summary, !summary.isEmpty {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: add) {
                if isImporting { ProgressView() } else { Text("Add") }
            }
            .buttonStyle(.borderedProminent)
            .tint(AppColors.evergreen)
            .disabled(isImporting)
            Menu {
                Button("Dismiss", systemImage: "xmark", action: dismiss)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Entry options")
        }
        .padding(14)
        .accessibilityIdentifier(identifier)
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
