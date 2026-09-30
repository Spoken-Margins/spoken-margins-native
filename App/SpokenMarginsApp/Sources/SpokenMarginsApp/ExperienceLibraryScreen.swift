import SwiftUI
import SessionKit

struct ExperienceLibraryScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Binding var addSourceRoute: AddSourceRoute?
    @State private var isAudioPreparationQueuePresented = false

    private var continueItem: LibraryItemRow? {
        LibraryPresentation.continueItem(in: model.libraryItems, activeItemId: model.activePlaybackItemId)
    }

    private var compactItems: [LibraryItemRow] {
        LibraryPresentation.compactItems(model.visibleLibraryItems, excluding: continueItem)
    }

    private var visibleContinueItem: LibraryItemRow? {
        guard let continueItem,
              model.visibleLibraryItems.contains(where: { $0.id == continueItem.id }) else {
            return nil
        }
        return continueItem
    }

    private var completionUndoActions: some View {
        HStack {
            Button("Undo Mark Complete", action: model.undoMarkedCompletion)
                .accessibilityIdentifier("completion.undo.button")
            Button { model.completionUndo = nil } label: { Image(systemName: "xmark") }
                .accessibilityLabel("Dismiss completion notification")
        }
        .buttonStyle(.borderless)
    }

    var body: some View {
        NavigationStack {
            List {
                controls
                    .experienceListBlock(horizontalSizeClass: horizontalSizeClass, verticalPadding: 4)

                if let undo = model.completionUndo {
                        ViewThatFits(in: .horizontal) {
                            HStack {
                                Text("Marked \(undo.title) complete.").lineLimit(2)
                                completionUndoActions
                            }
                            VStack(alignment: .leading) {
                                Text("Marked \(undo.title) complete.")
                                completionUndoActions
                            }
                        }
                        .font(.subheadline)
                        .padding(12)
                        .background(AppColors.panel, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("completion.undo.banner")
                        .experienceListBlock(horizontalSizeClass: horizontalSizeClass, verticalPadding: 4)
                    }

                if let continueItem = visibleContinueItem {
                    ExperienceLibraryCompactRow(
                        row: continueItem,
                        isCurrentItem: true,
                        onOpen: { model.openItem(id: continueItem.id) },
                        onPlay: { model.startItem(id: continueItem.id) },
                        onComplete: { model.markItemCompleted(id: continueItem.id) },
                        onPrepareOffline: { model.prioritizeOfflinePreparation(id: continueItem.id) },
                        onDelete: { model.moveItemToTrash(id: continueItem.id) }
                    )
                    .libraryRowLayout(horizontalSizeClass: horizontalSizeClass)
                }

                items

                if !model.audioPreparationQueue.isEmpty || !model.recentlyPreparedAudio.isEmpty {
                    preparationSummary
                        .experienceListBlock(horizontalSizeClass: horizontalSizeClass, verticalPadding: 6)
                }

                if model.shouldShowOnboardingCard {
                    onboardingStrip
                        .experienceListBlock(horizontalSizeClass: horizontalSizeClass)
                }
            }
            .background(AppColors.bone)
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .animation(.smooth(duration: 0.24), value: compactItems.map(\.id))
            .accessibilityIdentifier("home.screen")
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
        }
        .accessibilityIdentifier("library.screen")
        .sheet(isPresented: $isAudioPreparationQueuePresented) {
            ExperienceAudioPreparationQueueScreen()
                .environmentObject(model)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Button("Settings", systemImage: "gearshape", action: model.openSettings)
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
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library.offlineRendering.button")
    }

    private var preparationSummaryDetail: String {
        let queued = model.audioPreparationQueue.count
        let recent = model.recentlyPreparedAudio.count
        if queued > 0, recent > 0 {
            return "\(queued) queued · \(recent) recently ready"
        }
        if queued > 0 { return "\(queued) item\(queued == 1 ? "" : "s") queued" }
        return "\(recent) item\(recent == 1 ? "" : "s") recently ready"
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
                            .buttonStyle(PrimaryButtonStyle())
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
                        .accessibilityIdentifier("library.filters.reset")
                }
            }
            if model.libraryHidesCompleted {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Text("Completed items hidden")
                        Button(model.libraryQuery.query.isEmpty ? "Show completed" : "Include in search") {
                            if model.libraryQuery.query.isEmpty { model.showCompletedLibraryItems() }
                            else { model.libraryQuery.listeningState = .all }
                        }
                    }
                    VStack(alignment: .leading) {
                        Text("Completed items hidden")
                        Button(model.libraryQuery.query.isEmpty ? "Show completed" : "Include in search") {
                            if model.libraryQuery.query.isEmpty { model.showCompletedLibraryItems() }
                            else { model.libraryQuery.listeningState = .all }
                        }
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
        } else if model.libraryIsCaughtUp {
            SMExperienceEmptyState(
                systemImage: "checkmark.circle",
                title: "You’re caught up",
                detail: "Your completed items and Margins are still here.",
                actionTitle: "Show completed"
            ) { model.showCompletedLibraryItems() }
            .experienceListBlock(horizontalSizeClass: horizontalSizeClass)
        } else if model.visibleLibraryItems.isEmpty {
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
        } else {
            ForEach(compactItems) { row in
                ExperienceLibraryCompactRow(
                    row: row,
                    onOpen: { model.openItem(id: row.id) },
                    onPlay: { model.startItem(id: row.id) },
                    onComplete: { model.markItemCompleted(id: row.id) },
                    onPrepareOffline: { model.prioritizeOfflinePreparation(id: row.id) },
                    onDelete: { model.moveItemToTrash(id: row.id) }
                )
                .libraryRowLayout(horizontalSizeClass: horizontalSizeClass)
            }
        }
    }

    private func displayName(_ rawValue: String) -> String {
        rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private struct ExperienceLibraryCompactRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let row: LibraryItemRow
    var isCurrentItem = false
    let onOpen: () -> Void
    let onPlay: () -> Void
    let onComplete: () -> Void
    let onPrepareOffline: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: mediaSymbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(AppColors.evergreen)
                .frame(width: 38, height: 44)
                .background(AppColors.softGreen.opacity(isCurrentItem ? 0.85 : 0.55))
                .accessibilityLabel(mediaLabel)
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
                    Text(detailLine)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                        .multilineTextAlignment(.leading)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("library.row.\(row.id)")

            Button(action: onPlay) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: row.offlineState == .readyOffline ? "play.fill" : "play")
                        .foregroundStyle(AppColors.evergreen)
                        .frame(width: 40, height: 40)
                        .background(AppColors.softGreen, in: Circle())
                    if row.startupAudioState == .preparing {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(AppColors.evergreen)
                            .padding(2)
                            .background(AppColors.panel, in: Circle())
                    }
                }
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

    private var detailLine: String {
        [sourceByline, mediaLabel, listeningLabel, statusDetail]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")
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
