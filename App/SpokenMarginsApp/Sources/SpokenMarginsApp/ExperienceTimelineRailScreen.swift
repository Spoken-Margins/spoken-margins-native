import SwiftUI
import SessionKit
import SessionKitPersistence

struct ExperienceTimelineRailScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @EnvironmentObject private var sharingCoordinator: Build23SharingCoordinator
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openURL) private var openURL

    /// A playback pane reuses the rail and sheets, without a second player or navigation stack.
    var onReturnToPlayback: (() -> Void)? = nil
    var onEditorFocusChange: ((Bool) -> Void)? = nil
    /// The playback screen hides its dock while the editor has focus and brings it back after the keyboard leaves.
    var playbackDockHidden = false

    @State private var followsPlayback = true
    @State private var selectedSource: PlaybackTimelineSourceView.Selection?
    @State private var selectedElement: SourceElement?
    /// The table or figure picture open at full screen (#3895).
    @State private var selectedClip: TimelineClipSelection?
    /// Which rows of this item have a picture saved, from one listing of its clip folder.
    @State private var clipSource = TimelineClipSource.none
    /// Per item, the last answer to "are its notes read where they are cited" (#3777). A change of setting asks again.
    @State private var footnotesReadWhereCited: [String: Bool] = [:]
    @State private var selectedMargin: MarginRow?
    @State private var selectedSharedMargin: SharedMarginRow?
    @State private var entries: [TimelineRailEntry] = []
    /// Which chapters are folded (#3895): all but the playing one when the Timeline opens, then following playback
    /// unless the listener handled a chapter by hand (#4586). Kept for this item while the screen is open.
    @State private var folding = TimelineChapterFolding()
    @State private var playbackTick = 0 // bumped by each progress tick: the current row follows the playhead (#2074)
    @FocusState private var responseEditorFocused: Bool
    @State private var composerAnchor = TimelineComposerAnchor()
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
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
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
                        DisclosureGroup(FriendArrivalWords.sectionTitle(senderLabels: sharingCoordinator.importedLayers.map(\.senderLabel))) {
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
                        Button {
                            followsPlayback = true
                            focusTimeline(using: proxy)
                        } label: {
                            Label("Follow playback", systemImage: "location.fill").frame(minHeight: 44).contentShape(Rectangle())
                        }
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
            // A listing that just arrived: the rows of figures with a picture can now be made (#4587).
            .onChange(of: clipSource) { _, _ in
                rebuildRows(from: model.selectedItem)
            }
            // Pictures saved while this Timeline is open (an import just finished): list the folder again.
            .onReceive(NotificationCenter.default.publisher(for: PDFClipStore.didSaveClipsNotification)
                .receive(on: DispatchQueue.main)) { notice in
                if notice.userInfo?[PDFClipStore.itemIdKey] as? String == model.selectedItem.id {
                    refreshClips(for: model.selectedItem)
                }
            }
            .onChange(of: model.selectedItem.id) { _, _ in
                // A new item starts again: only its playing chapter open, no hand toggles carried over (#4586).
                folding = TimelineChapterFolding()
                refreshEntries(from: model.selectedItem)
                followsPlayback = true
                focusTimeline(using: proxy)
            }
            .onChange(of: currentEntryIDs) { _, _ in
                // Playback moved into another chapter: fold the one it left and open the one it entered, unless
                // the listener handled either by hand (#4586). The rail follow below reads the result.
                withMotion(.snappy) { folding.sync(rows: foldingRows, currentIDs: currentEntryIDs) }
            }
            .onChange(of: currentEntryID) { _, _ in
                guard onReturnToPlayback != nil && followsPlayback else { return }
                focusTimeline(using: proxy)
            }
            .onChange(of: model.requestedTimelineFocusMarginID) { _, id in
                if id != nil { focusTimeline(using: proxy) }
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting {
                    followsPlayback = false
                    composerAnchor.listenerScrolled()
                }
            }
            .onDisappear { onEditorFocusChange?(false) }
            .onChange(of: playbackDockHidden) { _, hidden in
                // The dock is back after the editor's keyboard left: keep the Reflect box and its Import button in
                // view above it, not behind it (#4043). Scroll again once the dock's inset is laid out. Only after
                // Done or Import from the box: focus also leaves when the listener drags up to read, or a row opens
                // a sheet, and the rail stays where they put it (#4047).
                guard !hidden, !responseEditorFocused, composerAnchor.dockReturned() else { return }
                scrollComposerIntoView(using: proxy)
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentInsets.bottom } action: { old, new in
                guard new > old, composerAnchor.dockInsetGrew() else { return }
                scrollComposerIntoView(using: proxy)
            }
            .onChange(of: responseEditorFocused) { _, isFocused in
                onEditorFocusChange?(isFocused)
                guard isFocused else { return }
                composerAnchor.editorGainedFocus()
                scrollComposerIntoView(using: proxy)
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
                    Image(systemName: "doc.text")
                        .frame(width: 44, height: 44)
                }
                // On the always-dark plate (embedded in Now Playing) the default tint is too dark in light mode (#3733).
                .tint(onReturnToPlayback != nil ? AppColors.listeningAccent : AppColors.evergreen)
                .accessibilityLabel("Export session")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    composerAnchor.editingEndedFromComposer()
                    responseEditorFocused = false
                }
                    .accessibilityIdentifier("timeline.keyboard.done")
            }
        }
        .trackedSheet(item: $selectedSource) { entry in
            PlaybackTimelineSourceView(selection: entry)
        }
        .trackedSheet(item: $selectedElement) { element in
            PlaybackTimelineElementView(element: element)
        }
        .trackedFullScreenCover(item: $selectedClip) { clip in
            TimelineClipViewer(selection: clip)
        }
        .trackedSheet(item: $selectedSharedMargin) { row in
            SharedMarginDetailView(row: row).environmentObject(model)
        }
        .trackedSheet(item: $selectedMargin) { row in
            ExperienceMarginDetailView(row: row)
                .environmentObject(model)
        }
    }

    private var timelineRail: some View {
        PlaybackTimelineListView(entries: entries, currentIDs: currentEntryIDs,
                                 folding: folding, toggleChapter: toggleChapter,
                                 currentPosition: currentPosition,
                                 perform: perform, openClip: openClip, details: details)
            .environment(\.timelineClips, clipSource)
    }

    private func openClip(_ entry: TimelineSourceContent.Entry) {
        guard let selection = TimelineClipSelection(entry: entry, source: clipSource) else { return }
        selectedClip = selection
    }

    private var foldingRows: [TimelineChapterFolding.Row] { entries.map(\.foldingRow) }

    /// The listener's place for the current card's line, while this item is the one playing (#3862).
    private var currentPosition: TimelineCurrentPosition? {
        Self.currentPosition(forItem: model.selectedItem, snapshot: model.snapshot)
    }

    /// Media: the clock and, with a known length, the percent (rounded down, as the Timeline's cards are, so 99.6% is 99%).
    /// Text: the percent the text scrubber prints, from the same function. Nil when another item is playing.
    static func currentPosition(forItem item: ItemDetailState, snapshot: SessionSnapshot) -> TimelineCurrentPosition? {
        guard let itemId = snapshot.itemId, itemId == item.id else { return nil }
        if item.isNativeAudio {
            guard let ms = snapshot.currentMediaTimeMs else { return nil }
            let duration = max(0, snapshot.currentPlaybackDurationMs ?? 0)
            return TimelineCurrentPosition(
                isMedia: true, ms: ms, percent: TimelinePositionLabel.mediaPercent(currentMs: ms, durationMs: duration))
        }
        // Another target (a spoken reply, a summary) counts characters in its own text, not the item's.
        guard snapshot.targetType == TargetType.itemTextTTS.rawValue,
              let offset = snapshot.currentTextStart, !item.text.isEmpty else { return nil }
        return TimelineCurrentPosition(
            isMedia: false, ms: nil,
            percent: TimelinePositionLabel.textScrubberPercent(offset: Double(offset), length: item.text.count))
    }

    private func toggleChapter(_ id: String) {
        // The listener is working the rail by hand: don't pull it back to the playing row under their finger.
        followsPlayback = false
        withMotion(.snappy) { folding.toggle(id, in: foldingRows) }
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
                    composerAnchor.editingEndedFromComposer()
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

    /// `footnotesReadWhereCited` is whether this item's narration is planned with its notes read where they are cited
    /// (`FootnotePlanDecision.asides`, which the screen asks off the main thread). Its default lists no footnote rows, so a
    /// caller that doesn't pass it gets the rail it always had (#3777).
    static func makeEntries(from item: ItemDetailState, sessionID: String?, playbackDurationMs: Int? = nil,
                            clips: TimelineClipSource = .none, footnotesReadWhereCited: Bool = false) -> [TimelineRailEntry] {
        var result: [TimelineRailEntry] = []
        let sourceLength = item.timelineSource.characterCount > 0 ? item.timelineSource.characterCount : item.text.count
        // A podcast or audio file speaks in clock time, like its scrubber; an article or PDF speaks in percent (#3862).
        let kind: TimelinePositionLabel.ItemKind = item.isNativeAudio ? .media : .text

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

        // A footnote the narrator reads where it is cited has a row at its citation: a tap goes to the note, reads it and goes
        // on after the sentence that cites it. Where the narration keeps the notes at the end ("Read at the end", a PDF, audio
        // prepared before notes were read where cited) they are in their own chapter, so there are no rows (#3777, Design PR 7).
        for note in FootnoteTimelineEntries.entries(for: item, readsWhereCited: footnotesReadWhereCited) {
            let position = TimelineRailSortKey.percent(position: note.citationStart, length: sourceLength) ?? 0
            result.append(TimelineRailEntry(
                id: note.id, position: Int(position.rounded()), rank: 0, provenance: .source,
                title: note.title, detail: note.detail, action: .footnote(note), precisePosition: position))
        }

        // A figure with no printed text of its own (a photo, a micrograph) has a row only when its picture was cut: the
        // row is the picture and its caption's first sentence (#4587). Ids like `float-p1-c1` repeat across PDFs, and the
        // rows can be rebuilt before the listing of the item just left is cleared, so a listing that isn't this item's
        // counts as none.
        let figureClips = clips.itemId == item.id ? clips : TimelineClipSource.none
        for entry in item.timelineSource.figures where figureClips.has(floatId: entry.floatId) {
            let position = Double(entry.start) / Double(max(1, item.timelineSource.characterCount)) * 100
            result.append(TimelineRailEntry(
                id: entry.id, position: Int(position.rounded()), rank: 0, provenance: .source,
                title: entry.label ?? "Figure",
                detail: TimelineTextPresentation.excerpt(entry.text, characterLimit: TimelineTextPresentation.supportingCharacterLimit),
                action: .sourceText(entry), precisePosition: position))
        }

        // Pictures, embeds and links the import kept from the page (#2032), at the place they sit in the text.
        for element in item.timelineSource.elements {
            let position = Double(element.start) / Double(max(1, item.timelineSource.characterCount)) * 100
            result.append(TimelineRailEntry(
                id: "source.element.\(element.id)", position: Int(position.rounded()), rank: 0, provenance: .source,
                // The kind and a link's host are the row's first line now (#4778), so the detail stays empty.
                title: element.label, detail: "",
                action: .sourceElement(element), precisePosition: position))
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
                    // The compact Beginning row shows the overview only when there is one (#4778).
                    detail: item.overview.isEmpty
                        ? ""
                        : TimelineTextPresentation.excerpt(
                            item.overview,
                            characterLimit: TimelineTextPresentation.supportingCharacterLimit
                        ),
                    action: .beginning,
                    positionLabel: TimelinePositionLabel.label(kind: kind, startMs: 0, percent: 0)
                )
            )
        }

        // A publisher's chapters are saved twice, with the same id: as a percent copy (`chapters`) and as a copy with the
        // exact start (`mediaChapters`). The rail draws the percent copy, so look the exact start up by id (#3862).
        let exactStartByChapterID = Dictionary(item.mediaChapters.map { ($0.id, $0.startMs) }, uniquingKeysWith: { first, _ in first })
        for chapter in item.chapters {
            // The place shows once, in the corner ("about 65%" when it is rough), so there is no detail line (#4778).
            let label = TimelinePositionLabel.chapterLabel(kind: kind, startMs: exactStartByChapterID[chapter.id], percent: chapter.percent)
            result.append(
                TimelineRailEntry(
                    id: "source.chapter.\(chapter.id)",
                    position: chapter.percent,
                    rank: 0,
                    provenance: .source,
                    title: chapter.title,
                    detail: "",
                    action: .chapter(chapter),
                    precisePosition: TimelineRailSortKey.percent(position: chapter.startChar, length: sourceLength),
                    positionLabel: label
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
                    detail: "",
                    action: .mediaChapter(chapter), precisePosition: TimelineRailSortKey.percent(position: chapter.startMs, length: knownDuration),
                    positionLabel: TimelinePositionLabel.chapterLabel(kind: kind, startMs: chapter.startMs, percent: position)
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
                // The time is in the corner already (#4778); "Generated scene" stays, it says the scene is machine-made.
                detail: "Generated scene" + (summary.map { " · \($0)" } ?? ""),
                action: .listeningMapScene(scene), precisePosition: TimelineRailSortKey.percent(position: scene.startMs, length: knownDuration),
                positionLabel: TimelinePositionLabel.label(kind: kind, startMs: scene.startMs, percent: position)
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
                    detail: "From \(row.collectionLabel) · \(row.positionDescription)",
                    action: .sharedMargin(row),
                    isNew: row.isNew,
                    precisePosition: TimelineRailSortKey.percent(position: margin.resolution.localMediaTimeMs ?? row.placementStatus.previousMediaTimeMs, length: knownDuration),
                    reference: .imported(margin.id),
                    // Only a Margin placed at a time shows one; a rough percent stays a percent (#3862).
                    positionLabel: TimelinePositionLabel.label(kind: kind, startMs: margin.resolution.localMediaTimeMs, percent: position)
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
                    detail: [row.cutShort?.tag, row.needsAttention ? row.attentionDescription
                        : MarginPlacePresentation.timelineDetail(for: row.interjection, position: position)].compactMap { $0 }.joined(separator: " · "),
                    action: .margin(row),
                    precisePosition: preciseSourcePosition(row.interjection, in: item, durationMs: knownDuration),
                    reference: .local(row.interjection.id),
                    // A Margin with no place (#4233) says so in the corner and sorts after the last placed entry.
                    positionLabel: row.interjection.hasPlace
                        ? TimelinePositionLabel.label(kind: kind, startMs: row.interjection.anchor.mediaTimeMs, percent: position)
                        : MarginPlacePresentation.timelineLabel
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
        rebuildRows(from: item)
        refreshClips(for: item)
        refreshFootnoteDecision(for: item)
    }

    private var footnoteMode: FootnoteMode {
        FootnoteMode(storedValue: UserDefaults.standard.string(forKey: FootnoteMode.storageKey))
    }

    /// Whether this item's notes are read where they are cited, as the plan decides it (#3777): the setting, a PDF, and audio
    /// already prepared with the notes at the end all count, so a row never promises a note the narrator will not read. The
    /// decision reads the item's summary and prepared-audio manifests, so it is made off the main thread and only for an item
    /// whose text has a note to read; until the answer arrives there are no footnote rows.
    private func refreshFootnoteDecision(for item: ItemDetailState) {
        let mode = footnoteMode
        guard mode.plansAsides, !item.isNativeAudio, item.documentStructure == nil,
              NarrationChunkPlanner.hasFootnotesToReadWhereCited(in: item.text), let store = model.store else { return }
        let itemId = item.id, text = item.text
        Task {
            let answer = try? await StoreReader(store).read { store -> Bool in
                guard let summary = try store.loadItemSummary(id: itemId) else { return false }
                return FootnotePlanDecision.asides(
                    mode: mode, isPDF: summary.mediaType == "pdf", articleText: text,
                    manifests: try store.loadPreparedAudioManifests(itemId: itemId))
            }
            // The listener may have moved to another item, or changed the setting, while the store was read.
            guard let answer, model.selectedItem.id == itemId, footnoteMode == mode,
                  footnotesReadWhereCited[itemId] != answer else { return }
            footnotesReadWhereCited[itemId] = answer
            rebuildRows(from: model.selectedItem)
        }
    }

    /// The rows from the item as it is and the pictures listed so far. Also runs when a listing arrives, so a figure's
    /// row appears then without another listing being started (#4587).
    private func rebuildRows(from item: ItemDetailState) {
        entries = Self.makeEntries(from: item, sessionID: model.snapshot.sessionId,
                                   playbackDurationMs: model.snapshot.currentPlaybackDurationMs, clips: clipSource,
                                   footnotesReadWhereCited: footnoteMode.plansAsides && footnotesReadWhereCited[item.id] == true)
        // Applies the starting state the first time the rail has chapters, and keeps folds in step with rows.
        folding.sync(rows: foldingRows, currentIDs: currentEntryIDs)
    }

    /// Which of the item's tables and figures have a picture: one listing of its folder, read off the main thread, and
    /// only for an item whose document located any, so a page or a podcast does no disk work here (#3895). Until the
    /// listing arrives the rows are their text, as they were before pictures existed.
    private func refreshClips(for item: ItemDetailState) {
        guard item.timelineSource.entries.contains(where: { $0.floatId != nil }) || !item.timelineSource.figures.isEmpty,
              let store = model.pdfClipStore() else {
            if clipSource != .none { clipSource = .none }
            return
        }
        let itemId = item.id
        // The rows are this item's now. Pictures listed for another item are not theirs: ids like `float-p1-1`
        // repeat across PDFs, so drop them until this item's own listing arrives.
        if clipSource.itemId != itemId, clipSource != .none { clipSource = .none }
        Task {
            let available = await Task.detached(priority: .utility) { store.available(forItem: itemId) }.value
            // The listener may have moved to another item while the folder was read.
            guard model.selectedItem.id == itemId else { return }
            let next = TimelineClipSource(store: store, itemId: itemId, available: available)
            if next != clipSource { clipSource = next }
        }
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
        struct Place { let order: Int; let depth: Int; let rootPosition: Int?; let rootPrecise: Double?; let rootLabel: TimelinePositionLabel.Label?; let parentLabel: String?; let note: String? }
        var places: [MarginReference: Place] = [:]
        var path: [String] = []
        var rootPosition: Int?
        var rootPrecise: Double?
        var rootLabel: TimelinePositionLabel.Label?
        for (index, row) in rows.enumerated() {
            if row.depth == 0 {
                rootPosition = roots[row.reference]?.position
                rootPrecise = roots[row.reference]?.precisePosition
                rootLabel = roots[row.reference]?.positionLabel
            }
            path = Array(path.prefix(row.depth))
            places[row.reference] = Place(
                order: index + 1, depth: row.depth, rootPosition: rootPosition, rootPrecise: rootPrecise, rootLabel: rootLabel,
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
                // A thread that starts with a Margin with no place (#4233) has no place to lend: a reply that has one stands
                // at its own, so its corner and its "Captured at" line agree.
                if let rootPosition = place.rootPosition, rootPosition != MarginPlacePresentation.timelineSortPosition {
                    threaded.depth = place.depth
                    threaded.position = rootPosition
                    // The sort key goes by the precise place first, so a reply takes its parent's exactly.
                    threaded.precisePosition = place.rootPrecise
                    // The corner says what `position` says: a reply reads as its parent's place, in the parent's unit (#3862).
                    threaded.positionLabel = place.rootLabel
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
            .map { MarginRow(interjection: $0, itemTitle: item.title, sessionDate: sessionDate, transcriptWaitsForAnswer: MarginRow.waitsForAnswer($0)) }
    }

    private static func preciseSourcePosition(_ margin: Interjection, in item: ItemDetailState, durationMs: Int?) -> Double? {
        // A Margin with no place (#4233) has no precise place: its `sortPercent` puts it after every placed entry.
        guard margin.hasPlace else { return nil }
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
        let sources = item.interjections.filter { $0.sessionId == turn.sessionId && sourceIDs.contains($0.id) }
        // A reflection on Margins that all have no place (#4233) sits with them, after every placed entry.
        if !sources.isEmpty, sources.allSatisfy({ $0.targetType == .item && !$0.hasPlace }) {
            return Double(MarginPlacePresentation.timelineSortPosition)
        }
        return sources
            // A source Margin with no place (#4233) says nothing about where the reflection belongs.
            .filter { $0.targetType != .item || $0.hasPlace }
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
        case .sourceElement(let element):
            // A link row is the link: one tap opens it (owner, 2026-11-14). Its details stay on long-press.
            if let url = element.linkDestination {
                openURL(url)
            } else {
                selectedElement = element
            }
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
        case .footnote(let note):
            model.playFootnote(label: note.label, fromTimeline: true)
        case .sharedMargin(let row):
            // #158: play the moment directly; details stay on long-press. A written Margin set not to be read aloud, or with
            // no voice on this phone (#3402), has nothing to play: when it has a place the tap goes there with no voice (#4934),
            // and when it has none it opens its details, where its words are (#3427).
            if row.layer.itemId != nil, SilentMarginWords.friendGoesTo(row.interjection, in: row.layer) {
                model.goToSharedMargin(row)
            } else if row.interjection.isWritten, !SharedMarginAudio.canOffer(row.interjection) {
                selectedSharedMargin = row
            } else {
                model.playSharedMarginMoment(row)
            }
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
        // The same on long-press and as a VoiceOver action, where the picture itself can't be tapped (#3895).
        if case .sourceText(let source) = action, clipSource.has(floatId: source.floatId) {
            Button(TimelineClipPresentation.viewActionTitle(kind: source.floatKind), systemImage: "photo") {
                openClip(source)
            }
        }
        if case .sourceElement(let element) = action, let url = element.linkDestination {
            Button("Link details", systemImage: "info.circle") { selectedElement = element }
            Button("Copy link", systemImage: "doc.on.doc") { UIPasteboard.general.url = url }
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
    /// The row to follow. A playing row folded away under a chapter is followed by showing that chapter (#3895).
    private var currentEntryID: String? {
        playbackSelection.focusID.map { folding.visibleID(for: $0, in: foldingRows) }
    }

    private func scrollComposerIntoView(using proxy: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            withMotion(.easeOut(duration: 0.2)) {
                proxy.scrollTo("timeline.reflection.composer", anchor: .bottom)
            }
        }
    }

    private func focusTimeline(using proxy: ScrollViewProxy) {
        guard !responseEditorFocused else { return }
        let requested = model.requestedTimelineFocusMarginID
        guard requested != nil || followsPlayback,
              let id = requested ?? currentEntryID ?? entries.first?.id else { return }
        if requested != nil {
            followsPlayback = false
            // A Margin the listener was taken to must be on screen, not folded away.
            if let requested { folding.reveal(requested, in: foldingRows) }
        }
        Task { @MainActor in
            await Task.yield()
            await Task.yield() // a row just unfolded needs a layout pass before it can be scrolled to
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

    private static func humanize(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

struct TimelineRailEntry: Identifiable, Equatable {
    enum Action: Equatable {
        case sourceText(TimelineSourceContent.Entry)
        case sourceElement(SourceElement)
        case beginning
        case chapter(Chapter)
        case mediaChapter(MediaTimelineChapter)
        case listeningMapScene(MediaTimelineChapter)
        /// A note read where it is cited (#3777).
        case footnote(FootnoteTimelineEntry)
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
    /// What the card's corner says about its place, in the item's own unit: a time on media where the entry has an exact one,
    /// otherwise a percent (#3862). Nil means the percent in `position`. `position` itself stays the sort coordinate.
    var positionLabel: TimelinePositionLabel.Label? = nil

    /// The card's corner: "1:07:30" or "65%".
    var cornerLabel: String { positionLabel?.corner ?? PlaybackPositionText.visible(percent: position) }
    /// The corner as VoiceOver reads it: "1 hour, 7 minutes, 30 seconds" or "65 percent".
    var spokenPosition: String { positionLabel?.spoken ?? PlaybackPositionText.spoken(percent: position) }

    var sortKey: TimelineRailSortKey {
        TimelineRailSortKey(position: position, rank: rank, threadOrder: threadOrder, id: id, precisePosition: precisePosition)
    }

    var provenanceLabel: String {
        if case .sourceText = action { return "Source" }
        if case .sourceElement(let element) = action { return element.kind.timelineName }
        if case .footnote = action { return "Footnote" }
        return provenance.label
    }

    /// The symbol beside the provenance label: a footnote has its own (Design, Screens), the rest follow their provenance.
    var provenanceSystemImage: String {
        if case .footnote = action { return "text.append" }
        return provenance.systemImage
    }

    var currentLabel: String {
        if case .sourceText = action { return "Current passage" }
        return "Current chapter"
    }

    /// How the row is drawn (#4778): chapters and the Beginning as compact headers, a page's links, pictures, embeds and
    /// tables as compact children, and every row that carries content in today's full card. Names every case on purpose,
    /// so a new kind of row has to choose.
    var rowRole: TimelineRowRole {
        switch action {
        case .chapter, .mediaChapter: .chapter
        case .beginning: .beginning
        case .sourceElement(let element): .sourceElement(kind: element.kind, linkHost: element.timelineLinkHost)
        case .sourceText, .footnote, .listeningMapScene, .margin, .sharedMargin, .turn, .turnChapter: .full
        }
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
        case .footnote(let note): "timeline.footnote.play.\(note.label)"
        case .beginning: "timeline.source.beginning"
        case .sourceText(let entry): "timeline.sourceText.\(entry.id)"
        case .sourceElement(let element): "timeline.sourceElement.\(element.id)"
        }
    }
}
