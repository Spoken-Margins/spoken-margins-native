import SwiftUI
import SessionKit

struct ExperienceTimelineRailScreen: View {
    @EnvironmentObject private var model: Gate1AppModel

    @State private var selectedMargin: MarginRow?
    @State private var entries: [TimelineRailEntry] = []
    @FocusState private var responseEditorFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ExperienceEditorialHeader(
                            eyebrow: "Listening session",
                            title: "Timeline",
                            detail: model.selectedItem.title
                        )
                        .padding(.bottom, 24)

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

                        reflectionComposer
                            .padding(.top, 24)
                            .id("timeline.reflection.composer")
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 22)
                    .padding(.bottom, model.shouldShowMiniPlayer ? 132 : 28)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .background(AppColors.bone)
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
                    isFirst: index == 0,
                    isLast: index == entries.count - 1,
                    action: { perform(entry.action) }
                )
                .id(entry.id)
                .accessibilityIdentifier(entry.accessibilityIdentifier)
            }
        }
        .accessibilityIdentifier("timeline.rail")
    }

    private var reflectionComposer: some View {
        ExperienceSurface(tint: AppColors.plum.opacity(0.4)) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Reflect on this session", systemImage: "sparkles")
                        .font(.headline)
                        .foregroundStyle(AppColors.plum)
                    Spacer()
                    if model.canSummarizeInterjections {
                        Button(model.canRetryLocalSummary ? "Retry summary" : "Summarize", action: model.summarize)
                            .buttonStyle(.borderedProminent)
                            .tint(AppColors.plum)
                            .accessibilityIdentifier("timeline.summary.button")
                    }
                }
                Text("On-device summaries and pasted responses are labeled as reflections; they never replace your Margins.")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
                TextEditor(text: $model.pastedAssistantResponse)
                    .frame(minHeight: 80)
                    .padding(8)
                    .background(AppColors.inputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 12).stroke(AppColors.border) }
                    .focused($responseEditorFocused)
                    .accessibilityLabel("Paste assistant response")
                    .accessibilityIdentifier("timeline.reflection.editor")
                Button("Import pasted response", systemImage: "plus") {
                    responseEditorFocused = false
                    model.importPastedAssistantResponse(autoPlay: false)
                }
                .buttonStyle(.bordered)
                .disabled(model.pastedAssistantResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("timeline.reflection.import.button")
            }
        }
    }

    private func makeEntries(from item: ItemDetailState) -> [TimelineRailEntry] {
        var result: [TimelineRailEntry] = []

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

        let duration = max(1, item.mediaDurationMs ?? model.snapshot.currentPlaybackDurationMs ?? 1)
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

        for row in currentSessionMargins(in: item) {
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

        for (turnIndex, turn) in item.turns.enumerated() {
            let position = turnPosition(turn, in: item)
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
            for (chapterIndex, chapter) in (turn.chapters ?? []).enumerated() {
                result.append(
                    TimelineRailEntry(
                        id: "turnChapter.\(turn.id).\(chapter.id)",
                        position: position,
                        rank: 3 + turnIndex * 10 + chapterIndex,
                        provenance: provenance,
                        title: chapter.title,
                        detail: "Within \(turn.role == "user" ? "my response" : "assistant response") · \(chapter.percent)%",
                        action: .turnChapter(turn, chapter)
                    )
                )
            }
        }

        return result.sorted { $0.sortKey < $1.sortKey }
    }

    private func refreshEntries(from item: ItemDetailState) {
        entries = makeEntries(from: item)
    }

    private func currentSessionMargins(in item: ItemDetailState) -> [MarginRow] {
        let sessionID = model.snapshot.sessionId
        let sessionDate = item.sessions.first(where: { $0.id == sessionID })?.updatedAt
        return item.interjections
            .filter { $0.status == "active" && (sessionID == nil || $0.sessionId == sessionID) }
            .map { MarginRow(interjection: $0, itemTitle: item.title, sessionDate: sessionDate) }
    }

    private func turnPosition(_ turn: ConversationTurn, in item: ItemDetailState) -> Int {
        let sourceIDs = Set(turn.sourceInterjectionIds)
        return item.interjections
            .filter { sourceIDs.contains($0.id) }
            .map(\.roughPercent)
            .max() ?? 100
    }

    private func perform(_ action: TimelineRailEntry.Action) {
        switch action {
        case .beginning:
            if let first = model.selectedItem.chapters.first {
                model.jumpToChapter(first, fromTimeline: true)
            } else if let first = model.selectedItem.mediaChapters.first {
                model.jumpToMediaChapter(first, fromTimeline: true)
            } else {
                model.openPlayback()
            }
        case .chapter(let chapter):
            model.jumpToChapter(chapter, fromTimeline: true)
        case .mediaChapter(let chapter):
            model.jumpToMediaChapter(chapter, fromTimeline: true)
        case .margin(let row):
            model.recordTimelineInterjectionViewed(interjectionId: row.interjection.id)
            selectedMargin = row
        case .turn(let turn):
            model.playTurn(turn, fromTimeline: true)
        case .turnChapter(let turn, let chapter):
            model.jumpToTurnChapter(turn: turn, chapter: chapter, fromTimeline: true)
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

    private func formatTime(_ milliseconds: Int) -> String {
        let seconds = max(0, milliseconds / 1_000)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func humanize(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private struct TimelineRailEntry: Identifiable {
    enum Action {
        case beginning
        case chapter(Chapter)
        case mediaChapter(MediaTimelineChapter)
        case margin(MarginRow)
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

    var sortKey: TimelineRailSortKey {
        TimelineRailSortKey(position: position, rank: rank, id: id)
    }

    var accessibilityIdentifier: String {
        switch action {
        case .margin(let row): "timeline.interjection.\(row.interjection.id)"
        case .turn(let turn): "timeline.turn.play.\(turn.id)"
        case .turnChapter(let turn, let chapter): "timeline.turnChapter.jump.\(turn.id).\(chapter.id)"
        case .chapter(let chapter): "timeline.chapter.jump.\(chapter.id)"
        case .mediaChapter(let chapter): "timeline.mediaChapter.jump.\(chapter.id)"
        case .beginning: "timeline.source.beginning"
        }
    }
}

private struct TimelineRailRow: View {
    let entry: TimelineRailEntry
    let isFirst: Bool
    let isLast: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
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

            Button(action: action) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline) {
                        Label(entry.provenance.label.uppercased(), systemImage: entry.provenance.systemImage)
                            .font(.caption2.weight(.bold))
                            .tracking(0.8)
                            .foregroundStyle(provenanceColor)
                        Spacer()
                        Text("\(entry.position)%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    Text(entry.title)
                        .font(.headline)
                        .foregroundStyle(AppColors.text)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                    Text(entry.detail)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                        .multilineTextAlignment(.leading)
                        .lineLimit(4)
                }
                .padding(15)
                .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
                .background(surfaceColor)
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
        .accessibilityLabel("\(entry.provenance.label), \(entry.position) percent. \(entry.title). \(entry.detail)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }

    @ViewBuilder
    private var provenanceMarker: some View {
        switch entry.provenance {
        case .source:
            Circle().fill(provenanceColor).frame(width: 13, height: 13)
        case .myMargin:
            RoundedRectangle(cornerRadius: 2).fill(provenanceColor).frame(width: 13, height: 13).rotationEffect(.degrees(45))
        case .userResponse:
            Circle().stroke(provenanceColor, lineWidth: 3).frame(width: 14, height: 14)
        case .assistantResponse:
            Image(systemName: "sparkle").font(.caption.bold()).foregroundStyle(provenanceColor)
        }
    }

    private var provenanceColor: Color {
        switch entry.provenance {
        case .source: AppColors.evergreen
        case .myMargin: AppColors.coral
        case .userResponse: AppColors.ochre
        case .assistantResponse: AppColors.plum
        }
    }

    private var surfaceColor: Color {
        switch entry.provenance {
        case .source: AppColors.panel
        case .myMargin: AppColors.coral.opacity(0.08)
        case .userResponse: AppColors.ochre.opacity(0.08)
        case .assistantResponse: AppColors.plum.opacity(0.07)
        }
    }
}
