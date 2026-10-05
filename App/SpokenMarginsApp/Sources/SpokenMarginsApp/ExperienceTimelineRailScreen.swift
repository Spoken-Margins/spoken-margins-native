import SwiftUI
import SessionKit

struct ExperienceTimelineRailScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @EnvironmentObject private var sharingCoordinator: Build23SharingCoordinator
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var selectedMargin: MarginRow?
    @State private var selectedSharedMargin: SharedMarginRow?
    @State private var entries: [TimelineRailEntry] = []
    @FocusState private var responseEditorFocused: Bool
    @ScaledMetric(relativeTo: .body) private var responseEditorHeight: CGFloat = 160

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.selectedItem.title)
                            .font(.subheadline)
                            .foregroundStyle(AppColors.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 12)

                        if entries.isEmpty {
                            SMExperienceEmptyState(
                                systemImage: "list.bullet.rectangle",
                                title: "This session is just beginning",
                                detail: "Source positions, Margins, and reflections will appear here in listening order.",
                                actionTitle: "Return to Now Playing",
                                action: model.openPlayback
                            )
                        } else {
                            timelineRail
                        }

                        if !sharingCoordinator.importedLayers.isEmpty {
                            DisclosureGroup("Shared Margins") {
                                Build23ImportedMarginPresentation(coordinator: sharingCoordinator, showsMargins: false)
                            }
                            .padding(.top, 16)
                        }

                        reflectionComposer
                            .padding(.top, 24)
                            .id("timeline.reflection.composer")
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 28)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .background(AppColors.bone)
                .safeAreaInset(edge: .bottom, spacing: 8) {
                    if model.shouldShowMiniPlayer && !responseEditorFocused {
                        MiniPlayerBar()
                            .padding(.horizontal, 12)
                            .padding(.bottom, 4)
                    }
                }
                .onAppear {
                    refreshEntries(from: model.selectedItem)
                    focusRequestedMargin(using: proxy)
                }
                .onReceive(model.$selectedItem) { item in
                    refreshEntries(from: item)
                }
                .onChange(of: responseEditorFocused) { _, isFocused in
                    guard isFocused else { return }
                    Task { @MainActor in
                        await Task.yield()
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("timeline.reflection.composer", anchor: .bottom)
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("timeline.screen")
            .navigationTitle("Timeline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: returnToPlayback) {
                        Label("Now Playing", systemImage: "arrow.left")
                    }
                    .accessibilityIdentifier("timeline.nowPlaying.button")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: model.openExport) {
                        Image(systemName: "square.and.arrow.up")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Export session")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { responseEditorFocused = false }
                        .accessibilityIdentifier("timeline.keyboard.done")
                }
            }
            .sheet(item: $selectedSharedMargin) { row in
                SharedMarginDetailView(row: row).environmentObject(model)
            }
            .sheet(item: $selectedMargin) { row in
                ExperienceMarginDetailView(row: row)
                    .environmentObject(model)
            }
        }
    }

    private var timelineRail: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                TimelineRailRow(
                    entry: entry,
                    isCurrent: isCurrent(entry.action),
                    isFirst: index == 0,
                    isLast: index == entries.count - 1,
                    action: { perform(entry.action) }
                )
                .equatable()
                .contextMenu { details(for: entry.action) }
                .id(entry.id)
                .accessibilityIdentifier(entry.accessibilityIdentifier)
            }
        }
        .accessibilityIdentifier("timeline.rail")
    }

    private var reflectionComposer: some View {
        ExperienceSurface(tint: AppColors.plum.opacity(0.4)) {
            VStack(alignment: .leading, spacing: 12) {
                (dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                    : AnyLayout(HStackLayout())) {
                    Label("Reflect on this session", systemImage: "sparkles")
                        .font(.headline)
                        .foregroundStyle(AppColors.plum)
                    if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                    if model.canSummarizeInterjections {
                        Button(model.canRetryLocalSummary ? "Retry summary" : "Summarize", action: model.summarize)
                            .buttonStyle(.borderedProminent)
                            .tint(AppColors.plum)
                            .accessibilityIdentifier("timeline.summary.button")
                    }
                }
                Button("Import and play response", systemImage: "play.fill") {
                    responseEditorFocused = false
                    model.importPastedAssistantResponse()
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.plum)
                .foregroundStyle(AppColors.onEvergreen)
                .disabled(model.pastedAssistantResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("timeline.reflection.import.button")
                TextEditor(text: $model.pastedAssistantResponse)
                    .frame(height: min(responseEditorHeight, 280))
                    .padding(8)
                    .background(AppColors.inputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 12).stroke(AppColors.border) }
                    .focused($responseEditorFocused)
                    .accessibilityLabel("Paste assistant response")
                    .accessibilityIdentifier("timeline.reflection.editor")
            }
        }
    }

    static func makeEntries(from item: ItemDetailState, sessionID: String?, playbackDurationMs: Int? = nil) -> [TimelineRailEntry] {
        var result: [TimelineRailEntry] = []

        let sourceAlreadyStartsAtBeginning = item.chapters.contains { $0.percent == 0 }
            || item.mediaChapters.contains { $0.startMs == 0 }
        if !sourceAlreadyStartsAtBeginning {
            result.append(
                TimelineRailEntry(
                    id: "source.beginning",
                    position: 0,
                    rank: 0,
                    provenance: .source,
                    title: "Beginning",
                    detail: item.overview.isEmpty
                        ? "Start of source"
                        : TimelineTextPresentation.excerpt(
                            item.overview,
                            characterLimit: TimelineTextPresentation.supportingCharacterLimit
                        ),
                    action: .beginning
                )
            )
        }

        for chapter in item.chapters {
            result.append(
                TimelineRailEntry(
                    id: "source.chapter.\(chapter.id)",
                    position: chapter.percent,
                    rank: 0,
                    provenance: .source,
                    title: chapter.title,
                    detail: "Chapter · \(chapter.percent)%",
                    action: .chapter(chapter)
                )
            )
        }

        let duration = max(1, item.mediaDurationMs ?? playbackDurationMs ?? 1)
        let sourceChapterIDs = Set(item.chapters.map(\.id))
        for chapter in item.mediaChapters where !sourceChapterIDs.contains(chapter.id) {
            let position = max(0, min(100, Int((Double(chapter.startMs) / Double(duration) * 100).rounded())))
            result.append(
                TimelineRailEntry(
                    id: "source.mediaChapter.\(chapter.id)",
                    position: position,
                    rank: 0,
                    provenance: .source,
                    title: chapter.title,
                    detail: "Chapter · \(formatTime(chapter.startMs))",
                    action: .mediaChapter(chapter)
                )
            )
        }

        for scene in item.listeningMapScenes {
            let position = max(0, min(100, Int((Double(scene.startMs) / Double(duration) * 100).rounded())))
            let summary = scene.description.map {
                TimelineTextPresentation.excerpt($0, characterLimit: TimelineTextPresentation.supportingCharacterLimit)
            }
            result.append(TimelineRailEntry(
                id: "source.listeningMapScene.\(scene.id)", position: position, rank: 0,
                provenance: .listeningMap, title: scene.title,
                detail: "Generated scene · \(formatTime(scene.startMs))" + (summary.map { " · \($0)" } ?? ""),
                action: .listeningMapScene(scene)
            ))
        }

        for layer in item.importedCommentaryLayers where layer.deletedAt == nil {
            for margin in item.importedCommentaryInterjections[layer.id, default: []] {
                let row = SharedMarginRow(interjection: margin, layer: layer, itemTitle: item.title)
                let position = margin.resolution.localMediaTimeMs.map {
                    max(0, min(100, Int((Double($0) / Double(duration) * 100).rounded())))
                } ?? margin.anchorEvidence.roughPercent ?? 100
                result.append(TimelineRailEntry(
                    id: "shared.\(row.id)", position: position, rank: 1,
                    provenance: .sharedMargin,
                    title: TimelineTextPresentation.excerpt(margin.approvedTranscript, characterLimit: TimelineTextPresentation.marginCharacterLimit),
                    detail: "Shared by \(row.collectionLabel) · \(row.positionDescription)",
                    action: .sharedMargin(row),
                    isNew: row.isNew
                ))
            }
        }

        let margins = currentSessionMargins(in: item, sessionID: sessionID)
        for row in margins where row.interjection.targetType == .item {
            let position = InterjectionPositionPresentation.sortPercent(
                for: row.interjection,
                durationMs: item.mediaDurationMs
            )
            result.append(
                TimelineRailEntry(
                    id: row.id,
                    position: position,
                    rank: 1,
                    provenance: .myMargin,
                    title: TimelineTextPresentation.excerpt(
                        row.preview,
                        characterLimit: TimelineTextPresentation.marginCharacterLimit
                    ),
                    detail: row.needsAttention ? row.attentionDescription : "Captured at \(position)%",
                    action: .margin(row)
                )
            )
        }

        var children: [String: [TimelineRailEntry]] = [:]
        for (turnIndex, turn) in item.turns.enumerated() {
            let position = turnPosition(turn, in: item, visited: [])
            let provenance: TimelineProvenance = turn.role == "user" ? .userResponse : .assistantResponse
            result.append(
                TimelineRailEntry(
                    id: "turn.\(turn.id)",
                    position: position,
                    rank: 2 + turnIndex * 10,
                    provenance: provenance,
                    title: turn.role == "user" ? "My response" : "Assistant response",
                    detail: TimelineTextPresentation.excerpt(
                        turn.summary ?? turn.text ?? humanize(turn.status),
                        characterLimit: TimelineTextPresentation.supportingCharacterLimit
                    ),
                    action: .turn(turn)
                )
            )
            for chapter in turn.chapters ?? [] {
                children[turn.id, default: []].append(
                    TimelineRailEntry(
                        id: "turnChapter.\(turn.id).\(chapter.id)",
                        position: chapter.percent,
                        rank: 0,
                        provenance: provenance,
                        title: chapter.title,
                        detail: "Within \(turn.role == "user" ? "my response" : "assistant response") · \(chapter.percent)%",
                        action: .turnChapter(turn, chapter)
                    )
                )
            }
        }

        // Derivative positions are local to their turn. Insert those rows after
        // their parent, never into the source's percentage coordinate space.
        for row in margins where row.interjection.targetType != .item {
            let position = InterjectionPositionPresentation.sortPercent(for: row.interjection, durationMs: nil)
            let parentExists = item.turns.contains { $0.id == row.interjection.targetId }
            let entry = TimelineRailEntry(
                id: row.id, position: position, rank: 1, provenance: .myMargin,
                title: TimelineTextPresentation.excerpt(row.preview, characterLimit: TimelineTextPresentation.marginCharacterLimit),
                detail: "Within \(row.targetDescription.lowercased()) · \(position)%" + (parentExists ? "" : " · Response unavailable"),
                action: .margin(row)
            )
            children[row.interjection.targetId, default: []].append(entry)
        }
        var ordered: [TimelineRailEntry] = []
        for entry in result.sorted(by: { $0.sortKey < $1.sortKey }) {
            ordered.append(entry)
            if case .turn(let turn) = entry.action {
                ordered.append(contentsOf: (children.removeValue(forKey: turn.id) ?? []).sorted { $0.sortKey < $1.sortKey })
            }
        }
        // Preserve recoverable notes whose parent is unavailable, without
        // pretending their positions describe the original source.
        for id in children.keys.sorted() {
            ordered.append(contentsOf: children[id, default: []].sorted { $0.sortKey < $1.sortKey })
        }
        return ordered
    }

    private func refreshEntries(from item: ItemDetailState) {
        entries = Self.makeEntries(from: item, sessionID: model.snapshot.sessionId, playbackDurationMs: model.snapshot.currentPlaybackDurationMs)
    }

    private static func currentSessionMargins(in item: ItemDetailState, sessionID: String?) -> [MarginRow] {
        let sessionDate = item.sessions.first(where: { $0.id == sessionID })?.updatedAt
        return item.interjections
            .filter { $0.status == "active" && (sessionID == nil || $0.sessionId == sessionID) }
            .map { MarginRow(interjection: $0, itemTitle: item.title, sessionDate: sessionDate) }
    }

    private static func turnPosition(_ turn: ConversationTurn, in item: ItemDetailState, visited: Set<String>) -> Int {
        guard !visited.contains(turn.id) else { return 100 }
        let visited = visited.union([turn.id])
        let sourceIDs = Set(turn.sourceInterjectionIds)
        return item.interjections
            .filter { $0.sessionId == turn.sessionId && sourceIDs.contains($0.id) }
            .map { margin in
                if margin.targetType == .item {
                    return InterjectionPositionPresentation.sortPercent(for: margin, durationMs: item.mediaDurationMs)
                }
                guard let parent = item.turns.first(where: { $0.id == margin.targetId }) else { return 100 }
                return turnPosition(parent, in: item, visited: visited)
            }.max() ?? 100
    }

    private func isCurrent(_ action: TimelineRailEntry.Action) -> Bool {
        guard model.snapshot.itemId == model.selectedItem.id else { return false }
        switch action {
        case .chapter(let chapter): return model.isCurrentTimelineChapter(chapter)
        case .mediaChapter(let chapter): return model.isCurrentTimelineMediaChapter(chapter)
        case .listeningMapScene(let scene): return model.isCurrentTimelineListeningMapScene(scene)
        case .turnChapter(let turn, let chapter): return model.isCurrentTimelineChapter(chapter, turnId: turn.id)
        default: return false
        }
    }

    private func perform(_ action: TimelineRailEntry.Action) {
        switch action {
        case .beginning:
            if let first = model.selectedItem.chapters.first {
                model.jumpToChapter(first, fromTimeline: true)
            } else if let first = model.selectedItem.mediaChapters.first {
                model.jumpToMediaChapter(first, fromTimeline: true)
            } else {
                model.playSourceFromBeginning(fromTimeline: true)
            }
        case .chapter(let chapter):
            model.jumpToChapter(chapter, fromTimeline: true)
        case .mediaChapter(let chapter):
            model.jumpToMediaChapter(chapter, fromTimeline: true)
        case .listeningMapScene(let scene):
            model.jumpToListeningMapScene(scene, fromTimeline: true)
        case .sharedMargin(let row):
            // #158: play the moment directly; details stay on long-press.
            model.playSharedMarginMoment(row)
        case .margin(let row):
            model.recordTimelineInterjectionViewed(interjectionId: row.interjection.id)
            selectedMargin = row
        case .turn(let turn):
            model.playTurn(turn, fromTimeline: true)
        case .turnChapter(let turn, let chapter):
            model.jumpToTurnChapter(turn: turn, chapter: chapter, fromTimeline: true)
        }
    }

    @ViewBuilder
    private func details(for action: TimelineRailEntry.Action) -> some View {
        if case .sharedMargin(let row) = action {
            Button("Shared Margin details", systemImage: "info.circle") { selectedSharedMargin = row }
        }
    }

    private func focusRequestedMargin(using proxy: ScrollViewProxy) {
        guard let id = model.requestedTimelineFocusMarginID else { return }
        DispatchQueue.main.async {
            withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) }
            model.requestedTimelineFocusMarginID = nil
        }
    }

    private func returnToPlayback() {
        responseEditorFocused = false
        withAnimation(.snappy(duration: 0.34)) {
            model.openPlayback()
        }
    }

    private static func formatTime(_ milliseconds: Int) -> String {
        let seconds = max(0, milliseconds / 1_000)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private static func humanize(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

struct TimelineRailEntry: Identifiable, Equatable {
    enum Action: Equatable {
        case beginning
        case chapter(Chapter)
        case mediaChapter(MediaTimelineChapter)
        case listeningMapScene(MediaTimelineChapter)
        case margin(MarginRow)
        case sharedMargin(SharedMarginRow)
        case turn(ConversationTurn)
        case turnChapter(ConversationTurn, Chapter)
    }

    let id: String
    let position: Int
    let rank: Int
    let provenance: TimelineProvenance
    let title: String
    let detail: String
    let action: Action
    /// A shared Margin the listener hasn't heard yet (#469).
    var isNew = false

    var sortKey: TimelineRailSortKey {
        TimelineRailSortKey(position: position, rank: rank, id: id)
    }

    var accessibilityIdentifier: String {
        switch action {
        case .sharedMargin(let row): "timeline.sharedMargin.\(row.id)"
        case .margin(let row): "timeline.interjection.\(row.interjection.id)"
        case .turn(let turn): "timeline.turn.play.\(turn.id)"
        case .turnChapter(let turn, let chapter): "timeline.turnChapter.jump.\(turn.id).\(chapter.id)"
        case .chapter(let chapter): "timeline.chapter.jump.\(chapter.id)"
        case .mediaChapter(let chapter): "timeline.mediaChapter.jump.\(chapter.id)"
        case .listeningMapScene(let scene): "timeline.listeningMapScene.jump.\(scene.id)"
        case .beginning: "timeline.source.beginning"
        }
    }
}

private struct TimelineRailRow: View, Equatable {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entry: TimelineRailEntry
    let isCurrent: Bool
    let isFirst: Bool
    let isLast: Bool
    let action: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry == rhs.entry && lhs.isCurrent == rhs.isCurrent && lhs.isFirst == rhs.isFirst && lhs.isLast == rhs.isLast
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if !dynamicTypeSize.isAccessibilitySize {
                ZStack(alignment: .top) {
                    Rectangle()
                        .fill(AppColors.border)
                        .frame(width: 2)
                        .padding(.top, isFirst ? 22 : 0)
                        .padding(.bottom, isLast ? 44 : 0)
                    provenanceMarker
                        .padding(.top, 20)
                }
                .frame(width: 30)
            }

            Button(action: action) {
                VStack(alignment: .leading, spacing: 7) {
                    (dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                        : AnyLayout(HStackLayout(alignment: .firstTextBaseline))) {
                        Label(dynamicTypeSize.isAccessibilitySize ? entry.provenance.label : entry.provenance.label.uppercased(), systemImage: entry.provenance.systemImage)
                            .font(.caption2.weight(.bold))
                            .tracking(dynamicTypeSize.isAccessibilitySize ? 0 : 0.8)
                            .foregroundStyle(provenanceColor)
                            .fixedSize(horizontal: false, vertical: true)
                        if entry.isNew { NewMarginBadge() }
                        if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                        Text("\(entry.position)%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    if isCurrent {
                        Label("Current chapter", systemImage: "speaker.wave.2.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppColors.evergreen)
                    }
                    Text(entry.title)
                        .font(.headline)
                        .foregroundStyle(AppColors.text)
                        .multilineTextAlignment(.leading)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                    Text(entry.detail)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                        .multilineTextAlignment(.leading)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 4)
                }
                .padding(15)
                .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
                .background(isCurrent ? AppColors.evergreen.opacity(0.14) : surfaceColor)
                .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .stroke(provenanceColor.opacity(entry.provenance == .assistantResponse ? 0.55 : 0.24), style: StrokeStyle(lineWidth: 1, dash: entry.provenance == .assistantResponse ? [5, 4] : []))
                }
            }
            .buttonStyle(.plain)
            .padding(.bottom, 12)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isCurrent ? "Current chapter. " : "")\(entry.isNew ? "New to you. " : "")\(entry.provenance.label), \(entry.position) percent. \(entry.title). \(entry.detail)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }

    @ViewBuilder
    private var provenanceMarker: some View {
        switch entry.provenance {
        case .source:
            Circle().fill(provenanceColor).frame(width: 13, height: 13)
        case .listeningMap:
            Image(systemName: "map").font(.caption.bold()).foregroundStyle(provenanceColor)
        case .myMargin:
            RoundedRectangle(cornerRadius: 2).fill(provenanceColor).frame(width: 13, height: 13).rotationEffect(.degrees(45))
        case .userResponse:
            Circle().stroke(provenanceColor, lineWidth: 3).frame(width: 14, height: 14)
        case .sharedMargin:
            Image(systemName: "person.2.fill").font(.caption.bold()).foregroundStyle(provenanceColor)
        case .assistantResponse:
            Image(systemName: "sparkle").font(.caption.bold()).foregroundStyle(provenanceColor)
        }
    }

    private var provenanceColor: Color {
        switch entry.provenance {
        case .source, .listeningMap: AppColors.evergreen
        case .myMargin: AppColors.coral
        case .userResponse: AppColors.ochre
        case .sharedMargin, .assistantResponse: AppColors.plum
        }
    }

    private var surfaceColor: Color {
        switch entry.provenance {
        case .source: AppColors.panel
        case .listeningMap: AppColors.evergreen.opacity(0.07)
        case .myMargin: AppColors.coral.opacity(0.08)
        case .userResponse: AppColors.ochre.opacity(0.08)
        case .sharedMargin, .assistantResponse: AppColors.plum.opacity(0.07)
        }
    }
}
