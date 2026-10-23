import SwiftUI
import SessionKit

struct ExperienceTimelineRailScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @EnvironmentObject private var sharingCoordinator: Build23SharingCoordinator
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// A playback pane reuses the rail and sheets, without a second player or navigation stack.
    var onReturnToPlayback: (() -> Void)? = nil
    var onEditorFocusChange: ((Bool) -> Void)? = nil

    @State private var followsPlayback = true
    @State private var selectedSource: PlaybackTimelineSourceView.Selection?
    @State private var selectedMargin: MarginRow?
    @State private var selectedSharedMargin: SharedMarginRow?
    @State private var entries: [TimelineRailEntry] = []
    @State private var playbackTick = 0 // bumped by each progress tick: the current row follows the playhead (#2074)
    @FocusState private var responseEditorFocused: Bool
    @ScaledMetric(relativeTo: .body) private var responseEditorHeight: CGFloat = 160

    var body: some View {
        let _ = playbackTick
        Group {
            if onReturnToPlayback != nil {
                content.environment(\.colorScheme, .dark)
            } else {
                NavigationStack {
                    content
                        .navigationTitle("Timeline")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
        .followsPlaybackClock(model.playbackClock, tick: $playbackTick)
    }

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.selectedItem.title)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 12)

                    if entries.isEmpty {
                        SMExperienceEmptyState(
                            systemImage: "list.bullet.rectangle",
                            title: "This session is just beginning",
                            detail: "Source positions, Margins, and reflections will appear here in listening order.",
                            actionTitle: "Return to \(model.timelineExitTitle)",
                            action: returnToPlayback
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
            .background(onReturnToPlayback == nil ? AppColors.bone : AppColors.listeningBackground)
            .safeAreaInset(edge: .top, spacing: 0) {
                if onReturnToPlayback != nil && !followsPlayback && !responseEditorFocused {
                    HStack {
                        Spacer()
                        Button("Follow playback", systemImage: "location.fill") {
                            followsPlayback = true
                            focusTimeline(using: proxy)
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("timeline.followPlayback.button")
                    }
                    .padding(.horizontal, 18)
                    .background(AppColors.listeningBackground)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 8) {
                if onReturnToPlayback == nil && model.shouldShowMiniPlayer && !responseEditorFocused {
                    MiniPlayerBar()
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)
                }
            }
            .onAppear {
                refreshEntries(from: model.selectedItem)
                focusTimeline(using: proxy)
            }
            .onReceive(model.$selectedItem) { item in
                refreshEntries(from: item)
            }
            .onChange(of: model.selectedItem.id) { _, _ in
                followsPlayback = true
                focusTimeline(using: proxy)
            }
            .onChange(of: currentEntryID) { _, _ in
                guard onReturnToPlayback != nil && followsPlayback else { return }
                focusTimeline(using: proxy)
            }
            .onChange(of: model.requestedTimelineFocusMarginID) { _, id in
                if id != nil { focusTimeline(using: proxy) }
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { followsPlayback = false }
            }
            .onDisappear { onEditorFocusChange?(false) }
            .onChange(of: responseEditorFocused) { _, isFocused in
                onEditorFocusChange?(isFocused)
                guard isFocused else { return }
                Task { @MainActor in
                    await Task.yield()
                    withMotion(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("timeline.reflection.composer", anchor: .bottom)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline.screen")
        .toolbar {
            if onReturnToPlayback == nil {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: returnToPlayback) {
                        Label(model.timelineExitTitle, systemImage: "arrow.left")
                    }
                    .accessibilityIdentifier("timeline.nowPlaying.button")
                }
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
        .sheet(item: $selectedSource) { entry in
            PlaybackTimelineSourceView(selection: entry)
        }
        .sheet(item: $selectedSharedMargin) { row in
            SharedMarginDetailView(row: row).environmentObject(model)
        }
        .sheet(item: $selectedMargin) { row in
            ExperienceMarginDetailView(row: row)
                .environmentObject(model)
        }
    }

    private var timelineRail: some View {
        PlaybackTimelineListView(entries: entries, currentIDs: currentEntryIDs,
                                 perform: perform, details: details)
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
                            .filledActionButton(tint: AppColors.plum)
                            .accessibilityIdentifier("timeline.summary.button")
                    }
                }
                Button("Import and play response", systemImage: "play.fill") {
                    responseEditorFocused = false
                    model.importPastedAssistantResponse()
                }
                .filledActionButton(tint: AppColors.plum)
                .disabled(model.pastedAssistantResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("timeline.reflection.import.button")
                TextEditor(text: $model.pastedAssistantResponse)
                    .frame(height: min(responseEditorHeight, 280))
                    .padding(8)
                    .inputEditorBackground()
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
        let sourceLength = item.timelineSource.characterCount > 0 ? item.timelineSource.characterCount : item.text.count

        // Paragraph following belongs to Now. Timeline keeps retained rich source elements
        // alongside actual chapter/scene boundaries, rather than inventing a row for every paragraph (#1624).
        let richSourceRoles: Set<StructuredDocument.Role> = [.caption, .table, .footnote, .reference, .figureText]
        for entry in item.timelineSource.entries where richSourceRoles.contains(entry.role) {
            let position = Double(entry.start) / Double(max(1, item.timelineSource.characterCount)) * 100
            result.append(TimelineRailEntry(
                id: entry.id, position: Int(position.rounded()), rank: 0, provenance: .source,
                title: entry.label ?? entry.role.timelineTitle,
                detail: TimelineTextPresentation.excerpt(entry.text, characterLimit: TimelineTextPresentation.supportingCharacterLimit),
                action: .sourceText(entry), precisePosition: position))
        }

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
                    action: .chapter(chapter),
                    precisePosition: TimelineRailSortKey.percent(position: chapter.startChar, length: sourceLength)
                )
            )
        }

        let knownDuration = (item.mediaDurationMs ?? playbackDurationMs).flatMap { $0 > 0 ? $0 : nil }
        let duration = knownDuration ?? 1
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
                    action: .mediaChapter(chapter), precisePosition: TimelineRailSortKey.percent(position: chapter.startMs, length: knownDuration)
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
                action: .listeningMapScene(scene), precisePosition: TimelineRailSortKey.percent(position: scene.startMs, length: knownDuration)
            ))
        }

        for layer in item.importedCommentaryLayers where layer.deletedAt == nil {
            for margin in item.importedCommentaryInterjections[layer.id, default: []] {
                let row = SharedMarginRow(interjection: margin, layer: layer, itemTitle: item.title, placement: item.sharedMarginPlacement)
                // A Margin being placed again stays at its old position until the pass writes the new one (#872).
                let position = (margin.resolution.localMediaTimeMs ?? row.placementStatus.previousMediaTimeMs).map {
                    max(0, min(100, Int((Double($0) / Double(duration) * 100).rounded())))
                } ?? margin.anchorEvidence.roughPercent ?? 100
                result.append(TimelineRailEntry(
                    id: "shared.\(row.id)", position: position, rank: 1,
                    provenance: .sharedMargin,
                    title: TimelineTextPresentation.excerpt(margin.approvedTranscript, characterLimit: TimelineTextPresentation.marginCharacterLimit),
                    detail: "Shared by \(row.collectionLabel) · \(row.positionDescription)",
                    action: .sharedMargin(row),
                    isNew: row.isNew,
                    precisePosition: TimelineRailSortKey.percent(position: margin.resolution.localMediaTimeMs ?? row.placementStatus.previousMediaTimeMs, length: knownDuration),
                    reference: .imported(margin.id)
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
                    action: .margin(row),
                    precisePosition: preciseSourcePosition(row.interjection, in: item, durationMs: knownDuration),
                    reference: .local(row.interjection.id)
                )
            )
        }
        result = threadingReplies(in: result, item: item)

        var children: [String: [TimelineRailEntry]] = [:]
        for (turnIndex, turn) in item.turns.enumerated() {
            let position = turnPosition(turn, in: item, durationMs: knownDuration, visited: [])
            let provenance: TimelineProvenance = turn.role == "user" ? .userResponse : .assistantResponse
            result.append(
                TimelineRailEntry(
                    id: "turn.\(turn.id)",
                    position: Int(position.rounded()),
                    rank: 2 + turnIndex * 10,
                    provenance: provenance,
                    title: turn.role == "user" ? "My response" : "Assistant response",
                    detail: TimelineTextPresentation.excerpt(
                        turn.summary ?? turn.text ?? humanize(turn.status),
                        characterLimit: TimelineTextPresentation.supportingCharacterLimit
                    ),
                    action: .turn(turn), precisePosition: position
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

    /// Replies sit directly under the Margin they answer, indented, at that Margin's place on the rail (#473).
    /// The thread is the one `MarginThreadPresentation` builds for the Margins list, so both screens agree.
    static func threadingReplies(in entries: [TimelineRailEntry], item: ItemDetailState) -> [TimelineRailEntry] {
        guard entries.contains(where: { $0.reference != nil }) else { return entries }
        let rows = MarginThreadPresentation.rows(
            itemId: item.id,
            localMargins: item.interjections,
            layers: item.importedCommentaryLayers,
            importedMargins: item.importedCommentaryLayers.flatMap { item.importedCommentaryInterjections[$0.id, default: []] }
        )
        let roots = Dictionary(entries.compactMap { entry in entry.reference.map { ($0, entry) } }, uniquingKeysWith: { first, _ in first })
        struct Place { let order: Int; let depth: Int; let rootPosition: Int?; let rootPrecise: Double?; let parentLabel: String?; let note: String? }
        var places: [MarginReference: Place] = [:]
        var path: [String] = []
        var rootPosition: Int?
        var rootPrecise: Double?
        for (index, row) in rows.enumerated() {
            if row.depth == 0 {
                rootPosition = roots[row.reference]?.position
                rootPrecise = roots[row.reference]?.precisePosition
            }
            path = Array(path.prefix(row.depth))
            places[row.reference] = Place(
                order: index + 1, depth: row.depth, rootPosition: rootPosition, rootPrecise: rootPrecise,
                parentLabel: row.depth > 0 ? path.last : nil, note: row.note
            )
            path.append(row.senderLabel)
        }
        return entries.map { entry in
            guard let place = entry.reference.flatMap({ places[$0] }) else { return entry }
            var threaded = entry
            threaded.threadOrder = place.order
            if place.depth > 0 {
                // The rail shows one session's Margins. A reply whose thread starts with a Margin that has no entry
                // here (an earlier session's) has nothing to indent under: it stands at its own place, and still
                // says what it answers.
                if let rootPosition = place.rootPosition {
                    threaded.depth = place.depth
                    threaded.position = rootPosition
                    // The sort key goes by the precise place first, so a reply takes its parent's exactly.
                    threaded.precisePosition = place.rootPrecise
                }
                threaded.detail = "Reply to \(place.parentLabel ?? "a Margin") · \(entry.detail)"
            } else if let note = place.note {
                threaded.detail = "\(note.prefix(1).uppercased())\(note.dropFirst()) · \(entry.detail)"
            }
            return threaded
        }
    }

    private static func currentSessionMargins(in item: ItemDetailState, sessionID: String?) -> [MarginRow] {
        let sessionDate = item.sessions.first(where: { $0.id == sessionID })?.updatedAt
        return item.interjections
            .filter { $0.status == "active" && (sessionID == nil || $0.sessionId == sessionID) }
            .map { MarginRow(interjection: $0, itemTitle: item.title, sessionDate: sessionDate) }
    }

    private static func preciseSourcePosition(_ margin: Interjection, in item: ItemDetailState, durationMs: Int?) -> Double? {
        if item.isNativeAudio {
            return TimelineRailSortKey.percent(position: margin.anchor.mediaTimeMs, length: durationMs)
        }
        guard margin.anchor.endChar > margin.anchor.startChar else { return nil }
        let length = item.timelineSource.characterCount > 0 ? item.timelineSource.characterCount : item.text.count
        return TimelineRailSortKey.percent(position: margin.anchor.startChar, length: length)
    }

    private static func turnPosition(_ turn: ConversationTurn, in item: ItemDetailState, durationMs: Int?,
                                     visited: Set<String>) -> Double {
        guard !visited.contains(turn.id) else { return 100 }
        let visited = visited.union([turn.id])
        let sourceIDs = Set(turn.sourceInterjectionIds)
        return item.interjections
            .filter { $0.sessionId == turn.sessionId && sourceIDs.contains($0.id) }
            .map { margin in
                if margin.targetType == .item {
                    return preciseSourcePosition(margin, in: item, durationMs: durationMs)
                        ?? Double(InterjectionPositionPresentation.sortPercent(for: margin, durationMs: item.mediaDurationMs))
                }
                guard let parent = item.turns.first(where: { $0.id == margin.targetId }) else { return 100 }
                return turnPosition(parent, in: item, durationMs: durationMs, visited: visited)
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
        case .sourceText(let entry):
            selectedSource = .init(entry: entry, sourceReference: model.selectedItem.externalReference)
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

    /// Resolve against displayed rows, not every retained paragraph. The full source lookup also
    /// prevents an earlier caption from claiming a body passage or whitespace gap after it (#1624).
    static func selectionForPlayback(
        entries: [TimelineRailEntry], item: ItemDetailState, snapshot: SessionSnapshot,
        isCurrent: (TimelineRailEntry.Action) -> Bool
    ) -> (currentIDs: Set<String>, focusID: String?) {
        let sourceID: String?
        if snapshot.itemId == item.id, snapshot.targetType == TargetType.itemTextTTS.rawValue,
           let offset = snapshot.currentTextStart,
           let source = item.timelineSource.entry(atCharacter: offset),
           offset < source.start + source.text.count,
           entries.contains(where: { entry in
               guard case .sourceText = entry.action else { return false }
               return entry.id == source.id
           }) {
            sourceID = source.id
        } else {
            sourceID = nil
        }
        let currentIDs = Set(entries.filter { entry in
            if case .sourceText = entry.action { return entry.id == sourceID }
            return isCurrent(entry.action)
        }.map(\.id))
        return (currentIDs, sourceID ?? entries.first(where: { currentIDs.contains($0.id) })?.id ?? entries.first?.id)
    }

    private var playbackSelection: (currentIDs: Set<String>, focusID: String?) {
        Self.selectionForPlayback(entries: entries, item: model.selectedItem, snapshot: model.snapshot, isCurrent: isCurrent)
    }

    private var currentEntryIDs: Set<String> { playbackSelection.currentIDs }
    private var currentEntryID: String? { playbackSelection.focusID }

    private func focusTimeline(using proxy: ScrollViewProxy) {
        guard !responseEditorFocused else { return }
        let requested = model.requestedTimelineFocusMarginID
        guard requested != nil || followsPlayback,
              let id = requested ?? currentEntryID ?? entries.first?.id else { return }
        if requested != nil { followsPlayback = false }
        Task { @MainActor in
            await Task.yield()
            guard !responseEditorFocused else { return }
            withMotion(.snappy) { proxy.scrollTo(id, anchor: .center) }
            if model.requestedTimelineFocusMarginID == requested {
                model.requestedTimelineFocusMarginID = nil
            }
        }
    }

    private func returnToPlayback() {
        responseEditorFocused = false
        withMotion(.snappy(duration: 0.34)) {
            if let onReturnToPlayback { onReturnToPlayback() } else { model.leaveTimeline() }
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
        case sourceText(TimelineSourceContent.Entry)
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
    var position: Int
    let rank: Int
    let provenance: TimelineProvenance
    let title: String
    var detail: String
    let action: Action
    /// A shared Margin the listener hasn't heard yet (#469).
    var isNew = false
    var precisePosition: Double? = nil
    /// The Margin this entry shows, when it is one that can be part of a conversation (#473).
    var reference: MarginReference? = nil
    /// 0 for a Margin that starts a conversation, 1 for a reply to it, and so on.
    var depth = 0
    /// Where the entry falls among the Margins at one place: a conversation in order, parent first.
    var threadOrder = 0

    var sortKey: TimelineRailSortKey {
        TimelineRailSortKey(position: position, rank: rank, threadOrder: threadOrder, id: id, precisePosition: precisePosition)
    }

    var provenanceLabel: String {
        if case .sourceText = action { return "Source" }
        return provenance.label
    }

    var currentLabel: String {
        if case .sourceText = action { return "Current passage" }
        return "Current chapter"
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
        case .sourceText(let entry): "timeline.sourceText.\(entry.id)"
        }
    }
}
