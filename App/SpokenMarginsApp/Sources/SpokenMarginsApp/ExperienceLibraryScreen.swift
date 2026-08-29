import SwiftUI
import SessionKit

struct ExperienceLibraryScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @Binding var addSourceRoute: AddSourceRoute?

    private var continueItem: LibraryItemRow? {
        LibraryPresentation.continueItem(in: model.libraryItems, activeItemId: model.activePlaybackItemId)
    }

    private var compactItems: [LibraryItemRow] {
        LibraryPresentation.compactItems(model.visibleLibraryItems, excluding: continueItem)
    }

    var body: some View {
        NavigationStack {
            List {
                ExperienceEditorialHeader(
                    eyebrow: "Your listening life",
                    title: "Listen where you left off",
                    detail: "Your sources, listening progress, and saved Margins stay together."
                )
                .experienceListBlock(horizontalSizeClass: horizontalSizeClass)

                if model.shouldShowOnboardingCard {
                    onboardingStrip
                        .experienceListBlock(horizontalSizeClass: horizontalSizeClass)
                }

                if let continueItem {
                    continueHero(continueItem)
                        .experienceListBlock(horizontalSizeClass: horizontalSizeClass)
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button { model.markItemCompleted(id: continueItem.id) } label: {
                                Label("Complete", systemImage: "checkmark.circle.fill")
                            }
                            .tint(AppColors.evergreen)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) { model.moveItemToTrash(id: continueItem.id) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button { model.prioritizeOfflinePreparation(id: continueItem.id) } label: {
                                Label("Offline", systemImage: "arrow.down.circle")
                            }
                            .tint(AppColors.ochre)
                        }
                }

                controls
                    .experienceListBlock(horizontalSizeClass: horizontalSizeClass)
                items
            }
            .background(AppColors.bone)
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .accessibilityIdentifier("home.screen")
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
        }
        .accessibilityIdentifier("library.screen")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Button("Settings", systemImage: "gearshape", action: model.openSettings)
                Button("Help", systemImage: "questionmark.circle", action: model.openHelp)
                Divider()
                Button("Export Sessions", systemImage: "square.and.arrow.up.on.square", action: model.openBatchExport)
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
                Label("Add Source", systemImage: "plus")
            }
            .accessibilityIdentifier("home.addSource.button")
        }
    }

    private var onboardingStrip: some View {
        ExperienceSurface(tint: AppColors.ochre.opacity(0.7)) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles")
                    .foregroundStyle(AppColors.ochre)
                    .frame(width: 36, height: 36)
                    .background(AppColors.ochre.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 8) {
                    Text("Start with a two-minute tour")
                        .font(.headline)
                    Text("Hear the core loop, then practice making a Margin.")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                    HStack {
                        Button("Hear overview") { model.startItem(id: Gate1AppModel.welcomeSampleItemId) }
                            .buttonStyle(.borderedProminent)
                            .tint(AppColors.evergreen)
                        Button("Practice") { model.startGuidedOnboarding() }
                            .buttonStyle(.bordered)
                    }
                }
                Spacer(minLength: 0)
                Button(action: model.dismissOnboardingCard) {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss getting started")
            }
        }
        .accessibilityIdentifier("library.onboarding.starters")
    }

    private func continueHero(_ item: LibraryItemRow) -> some View {
        Button { model.openItem(id: item.id) } label: {
            HStack(spacing: 18) {
                SMExperienceTypeCover(row: item, size: horizontalSizeClass == .regular ? 112 : 88)
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        model.activePlaybackItemId == item.id ? "Now playing · In your Library" : "Continue listening · In your Library",
                        systemImage: "play.circle.fill"
                    )
                        .font(.caption.weight(.bold))
                        .textCase(.uppercase)
                        .foregroundStyle(AppColors.ochre)
                    Text(item.title)
                        .font(.system(.title2, design: .serif).weight(.bold))
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
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(value: Double(progress), total: 100)
                                .tint(AppColors.ochre)
                            Text("\(progress)% complete")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(AppColors.secondaryText)
                        }
                    }
                }
                Spacer(minLength: 0)
                Button { model.startItem(id: item.id) } label: {
                    Image(systemName: "play.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 54, height: 54)
                        .background(AppColors.evergreen, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Continue \(item.title)")
                .accessibilityIdentifier("library.continue.\(item.id)")
            }
            .padding(horizontalSizeClass == .regular ? 22 : 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [AppColors.panel, AppColors.softGreen.opacity(0.86)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(AppColors.evergreen.opacity(0.28))
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library.row.\(item.id)")
        .accessibilityHint("This item is saved in your Library.")
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AppColors.secondaryText)
                TextField("Search title, source, or author", text: $model.libraryQuery.query)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .accessibilityIdentifier("library.search.field")
                if !model.libraryQuery.query.isEmpty {
                    Button {
                        model.libraryQuery.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(AppColors.secondaryText)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .background(AppColors.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(AppColors.border) }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    contentTypeMenu
                    listeningMenu
                    offlineMenu
                    sortMenu
                }
            }
        }
        .onChange(of: model.libraryQuery) { _, _ in model.libraryQueryChanged() }
    }

    private var contentTypeMenu: some View {
        Menu {
            Picker("Content type", selection: $model.libraryQuery.contentType) {
                ForEach(LibraryContentTypeFilter.allCases, id: \.self) { option in
                    Text(displayName(option.rawValue)).tag(option)
                }
            }
        } label: {
            ExperienceFilterChip(isActive: model.libraryQuery.contentType != .all) {
                Label(displayName(model.libraryQuery.contentType.rawValue), systemImage: "square.grid.2x2")
            }
        }
        .accessibilityIdentifier("library.filter.menu")
    }

    private var listeningMenu: some View {
        Menu {
            Picker("Listening", selection: $model.libraryQuery.listeningState) {
                ForEach(LibraryListeningStateFilter.allCases, id: \.self) { option in
                    Text(displayName(option.rawValue)).tag(option)
                }
            }
        } label: {
            ExperienceFilterChip(isActive: model.libraryQuery.listeningState != .all) {
                Label(displayName(model.libraryQuery.listeningState.rawValue), systemImage: "play.circle")
            }
        }
    }

    private var offlineMenu: some View {
        Menu {
            Picker("Offline", selection: $model.libraryQuery.offlineState) {
                ForEach(LibraryOfflineStateFilter.allCases, id: \.self) { option in
                    Text(displayName(option.rawValue)).tag(option)
                }
            }
        } label: {
            ExperienceFilterChip(isActive: model.libraryQuery.offlineState != .all) {
                Label(displayName(model.libraryQuery.offlineState.rawValue), systemImage: "arrow.down.circle")
            }
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $model.libraryQuery.sort) {
                ForEach(LibrarySort.allCases, id: \.self) { option in
                    Text(displayName(option.rawValue)).tag(option)
                }
            }
        } label: {
            ExperienceFilterChip(isActive: model.libraryQuery.sort != .recentlyAdded) {
                Label(displayName(model.libraryQuery.sort.rawValue), systemImage: "arrow.up.arrow.down")
            }
        }
        .accessibilityIdentifier("library.sort.menu")
    }

    @ViewBuilder
    private var items: some View {
        if model.libraryItems.isEmpty {
            SMExperienceEmptyState(
                systemImage: "books.vertical",
                title: "Your Library is ready",
                detail: "Add a link, text, document, book, or audiobook to begin.",
                actionTitle: "Add Source"
            ) { addSourceRoute = .linkOrPodcast }
            .experienceListBlock(horizontalSizeClass: horizontalSizeClass)
        } else if compactItems.isEmpty {
            SMExperienceEmptyState(
                systemImage: "magnifyingglass",
                title: "No matches",
                detail: "Change the search or clear the active filters.",
                actionTitle: "Clear filters"
            ) {
                model.libraryQuery = LibraryQuery()
                model.libraryQueryChanged()
            }
            .experienceListBlock(horizontalSizeClass: horizontalSizeClass)
        } else {
            Section {
                ForEach(compactItems) { row in
                    ExperienceLibraryCompactRow(
                        row: row,
                        onOpen: { model.openItem(id: row.id) },
                        onPlay: { model.startItem(id: row.id) },
                        onComplete: { model.markItemCompleted(id: row.id) },
                        onPrepareOffline: { model.prioritizeOfflinePreparation(id: row.id) },
                        onDelete: { model.moveItemToTrash(id: row.id) }
                    )
                    .listRowInsets(EdgeInsets(
                        top: 0,
                        leading: horizontalSizeClass == .regular ? 28 : 16,
                        bottom: 0,
                        trailing: horizontalSizeClass == .regular ? 28 : 16
                    ))
                    .listRowBackground(AppColors.bone)
                    .listRowSeparator(.hidden)
                }
            } header: {
                HStack {
                    Text("In your Library")
                        .font(.system(.title3, design: .serif).weight(.bold))
                        .foregroundStyle(AppColors.text)
                    Spacer()
                    Text("\(compactItems.count)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(AppColors.secondaryText)
                }
                .textCase(nil)
                .experienceListBlock(horizontalSizeClass: horizontalSizeClass, verticalPadding: 8)
            }
        }
    }

    private func displayName(_ rawValue: String) -> String {
        rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private struct ExperienceLibraryCompactRow: View {
    let row: LibraryItemRow
    let onOpen: () -> Void
    let onPlay: () -> Void
    let onComplete: () -> Void
    let onPrepareOffline: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            SMExperienceTypeCover(row: row, size: 58)
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.title)
                        .font(.headline)
                        .foregroundStyle(AppColors.text)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                    Text(metadata)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                        .multilineTextAlignment(.leading)
                        .lineLimit(1)
                    HStack(spacing: 7) {
                        if row.isCompleted {
                            Label("Completed", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(AppColors.evergreen)
                        } else if let progress = row.continuationProgressPercent {
                            Text("\(progress)%")
                                .foregroundStyle(AppColors.evergreen)
                            ProgressView(value: Double(progress), total: 100)
                                .frame(maxWidth: 90)
                                .tint(AppColors.ochre)
                        }
                        Label(offlineLabel, systemImage: offlineIcon)
                    }
                    .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColors.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("library.row.\(row.id)")

            Button(action: onPlay) {
                Image(systemName: row.hasContinuationSession ? "play.fill" : "play")
                    .foregroundStyle(AppColors.evergreen)
                    .frame(width: 44, height: 44)
                    .background(AppColors.softGreen, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playActionTitle)
            .accessibilityIdentifier("queue.start.\(row.id)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .contentShape(Rectangle())
        .background(AppColors.panel)
        .overlay(alignment: .bottom) {
            Divider().padding(.leading, 90)
        }
        .contextMenu {
            Button("Open", systemImage: "arrow.right", action: onOpen)
            Button(playActionTitle, systemImage: "play", action: onPlay)
            if !row.isCompleted {
                Button("Mark Complete", systemImage: "checkmark.circle", action: onComplete)
            }
            if row.offlineState != .readyOffline {
                Button("Prepare Offline", systemImage: "arrow.down.circle", action: onPrepareOffline)
            }
            if row.canDelete {
                Button("Move to Recently Deleted", systemImage: "trash", role: .destructive, action: onDelete)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if !row.isCompleted {
                Button(action: onComplete) { Label("Complete", systemImage: "checkmark.circle.fill") }
                    .tint(AppColors.evergreen)
                    .accessibilityIdentifier("library.complete.\(row.id)")
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
        .accessibilityAction(named: "Mark Complete", onComplete)
        .accessibilityAction(named: "Prepare Offline", onPrepareOffline)
        .accessibilityAction(named: "Move to Recently Deleted", onDelete)
    }

    private var metadata: String {
        [row.sourceTitle ?? row.author, mediaLabel]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")
    }

    private var playActionTitle: String {
        if row.isCompleted { return "Review \(row.title)" }
        return row.hasContinuationSession ? "Continue \(row.title)" : "Start \(row.title)"
    }

    private var mediaLabel: String {
        row.mediaType.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private var offlineLabel: String {
        switch row.offlineState {
        case .readyOffline: "Offline"
        case .preparing: "Preparing"
        case .needsRepreparation: "Needs update"
        case .onlineOnly, .all: "Online"
        }
    }

    private var offlineIcon: String {
        switch row.offlineState {
        case .readyOffline: "arrow.down.circle.fill"
        case .preparing: "clock.arrow.circlepath"
        case .needsRepreparation: "exclamationmark.arrow.circlepath"
        case .onlineOnly, .all: "network"
        }
    }
}
