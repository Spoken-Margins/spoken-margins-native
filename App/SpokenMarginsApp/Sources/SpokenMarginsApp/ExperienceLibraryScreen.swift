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

    private var libraryComposition: Build23ExperiencePolishLayout.LibraryComposition {
        Build23ExperiencePolishLayout.libraryComposition(
            isCompactWidth: horizontalSizeClass == .compact,
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
        )
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
                if !model.audioPreparationQueue.isEmpty || !model.recentlyPreparedAudio.isEmpty {
                    preparationSummary
                        .experienceListBlock(horizontalSizeClass: horizontalSizeClass, verticalPadding: 4)
                }
                items
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
                Button("Offline Rendering", systemImage: "waveform.badge.magnifyingglass") {
                    isAudioPreparationQueuePresented = true
                }
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
                        Text("Offline rendering")
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

    private func continueHero(_ item: LibraryItemRow) -> some View {
        Group {
            Group {
                switch libraryComposition {
                case .horizontal:
                    HStack(spacing: 18) {
                        SMExperienceTypeCover(row: item, size: horizontalSizeClass == .regular ? 112 : 88)
                        Button { model.openItem(id: item.id) } label: { continueHeroDetails(item) }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("library.row.\(item.id)")
                        Spacer(minLength: 0)
                        continueHeroAction(item)
                    }
                case .wrapped:
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top, spacing: 12) {
                            SMExperienceTypeCover(row: item, size: 88)
                            Spacer(minLength: 12)
                            continueHeroAction(item)
                        }
                        Button { model.openItem(id: item.id) } label: { continueHeroDetails(item) }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("library.row.\(item.id)")
                    }
                }
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
        .accessibilityHint("This item is saved in your Library.")
    }

    private func continueHeroDetails(_ item: LibraryItemRow) -> some View {
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
    }

    private func continueHeroAction(_ item: LibraryItemRow) -> some View {
        Button { model.startItem(id: item.id) } label: {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "play.fill")
                    .font(.title3)
                    .foregroundStyle(item.offlineState == .readyOffline ? .white : AppColors.evergreen)
                    .frame(width: 54, height: 54)
                    .background(item.offlineState == .readyOffline ? AppColors.evergreen : AppColors.softGreen, in: Circle())
                if item.startupAudioState == .preparing {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(AppColors.evergreen)
                        .padding(4)
                        .background(AppColors.panel, in: Circle())
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Continue \(item.title)")
        .accessibilityValue(
            item.startupAudioState == .preparing
                ? "\(startupProgressDescription(item)). Playback can start now."
                : (item.offlineState == .readyOffline ? "Ready offline" : "Opening audio ready")
        )
        .accessibilityIdentifier("library.continue.\(item.id)")
    }

    private func startupProgressDescription(_ item: LibraryItemRow) -> String {
        let target = max(1, item.startupAudioTargetChunkCount)
        return "\(min(item.startupAudioCompletedChunkCount, target)) of \(target) opening chunks ready"
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

            filterControls
        }
        .onChange(of: model.libraryQuery) { _, _ in model.libraryQueryChanged() }
    }

    @ViewBuilder
    private var filterControls: some View {
        if libraryComposition == .wrapped {
            wrappedFilterControls
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    contentTypeMenu
                    listeningMenu
                    offlineMenu
                    sortMenu
                }
                .fixedSize(horizontal: true, vertical: false)

                wrappedFilterControls
            }
        }
    }

    private var wrappedFilterControls: some View {
        LazyVGrid(columns: wrappedFilterColumns, alignment: .leading, spacing: 8) {
            contentTypeMenu.frame(maxWidth: .infinity, alignment: .leading)
            listeningMenu.frame(maxWidth: .infinity, alignment: .leading)
            offlineMenu.frame(maxWidth: .infinity, alignment: .leading)
            sortMenu.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var wrappedFilterColumns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible(), spacing: 8, alignment: .leading)]
        }
        return [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)]
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
        HStack(alignment: .center, spacing: 12) {
            SMExperienceTypeCover(row: row, size: 52)
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.title)
                        .font(.headline)
                        .foregroundStyle(AppColors.text)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                    Text(detailLine)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                        .multilineTextAlignment(.leading)
                        .lineLimit(1)
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
                    ? "\(startupProgressDescription). Playback can start now."
                    : (row.offlineState == .readyOffline ? "Ready offline" : "Ready to start")
            )
            .accessibilityIdentifier("queue.start.\(row.id)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
        .contentShape(Rectangle())
        .background(AppColors.panel)
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
        [row.sourceTitle ?? row.author, mediaLabel, listeningLabel, offlineDetailLabel]
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
        row.mediaType.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private var offlineDetailLabel: String? {
        switch row.startupAudioState {
        case .preparing:
            return "Opening audio \(startupProgressDescription.lowercased())"
        case .ready where row.offlineState != .readyOffline:
            return "Ready to start"
        case .paused:
            return "Opening audio paused"
        case .failed:
            return "Live voice available"
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

    private var startupProgressDescription: String {
        let target = max(1, row.startupAudioTargetChunkCount)
        return "\(min(row.startupAudioCompletedChunkCount, target)) of \(target) chunks"
    }
}
