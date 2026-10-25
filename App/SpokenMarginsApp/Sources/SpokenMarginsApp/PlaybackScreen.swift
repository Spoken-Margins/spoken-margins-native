import SwiftUI
import SessionKit
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

struct PlaybackScrubState: Equatable {
    private(set) var draftValue = 0.0
    private(set) var isEditing = false
    private var hasPendingValue = false

    mutating func begin(at canonicalValue: Double, range: ClosedRange<Double>) {
        guard !isEditing else { return }
        if !hasPendingValue { draftValue = Self.clamped(canonicalValue, to: range) }
        isEditing = true
    }

    mutating func updateFromGesture(_ value: Double, range: ClosedRange<Double>) {
        // Binding writes may arrive both before begin and after finish. Only
        // editing callbacks own the gesture; a late write must never freeze
        // subsequent canonical playback ticks.
        hasPendingValue = true
        draftValue = Self.clamped(value, to: range)
    }

    mutating func finish() {
        isEditing = false
        hasPendingValue = false
    }

    func displayedValue(canonicalValue: Double, range: ClosedRange<Double>) -> Double {
        Self.clamped(isEditing ? draftValue : canonicalValue, to: range)
    }

    private static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        max(range.lowerBound, min(value, range.upperBound))
    }
}

struct PlaybackScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedPane: PlaybackPane = .now
    @State private var isTimelineEditing = false
    @State private var followUp = ""
    @State private var selectedInterjection: Interjection?
    @State private var isPastingAssistantResponse = false
    @State private var mediaScrubState = PlaybackScrubState()
    @State private var textScrubState = PlaybackScrubState()
    @State private var isSleepTimerPresented = false
    @State private var sourceTextTarget: PlaybackTextReaderTarget?
    @State private var isPlaybackOptionsPresented = false
    @State private var pendingOptionsDestination: OptionsDestination?
    @Environment(\.openURL) private var openURL

    private enum OptionsDestination { case item, timeline, export, margins, paste, sourceText }
    @State private var timelinePullTriggered = false
    @State private var playbackTick = 0 // bumped by each progress tick, so this screen follows the clock (#2074)
    @AppStorage("playbackUsesVerboseActions") private var usesVerbosePlaybackActions = true
    @FocusState private var followUpFocused: Bool

    /// Back to the Library while playback goes on. The Library label lower down stays; this one is where a listener
    /// looks first. On Now it sits in line with the title, so the screen gets no taller (#2262).
    private var libraryExitButton: some View {
        Button(action: model.openLibrary) {
            Image(systemName: "chevron.left").font(.body.weight(.semibold)).minimumTapTarget()
        }
        .accessibilityLabel("Library")
        .accessibilityHint("Leaves this screen. Playback keeps going.")
        .accessibilityIdentifier("playback.exit.button")
    }

    var body: some View {
        let _ = playbackTick
        NavigationStack {
            ScrollViewReader { proxy in
                ZStack {
                    AppColors.listeningBackground.ignoresSafeArea()
                    Group {
                        switch selectedPane {
                        case .now:
                            ScrollView {
                                VStack(alignment: .leading, spacing: 20) {
                                    if model.snapshot.phase == .finished {
                                        Text("Finished").font(.headline).foregroundStyle(AppColors.listeningAccent)
                                    }
                                    // Keep the promised Margin visible before the large source header (#1577).
                                    marginMomentControl
                                    playbackHeader
                                    capturePermissionRecovery
                                    importedCommentaryControl
                                    if model.selectedItem.isNativeAudio {
                                        PlaybackNowView()
                                    } else {
                                        PlaybackLivePassageView { offset in
                                            sourceTextTarget = PlaybackTextReaderTarget.resolve(
                                                text: model.selectedItem.text,
                                                chapters: model.selectedItem.chapters,
                                                offset: offset,
                                                fallbackChapterId: model.currentChapter?.id
                                            )
                                        }
                                        recentMarginPreview
                                    }
                                    if model.shouldShowGuidedOnboardingCoach {
                                        GuidedOnboardingPlaybackCard {
                                            openTimeline()
                                        }
                                    }
                                }
                                .padding(.horizontal, horizontalSizeClass == .regular ? 36 : 22)
                                .padding(.vertical, 18)
                                .frame(maxWidth: 620)
                                .frame(maxWidth: .infinity, alignment: .top)
                            }
                            .scrollBounceBehavior(.always)
                            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                                // ScrollGeometry's container is the inset content viewport.
                                // The offset calculation below expects the whole viewport.
                                TimelinePullPresentation.overscrollDistance(
                                    contentOffsetY: geometry.contentOffset.y,
                                    contentHeight: geometry.contentSize.height,
                                    containerHeight: geometry.containerSize.height
                                        + geometry.contentInsets.top + geometry.contentInsets.bottom,
                                    bottomInset: geometry.contentInsets.bottom,
                                    topInset: geometry.contentInsets.top
                                )
                            } action: { _, distance in
                                if distance < 1 {
                                    timelinePullTriggered = false
                                } else if TimelinePullPresentation.shouldOpenTimeline(overscrollDistance: distance),
                                          !timelinePullTriggered {
                                    timelinePullTriggered = true
                                    openTimeline()
                                }
                            }

                        case .timeline:
                            ExperienceTimelineRailScreen(
                                onReturnToPlayback: { selectedPane = .now },
                                onEditorFocusChange: { isTimelineEditing = $0 }
                            )
                        case .margins:
                            PlaybackMarginsView()
                        }
                    }
                    // Pinned above every pane, not inside the Now pane's scrolling header: a failure about this
                    // listen hides the top banner, so the tag must stay in sight on Timeline and Margins too (#430).
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if !model.recordingNavigationIsLocked, let feedback = model.playbackFeedbackTag {
                            PlaybackFeedbackTagView(event: feedback.event, tag: feedback.tag)
                                .padding(.horizontal, horizontalSizeClass == .regular ? 36 : 22)
                                .frame(maxWidth: 620)
                                .frame(maxWidth: .infinity)
                                .background(AppColors.listeningBackground)
                        }
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if !isTimelineEditing { playbackControls }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("playback.screen")
                .announcesScreenChange()
                .onChange(of: model.marginMoment?.target.marginId) { _, target in
                    if target != nil { selectedPane = .now }
                }
                .task(id: model.renderFrontierKey) { await model.observeRenderedFrontier() }
                .task(id: "\(model.snapshot.itemId ?? "")|\(model.snapshot.status.rawValue)") {
                    guard model.snapshot.status == .starting, let id = model.snapshot.itemId,
                          model.selectedPodcastDownloadState != nil else { return }
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    model.stopStalledPodcastStart(itemID: id)
                }
                .onCompatibleChange(of: model.guidedOnboardingStage) { stage in
                    if stage == .reviewTimeline {
                        withMotion {
                            proxy.scrollTo("playback.timeline", anchor: .top)
                        }
                    }
                }
            }
            .toolbarBackground(AppColors.listeningBackground, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                if selectedPane == .timeline {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { selectedPane = .now } label: {
                            Label("Now Playing", systemImage: "arrow.left")
                        }
                        .accessibilityIdentifier("timeline.nowPlaying.button")
                    }
                } else if selectedPane == .margins {
                    ToolbarItem(placement: .topBarLeading) { libraryExitButton }
                }
                if selectedPane != .timeline {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { followUpFocused = false }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .sheet(item: $selectedInterjection) { interjection in
                ExperienceMarginDetailView(row: MarginRow(interjection: interjection, itemTitle: model.selectedItem.title, sessionDate: nil))
                    .environmentObject(model)
            }
            .sheet(isPresented: $isPastingAssistantResponse) {
                PastedAssistantResponseView(isPresented: $isPastingAssistantResponse)
                    .environmentObject(model)
            }
            .sheet(item: $sourceTextTarget) { target in
                NativeTextPeekView(
                    title: model.selectedItem.title, target: target,
                    text: model.selectedItem.text, chapters: model.selectedItem.chapters
                )
            }
            .sheet(isPresented: $isPlaybackOptionsPresented, onDismiss: performPendingOptionsNavigation) {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            playbackRateControl
                            mixedAudioControl
                            PlaybackFollowOptionsView()
                            PlaybackPreparedAudioView(
                                fraction: model.renderedFractionForPlayback,
                                isNativeAudio: model.selectedItem.isNativeAudio
                            )
                            onDeviceSpeechGenerationControl
                            reflectionOptions
                            conversation
                            sessionActionDock
                        }
                        .padding(20)
                    }
                    .background(AppColors.listeningBackground)
                    .navigationTitle("Listening options")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isPlaybackOptionsPresented = false }
                        }
                    }
                }
                .preferredColorScheme(.dark)
                .presentationDetents([.medium, .large])
            }
        }
        .followsPlaybackClock(model.playbackClock, tick: $playbackTick)
    }

    /// Spacing only is tightened (owner, 2026-10-13): the rows, their order and their controls stay as approved, so
    /// the dock is about 40% of a 6.1-inch phone and still leaves the Now pane half of an iPhone SE (#1475).
    private var playbackControls: some View {
        // The scrubber's 44 pt bar reaches into the gaps either side of it (`PlaybackPositionSlider.rowGapOverlap`).
        VStack(spacing: PlaybackPositionSlider.rowGapOverlap) {
            PlaybackPaneSwitchView(selection: $selectedPane)
                .id("playback.timeline")
            PlaybackChapterRowView(
                title: model.playbackChapterHeaderTitle,
                sourceTitle: model.playbackItemHeaderTitle,
                backward: model.chapterRowBackwardControl,
                forward: model.chapterRowForwardControl,
                skimBackwardTitle: model.skimBackwardTitle,
                skimForwardTitle: model.skimForwardTitle,
                skimForwardUnavailable: model.skimBridge.forwardUnavailableReason,
                skimLocked: model.snapshot.isRecording,
                waitingText: model.snapshot.status == .starting
                    ? PlaybackStartWatch.waitingText(isMedia: model.isMediaPlaybackSnapshot) : nil,
                showItem: model.openCurrentPlaybackItem,
                nextChapter: model.nextChapterFromChapterRow,
                skimBackward: model.skimBackward,
                skimForward: model.skimForward
            )
            playbackPosition
            playbackTransport
            // These are plain buttons, which take taps only on what they draw, and the speed and More frames sat
            // outside their buttons: each was a target the size of its word (#430). The 44 pt target is the label's.
            PlaybackSecondaryControlsRow {
                Button(action: model.openLibrary) {
                    if dynamicTypeSize.isAccessibilitySize {
                        Image(systemName: "books.vertical").minimumTapTarget()
                    } else {
                        Text("Library").minimumTapTarget()
                    }
                }
                .accessibilityLabel("Library")
                .accessibilityIdentifier("playback.home.button")
                Button(action: model.cyclePlaybackRate) {
                    Text(model.compactPlaybackRateDescription).minimumTapTarget()
                }
                .accessibilityLabel("Playback speed, \(model.compactPlaybackRateDescription)")
                .accessibilityIdentifier("playback.rate.button")
                listeningOptionsButton
            }
            .foregroundStyle(.white)
            .buttonStyle(.plain)
            if model.playingImportedCommentary != nil {
                Button(action: model.returnToSourceFromImportedCommentary) {
                    Text("Return to Source").frame(maxWidth: .infinity)
                }
                .buttonStyle(InterjectButtonStyle())
                .accessibilityIdentifier("importedCommentary.returnToSource")
            } else if model.snapshot.skimBridgeState != nil {
                Button {
                    model.returnFromSkim()
                } label: {
                    Text("Return to Source").frame(maxWidth: .infinity)
                }
                .buttonStyle(InterjectButtonStyle())
                .accessibilityIdentifier("playback.skim.return.button")
            } else if model.snapshot.phase == .finished {
                // #142: the same spoken + written row as during playback, so the flow is
                // finish, add a recap Margin, then Share.
                marginRow
                Button(action: model.openExport) {
                    Label("Share", systemImage: "square.and.arrow.up").minimumTapTarget()
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .accessibilityIdentifier("playback.finished.share.button")
            } else {
                marginRow
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
        .background(AppColors.listeningBackground)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.18)).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("playback.controls")
        .boundedScrollDock(dynamicTypeSize.isAccessibilitySize)
    }

    /// Add a Margin (spoken) with the pencil (written) beside it.
    private var marginRow: some View {
        HStack(spacing: 8) {
            Button(action: model.beginInterjection) {
                Label(dynamicTypeSize.isAccessibilitySize ? "Record" : "Add a Margin", systemImage: "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(InterjectButtonStyle())
            .accessibilityLabel("Record a Margin")
            .accessibilityIdentifier("playback.interject.button")
            Button(action: model.beginWrittenMargin) {
                Image(systemName: "square.and.pencil")
                    .resizable()
                    .scaledToFit()
                    .frame(width: dynamicTypeSize.isAccessibilitySize ? 32 : 24, height: dynamicTypeSize.isAccessibilitySize ? 32 : 24)
                    .frame(width: 52, height: 52)
            }
            .buttonStyle(InterjectButtonStyle())
            .accessibilityLabel("Write a Margin")
            .accessibilityIdentifier("playback.write.button")
        }
        .disabled(!model.hasActiveSession)
    }

    private var listeningOptionsButton: some View {
        Button {
            isPlaybackOptionsPresented = true
        } label: {
            if dynamicTypeSize.isAccessibilitySize {
                Image(systemName: "ellipsis").frame(minWidth: 52, minHeight: 52).contentShape(Rectangle())
            } else {
                Label("More", systemImage: "ellipsis").minimumTapTarget()
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("More listening options")
        .accessibilityIdentifier("playback.options.button")
    }

    @ViewBuilder
    private var recentMarginPreview: some View {
        let notes = model.selectedItem.interjections.filter { $0.status == "active" }.suffix(2)
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recent Margins")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.watchSecondary)
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array(notes)) { note in
                    Button { selectedInterjection = note } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(InterjectionPositionPresentation.detailDescription(for: note, durationMs: model.snapshot.currentPlaybackDurationMs))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(AppColors.watchSecondary)
                            Text(PlaybackMarginPreview.text(displayText: note.displayText,
                                                            cleanedTranscript: note.cleanedTranscript,
                                                            transcript: note.transcript,
                                                            transcriptionStatus: note.transcriptionStatus,
                                                            captureKind: note.captureKind))
                                .font(.system(.body, design: .serif))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.leading)
                                .lineLimit(3)
                        }
                        .padding(.leading, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .leading) { Rectangle().fill(AppColors.captureBackground).frame(width: 2) }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var reflectionOptions: some View {
        if model.aiSummaryExperienceAvailable {
            Button(action: model.summarize) {
                Label(model.summaryActionTitle, systemImage: "sparkles")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(!model.canSummarizeInterjections || model.isSummarizingInterjections)
            .accessibilityIdentifier("playback.summary.button")
        }
        if model.remoteProviderExperienceEnabled {
            TextField("Ask about this session", text: $followUp, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .focused($followUpFocused)
            Button("Discuss", systemImage: "bubble.left.and.bubble.right") {
                followUpFocused = false
                model.discuss(followUp: followUp)
            }
            .disabled(!model.hasActiveSession || followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("playback.discuss.button")
        }
        Button("Margins", systemImage: "quote.bubble") {
            closeOptions(to: .margins)
        }
        .frame(minHeight: 44)
    }

    private var sessionActionDock: some View {
        HStack(spacing: 8) {
            Button {
                closeOptions(to: .item)
            } label: {
                Image(systemName: "doc.text")
                    .frame(width: 48, height: 48)
            }
            .accessibilityLabel("Item")
            .accessibilityIdentifier("playback.item.button")

            Button(action: openTimeline) {
                Label("Timeline", systemImage: "list.bullet.rectangle")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .accessibilityIdentifier("playback.timeline.button")

            Button {
                closeOptions(to: .export)
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 48, height: 48)
            }
            .disabled(!model.hasActiveSession)
            .accessibilityLabel("Export")
            .accessibilityIdentifier("playback.export.button")
        }
        .font(.subheadline.weight(.semibold))
        .buttonStyle(.bordered)
        .tint(.white)
        .foregroundStyle(.white)
        .padding(8)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func openTimeline() {
        if isPlaybackOptionsPresented {
            closeOptions(to: .timeline)
            return
        }
        selectedPane = .timeline
    }

    private func closeOptions(to destination: OptionsDestination) {
        pendingOptionsDestination = destination
        isPlaybackOptionsPresented = false
    }

    private func performPendingOptionsNavigation() {
        guard let destination = pendingOptionsDestination else { return }
        pendingOptionsDestination = nil
        switch destination {
        case .item: model.openCurrentPlaybackItem()
        case .timeline: openTimeline()
        case .export: model.openExport()
        case .margins: model.openMargins()
        case .paste: isPastingAssistantResponse = true
        case .sourceText: openSourceText()
        }
    }

    /// #1547: the button sits in the More sheet, so close it first, then resolve the playhead when the
    /// reader opens. The target is the sheet's item, so the reader can't open with a stale offset.
    private func openSourceText() {
        if isPlaybackOptionsPresented {
            closeOptions(to: .sourceText)
            return
        }
        sourceTextTarget = PlaybackTextReaderTarget.resolve(
            text: model.selectedItem.text,
            chapters: model.selectedItem.chapters,
            offset: model.snapshot.currentTextStart,
            fallbackChapterId: model.currentChapter?.id
        )
    }

    @ViewBuilder
    private var capturePermissionRecovery: some View {
        if model.recordingPermissionDenied {
            VStack(alignment: .leading, spacing: 10) {
                Label("Microphone access is unavailable", systemImage: "mic.slash")
                    .font(.headline)
                Text("You can write a Margin, or enable microphone access in Settings.")
                    .font(.subheadline)
                ViewThatFits(in: .horizontal) {
                    HStack { permissionRecoveryActions }
                    VStack(alignment: .leading) { permissionRecoveryActions }
                }
            }
            .foregroundStyle(.white)
            .padding(16)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private var permissionRecoveryActions: some View {
        Button("Write instead", systemImage: "square.and.pencil", action: model.beginWrittenMargin)
            .accessibilityIdentifier("playback.permission.write.button")
        Button("Open Settings", systemImage: "gearshape") {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        }
    }

    private var timelineLaunchCard: some View {
        ProductPanel {
            VStack(alignment: .leading, spacing: 12) {
                Label("Timeline", systemImage: "list.bullet.rectangle")
                    .font(.system(.title2, design: .serif).weight(.semibold))
                Text("Review source structure, your Margins, and eligible session reflections without crowding the listening controls.")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
                Button(action: { model.openTimeline() }) {
                    Label("Open Timeline", systemImage: "arrow.right")
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("timeline.section")
            }
        }
    }

    /// What the shared Margin's voice is doing, from the player's own report (#941).
    @ViewBuilder
    private var importedCommentaryStatus: some View {
        switch model.importedCommentaryPhase {
        case .loading:
            Label("Loading Margin…", systemImage: "hourglass")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.72))
                .accessibilityIdentifier("importedCommentary.status.loading")
        case .playing:
            Label("Playing at \(model.playingInterjectionAudioRate.formatted(.number.precision(.fractionLength(0...2))))× to match the item", systemImage: "waveform")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.72))
                .accessibilityIdentifier("importedCommentary.status.playing")
        case .paused:
            Label("Paused", systemImage: "pause.fill")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.72))
                .accessibilityIdentifier("importedCommentary.status.paused")
        case .failed:
            VStack(spacing: 8) {
                Label("Margin audio could not play", systemImage: "exclamationmark.triangle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("importedCommentary.status.failed")
                Button("Retry", systemImage: "arrow.clockwise", action: model.retryImportedCommentary)
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("importedCommentary.retry")
            }
        }
    }

    @ViewBuilder
    private var importedCommentaryControl: some View {
        if let playing = model.playingImportedCommentary {
            VStack(spacing: 8) {
                Text(playing.senderLabel)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Shared Margin \(playing.index) of \(playing.count)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
                importedCommentaryStatus
                Text(playing.interjection.approvedTranscript)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(3)

            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
        } else if let pending = model.pendingImportedCommentary {
            VStack(spacing: 8) {
                Text(pending.senderLabel)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Shared Margin \(pending.index) of \(pending.count)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
                Text(pending.interjection.approvedTranscript)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(3)
                VStack(spacing: 10) {
                    Button("Listen", action: model.listenToPendingImportedCommentary)
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityIdentifier("importedCommentary.listen")
                    Button("Dismiss", action: model.dismissPendingImportedCommentary)
                        .buttonStyle(SecondaryButtonStyle())
                        .accessibilityIdentifier("importedCommentary.dismiss")
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
        }
        if model.hasEnabledImportedCommentary {
            Toggle(
                "Auto-play shared Margins",
                isOn: Binding(
                    get: { model.importedCommentaryAutoPlayEnabled },
                    set: { enabled in
                        model.setImportedCommentaryAutoPlayEnabled(enabled)
                    }
                )
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .tint(AppColors.accent)
            .padding(.horizontal, 4)
            .accessibilityIdentifier("importedCommentary.autoPlay")
        }

    }

    /// "Play this moment" (#159): the lead-in countdown with a way to skip it, then the Margin playing inline.
    @ViewBuilder
    private var marginMomentControl: some View {
        if let moment = model.marginMoment, moment.isReview {
            ReviewNewMarginsCard(moment: moment)
        } else if let moment = model.marginMoment {
            VStack(alignment: .leading, spacing: 10) {
                // A shared Margin still being placed says so for the whole moment (#872); it plays from its
                // approximate time meanwhile.
                if let placing = model.sharedMarginRows.first(where: { $0.id == moment.target.marginId })?
                    .placementStatus.positionDescription {
                    Text(placing)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .accessibilityIdentifier("marginMoment.placing")
                }
                if moment.isPlayingMargin {
                    Label(model.marginMomentVoiceIsPaused ? "\(model.marginMomentTitle) is paused" : "Playing \(model.marginMomentTitle)",
                          systemImage: "waveform")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Button("Skip to the item", systemImage: "forward.end.fill", action: model.skipMarginMomentVoice)
                        .buttonStyle(SecondaryButtonStyle())
                        .accessibilityIdentifier("marginMoment.skip")
                } else if let countdown = moment.targetCountdown(currentMediaTimeMs: model.marginMomentPositionMs) {
                    Label("\(model.marginMomentTitle) in \(countdown)", systemImage: "text.bubble")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .numericTextTransition()
                        .accessibilityIdentifier("marginMoment.countdown")
                    if model.marginMomentPositionIsApproximate {
                        Text("Approximate position: ads can differ between copies.")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    Button("Play it now", systemImage: "play.fill", action: model.playMarginMomentNow)
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityIdentifier("marginMoment.playNow")
                } else {
                    Text("Your Margins play as you reach them.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                }
                if !moment.isPlayingMargin {
                    Button(moment.phase == .leadIn ? "Cancel" : "Stop playing my Margins", action: model.endMarginMoment)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("marginMoment.end")
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .contain)
        }
    }

    private var playbackHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 4) {
                libraryExitButton
                PlaybackSourceTitleView(
                    title: model.playbackItemHeaderTitle,
                    sleepTimerState: model.sleepTimerState,
                    sleepTimerRemainingSeconds: model.sleepTimerRemainingSeconds,
                    showItem: model.openCurrentPlaybackItem
                )
            }

            if model.selectedItem.isNativeAudio,
               let show = model.libraryItems.first(where: { $0.id == model.selectedItem.id })?.sourceTitle,
               !show.isEmpty {
                Text(show)
                    .font(.subheadline)
                    .foregroundStyle(AppColors.watchSecondary)
                    .accessibilityIdentifier("playback.showTitle")
            }

            PlaybackMarginTranscriptionStatusView(status: PlaybackMarginTranscriptionStatus(
                selectedItemId: model.selectedItem.id,
                playingItemId: model.snapshot.itemId,
                sessionId: model.snapshot.sessionId,
                interjections: model.selectedItem.interjections,
                isRetrying: model.isRetryingInterjectionTranscription
            ))

            // The chapter title is not repeated here: the dock's chapter row, right above the bar, already shows it
            // and opens the same item details (#1475).
        }
        .accessibilityIdentifier("playback.title")
    }

    @ViewBuilder
    private var playbackPosition: some View {
        if model.isMediaPlaybackSnapshot, mediaDurationMs > 0 {
            HStack(spacing: 8) {
                Text(formatPlaybackTime(Int(scrubberDisplaySeconds * 1_000)))
                    .frame(minWidth: 36, alignment: .trailing)
                    .accessibilityIdentifier("playback.progress.label")
                PlaybackPositionSlider(
                    value: Binding(
                        get: { mediaScrubState.displayedValue(canonicalValue: canonicalMediaSeconds, range: mediaScrubRange) },
                        set: {
                            mediaScrubState.updateFromGesture($0, range: mediaScrubRange)
                            model.recordDeveloperDiagnostic("scrub.media.drag", ["value": String($0), "canonical": String(canonicalMediaSeconds), "range": String(mediaScrubRange.upperBound)])
                        }
                    ),
                    range: mediaScrubRange,
                    onEditingChanged: { editing in
                        model.recordDeveloperDiagnostic("scrub.media.editing", ["editing": String(editing)])
                        if editing {
                            mediaScrubState.begin(at: canonicalMediaSeconds, range: mediaScrubRange)
                        } else {
                            let targetSeconds = mediaScrubState.displayedValue(
                                canonicalValue: canonicalMediaSeconds,
                                range: mediaScrubRange
                            )
                            model.seekMedia(toMediaTimeMs: Int((targetSeconds * 1_000).rounded()))
                            mediaScrubState.finish()
                        }
                    },
                    onCancelled: {
                        model.recordDeveloperDiagnostic("scrub.media.cancelled", [:])
                        mediaScrubState.finish() // slid off the bar and lifted: no seek (#1930)
                    },
                    barContent: mediaBarContent,
                    barPositionUnit: .seconds,
                    positionAccessibilityValue: "\(formatPlaybackTime(Int(scrubberDisplaySeconds * 1_000))) of \(formatPlaybackTime(mediaDurationMs))"
                )
                .tint(AppColors.accent)
                .padding(.vertical, -PlaybackPositionSlider.rowGapOverlap)
                .onCompatibleChange(of: canonicalMediaSeconds) { value in
                    model.recordDeveloperDiagnostic("scrub.media.display", ["canonical": String(value), "displayed": String(mediaScrubState.displayedValue(canonicalValue: value, range: mediaScrubRange)), "editing": String(mediaScrubState.isEditing), "range": String(mediaScrubRange.upperBound)])
                }
                .disabled(model.snapshot.isRecording)
                Text("−\(formatPlaybackTime(displayMediaRemainingMs))")
                    .frame(minWidth: 42, alignment: .leading)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(AppColors.watchSecondary)
        } else if !model.isMediaPlaybackSnapshot,
                  textLength > 0,
                  model.canShowFullPlaybackScrubber {
            HStack(spacing: 8) {
                Text("\(textScrubberPercent)%")
                    .frame(minWidth: 34, alignment: .trailing)
                    .accessibilityIdentifier("playback.progress.label")
                PlaybackPositionSlider(
                    value: Binding(
                        get: { textScrubState.displayedValue(canonicalValue: canonicalTextOffset, range: textScrubRange) },
                        set: {
                            textScrubState.updateFromGesture($0, range: textScrubRange)
                            model.recordDeveloperDiagnostic("scrub.text.drag", ["value": String($0), "canonical": String(canonicalTextOffset), "range": String(textScrubRange.upperBound)])
                        }
                    ),
                    range: textScrubRange,
                    onEditingChanged: { editing in
                        model.recordDeveloperDiagnostic("scrub.text.editing", ["editing": String(editing)])
                        if editing {
                            textScrubState.begin(at: canonicalTextOffset, range: textScrubRange)
                        } else {
                            let targetOffset = textScrubState.displayedValue(
                                canonicalValue: canonicalTextOffset,
                                range: textScrubRange
                            )
                            model.seekText(toCharOffset: Int(targetOffset.rounded()))
                            textScrubState.finish()
                        }
                    },
                    onCancelled: {
                        model.recordDeveloperDiagnostic("scrub.text.cancelled", [:])
                        textScrubState.finish() // slid off the bar and lifted: no seek (#1930)
                    },
                    barContent: textBarContent,
                    barPositionUnit: .characters,
                    positionAccessibilityValue: textTimeEstimate?.scrubberAccessibilityValue(percent: textScrubberPercent) ?? "\(textScrubberPercent) percent"
                )
                .tint(AppColors.accent)
                .padding(.vertical, -PlaybackPositionSlider.rowGapOverlap)
                .onCompatibleChange(of: canonicalTextOffset) { value in
                    model.recordDeveloperDiagnostic("scrub.text.display", ["canonical": String(value), "displayed": String(textScrubState.displayedValue(canonicalValue: value, range: textScrubRange)), "editing": String(textScrubState.isEditing), "range": String(textScrubRange.upperBound)])
                }
                .disabled(model.snapshot.isRecording)
                // Compact and as wide as its text, so the slider keeps the rest of the row (#1442). The slider's
                // VoiceOver value above already says the time left in words.
                Text(textTimeEstimate?.compactRemainingText ?? "100%")
                    .fixedSize(horizontal: true, vertical: false)
                    .allowsHitTesting(false)
                    // The label stays its own element (its identifier is queried, #305), so it speaks the words.
                    .accessibilityLabel(textTimeEstimate?.remainingSpokenText ?? "100 percent")
                    .accessibilityIdentifier("playback.timeLeft.label")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(AppColors.watchSecondary)
        } else {
            let barLabels = PlaybackProgressBarLabels(
                percent: model.displayPlaybackProgressPercent,
                estimate: model.isMediaPlaybackSnapshot ? nil : textTimeEstimate // starter audio still shows time left
            )
            HStack(spacing: 8) {
                Text("\(model.displayPlaybackProgressPercent)%")
                    .frame(minWidth: 34, alignment: .trailing)
                    .accessibilityIdentifier("playback.progress.label")
                ProgressView(value: Double(model.displayPlaybackProgressPercent), total: 100)
                    .tint(AppColors.accent)
                    .accessibilityLabel("Playback progress")
                    .accessibilityValue(barLabels.accessibilityValue)
                Text(barLabels.trailing)
                    .fixedSize(horizontal: true, vertical: false)
                    .allowsHitTesting(false)
                    .accessibilityLabel(barLabels.trailingSpokenText)
                    .accessibilityIdentifier("playback.timeLeft.label")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(AppColors.watchSecondary)
        }
    }

    private var playbackTransport: some View {
        VStack(spacing: 12) {
            HStack(spacing: 22) {
                Button {
                    if model.isMediaPlaybackSnapshot {
                        model.skipBackMedia()
                    } else {
                        model.skipBack()
                    }
                } label: {
                    if model.isMediaPlaybackSnapshot {
                        Image(systemName: "gobackward.\(model.mediaSkipBackSeconds)")
                    } else {
                        PlaybackTextSkipIcon(direction: .backward, unit: model.skipUnit)
                    }
                }
                .buttonStyle(RoundPlaybackButtonStyle())
                .disabled(!model.hasActiveSession)
                .accessibilityLabel(model.isMediaPlaybackSnapshot ? "Back \(model.mediaSkipBackSeconds) seconds" : "Previous \(model.skipUnit)")
                .accessibilityIdentifier("playback.back.button")

                Button(action: model.playPauseTapped) {
                    Group {
                        if model.playPauseFace == .cancelStart {
                            // A start is pending and a tap cancels it: a stop mark inside the spinner says so (#2098).
                            ZStack {
                                ProgressView()
                                    .tint(.white)
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 12, weight: .bold))
                            }
                        } else {
                            Image(systemName: model.snapshot.phase == .finished && model.playingImportedCommentary == nil ? "arrow.counterclockwise" : (model.snapshot.skimBridgeState?.status == .playing
                                || model.activePlaybackIsPlaying ? "pause.fill" : "play.fill"))
                        }
                    }
                }
                .buttonStyle(MainPlaybackButtonStyle())
                .accessibilityLabel(model.snapshot.phase == .finished && model.playingImportedCommentary == nil ? "Replay in a new session" : (model.snapshot.skimBridgeState?.status == .playing
                    || model.activePlaybackIsPlaying ? "Pause" : "Play"))
                .accessibilityHint(model.playPauseFace.accessibilityHint ?? "")
                .accessibilityIdentifier("playback.play.button")

                Button {
                    if model.isMediaPlaybackSnapshot {
                        model.skipForwardMedia()
                    } else {
                        model.skipForward()
                    }
                } label: {
                    if model.isMediaPlaybackSnapshot {
                        Image(systemName: "goforward.\(model.mediaSkipForwardSeconds)")
                    } else {
                        PlaybackTextSkipIcon(direction: .forward, unit: model.skipUnit)
                    }
                }
                .buttonStyle(RoundPlaybackButtonStyle())
                .disabled(!model.hasActiveSession)
                .accessibilityLabel(model.isMediaPlaybackSnapshot ? "Forward \(model.mediaSkipForwardSeconds) seconds" : "Next \(model.skipUnit)")
                .accessibilityIdentifier("playback.forward.button")
            }
        }
        .disabled(model.snapshot.isRecording)
    }

    private var playbackRateControl: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                playbackSecondaryControls
            }
            .fixedSize(horizontal: true, vertical: false)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                playbackSecondaryControls
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .buttonStyle(.bordered)
        .tint(AppColors.watchControl)
    }

    @ViewBuilder
    private var playbackSecondaryControls: some View {
        if let state = model.selectedPodcastDownloadState {
            Button(model.selectedPodcastDownloadButtonTitle, action: model.redownloadSelectedPodcast)
                .disabled(state == .downloading)
                .accessibilityIdentifier("playback.download.button")
        }

        if PlaybackTextReaderAvailability.isAvailable(
            targetType: model.snapshot.targetType,
            itemText: model.selectedItem.text,
            itemHasNativeAudio: model.selectedItem.isNativeAudio
        ) {
            Button(action: openSourceText) {
                if usesVerbosePlaybackActions {
                    PlaybackControlLabel(title: "Text", systemImage: "doc.plaintext")
                    .frame(minHeight: 32)
                    .expandedHitArea(vertical: 6)
                } else {
                    Image(systemName: "doc.plaintext")
                    .frame(minWidth: 24, minHeight: 32)
                    .expandedHitArea(horizontal: 10, vertical: 6)
                }
            }
            .accessibilityLabel("View native source text")
            .accessibilityIdentifier("playback.sourceText.button")
        }

        if model.showsMixWithOtherAudioOption {
            Toggle(isOn: Binding(
                get: { model.mixesWithOtherAudio },
                set: { model.setMixesWithOtherAudio($0) }
            )) {
                PlaybackControlLabel(
                    title: "Mix",
                    systemImage: model.mixesWithOtherAudio ? "checkmark.circle.fill" : "circle"
                )
                .frame(minHeight: 32)
                .expandedHitArea(vertical: 6)
            }
            .toggleStyle(.button)
            .disabled(model.snapshot.isRecording)
            .accessibilityLabel("Mix with Other Audio")
            .accessibilityValue(model.mixesWithOtherAudio ? "On" : "Off")
            .accessibilityIdentifier("playback.mixWithOtherAudio.toggle")
        }

        Button {
            isSleepTimerPresented = true
        } label: {
            if usesVerbosePlaybackActions {
                PlaybackControlLabel(title: model.sleepTimerIsActive ? model.sleepTimerDescription : "Sleep", systemImage: "moon.zzz")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .frame(minHeight: 32)
                    .expandedHitArea(vertical: 6)
            } else {
                Image(systemName: "moon.zzz")
                    .frame(minWidth: 24, minHeight: 32)
                    .expandedHitArea(horizontal: 10, vertical: 6)
            }
        }
        .accessibilityLabel(model.sleepTimerDescription)
        .accessibilityIdentifier("playback.sleepTimer.button")
        .popover(isPresented: $isSleepTimerPresented, arrowEdge: .top) {
            sleepTimerPopover
                .presentationCompactAdaptation(.popover)
        }

        Button {
            model.cyclePlaybackRate()
        } label: {
            if usesVerbosePlaybackActions {
                PlaybackControlLabel(title: model.compactPlaybackRateDescription, systemImage: "speedometer")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .frame(minHeight: 32)
                    .expandedHitArea(vertical: 6)
            } else {
                Text(model.compactPlaybackRateDescription)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .frame(minHeight: 32)
                    .expandedHitArea(vertical: 6)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .accessibilityLabel("Playback speed, \(model.compactPlaybackRateDescription)")
        .accessibilityHint("Advances to the next playback speed")
        .accessibilityIdentifier("playback.rate.button")
        .contextMenu {
            ForEach(Gate1AppModel.supportedPlaybackRates, id: \.self) { rate in
                Button(String(format: "%.2f×", rate)) {
                    if model.isMediaPlaybackSnapshot {
                        model.setMediaPlaybackRate(rate)
                    } else {
                        model.speechRate = rate * 0.5
                        model.playbackSpeechRateChanged()
                    }
                }
            }
        }
    }

    private var mixedAudioVolumeSlider: some View {
        VStack(spacing: 4) {
            Slider(
                value: $model.mixedPlaybackVolume,
                in: 0...Gate1AppModel.mixedPlaybackVolumeMaximum,
                step: 0.05,
                onEditingChanged: { isEditing in
                    if !isEditing {
                        model.mixedPlaybackVolumeChanged()
                    }
                }
            )
            .tint(AppColors.ochre)
            .accessibilityLabel("Spoken Margins level")
            .accessibilityValue(
                Text(model.mixedPlaybackVolume, format: .percent.precision(.fractionLength(0)))
            )
            .accessibilityIdentifier("playback.mixedAudioVolume.slider")
            HStack {
                Text("Muted")
                Spacer()
                Text("100%")
            }
            .font(.caption2)
            .foregroundStyle(AppColors.watchSecondary)
        }
    }

    private var lowerBackgroundAudioToggle: some View {
        // The icon swaps between a filled check and an empty circle, as the Mix toggle's does, so "on" doesn't
        // rest on the tint alone (#1923).
        Toggle(
            isOn: Binding(
                get: { model.lowersBackgroundAudio },
                set: { model.setLowersBackgroundAudio($0) }
            )
        ) {
            Label(
                "Lower Background Audio",
                systemImage: model.lowersBackgroundAudio ? "checkmark.circle.fill" : "circle"
            )
        }
        .font(.subheadline.weight(.semibold))
        .tint(AppColors.ochre)
        .accessibilityIdentifier("playback.lowerBackgroundAudio.toggle")
        .accessibilityHint("Lowers other apps’ audio while Spoken Margins plays. Starts off for each session.")
        .toggleStyle(.button)
    }

    @ViewBuilder
    private var mixedAudioControl: some View {
        if model.showsMixWithOtherAudioOption && model.mixesWithOtherAudio {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Spoken Margins level", systemImage: "speaker.wave.2")
                    Spacer()
                    Text(model.mixedPlaybackVolume, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
                .font(.caption.weight(.semibold))

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        mixedAudioVolumeSlider.frame(minWidth: 120)
                        lowerBackgroundAudioToggle.fixedSize(horizontal: true, vertical: false)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        mixedAudioVolumeSlider
                        lowerBackgroundAudioToggle
                    }
                }

                Text("Make Spoken Margins easier to hear by lowering other apps while listening. Their volume returns when you pause or turn this off.")
                    .font(.caption2)
                    .foregroundStyle(AppColors.watchSecondary)

                Text("Other audio can continue. Control Spoken Margins here; Lock Screen and headphone controls may control the other app.")
                    .font(.caption2)
                    .foregroundStyle(AppColors.watchSecondary)
            }
            .padding(14)
            .foregroundStyle(.white)
            .background(AppColors.watchControl.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .disabled(model.snapshot.isRecording)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("playback.mixedAudio.control")
        }
    }

    @ViewBuilder
    private var onDeviceSpeechGenerationControl: some View {
        if model.shouldShowOnDeviceSpeechGenerationStatus {
            HStack(spacing: 12) {
                if model.isOnDeviceSpeechGenerating {
                    ProgressView()
                        .tint(AppColors.accent)
                } else if model.canStopOnDeviceSpeechGeneration {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppColors.accent)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(AppColors.accent)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("On-device voice")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                    Text(model.onDeviceSpeechGenerationStatusDescription)
                        .font(.caption2)
                        .foregroundStyle(AppColors.watchSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if model.canStopOnDeviceSpeechGeneration {
                    Button("Stop", action: model.stopOnDeviceSpeechGeneration)
                        .font(.caption.weight(.bold))
                        .buttonStyle(.bordered)
                        .tint(AppColors.watchDanger)
                        .accessibilityHint("Continues playback with the iOS system voice")
                        .accessibilityIdentifier("playback.onDeviceGeneration.stop")
                } else if model.canRetryOnDeviceSpeechGeneration {
                    Button("Retry", action: model.retryOnDeviceSpeechGeneration)
                        .font(.caption.weight(.bold))
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("playback.onDeviceGeneration.retry")
                }
            }
            .padding(12)
            .background(AppColors.watchControl.opacity(0.8))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("playback.onDeviceGeneration.status")
        }
    }

    private var playbackRatePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.isMediaPlaybackSnapshot ? "Playback Speed" : "Speaking Rate")
                .font(.headline)
            Text(model.compactPlaybackRateDescription)
                .font(.title2.weight(.bold).monospacedDigit())
            if model.isMediaPlaybackSnapshot {
                DiscretePlaybackRateSlider(
                    value: Binding(get: { model.mediaPlaybackRate }, set: { model.setMediaPlaybackRate($0) }),
                    accessibilityLabel: "Playback speed",
                    accessibilityValue: String(format: "%.2f times", model.mediaPlaybackRate),
                    accessibilityIdentifier: "playback.mediaRate.slider"
                )
                Text("Transcript: \(model.sourceTranscriptStatusDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("playback.sourceTranscript.status")
            } else {
                DiscretePlaybackRateSlider(
                    value: Binding(
                        get: { model.speechPlaybackRateMultiplier },
                        set: { model.speechRate = $0 * 0.5 }
                    ),
                    accessibilityLabel: "Speaking rate",
                    accessibilityValue: model.speechRateDescription,
                    accessibilityIdentifier: "playback.speechRate.slider"
                )
                    .onCompatibleChange(of: model.speechRate) { _ in model.playbackSpeechRateChanged() }
                Text("Prepared audio: \(model.preparedTextAudioStatusDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("playback.preparedAudio.status")
            }
        }
        .padding(20)
        .frame(minWidth: 280, idealWidth: 320)
    }

    private var sleepTimerPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sleep Timer").font(.headline)
            if model.sleepTimerIsActive {
                Text(model.sleepTimerDescription).font(.title2.weight(.bold).monospacedDigit())
                HStack {
                    Button("Extend 15 Minutes", action: model.extendSleepTimerBy15Minutes)
                        .buttonStyle(SecondaryButtonStyle())
                    Button("Cancel", role: .destructive, action: model.cancelSleepTimer)
                        .buttonStyle(LightButtonStyle())
                }
            }
            ForEach([SleepTimerMode.minutes15, .minutes30, .minutes45, .minutes60], id: \.self) { mode in
                Button(mode.rawValue.replacingOccurrences(of: "minutes_", with: "") + " Minutes") {
                    model.armSleepTimer(mode)
                    isSleepTimerPresented = false
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            Button("End of Chapter") {
                model.armSleepTimer(.endOfChapter)
                isSleepTimerPresented = false
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(!model.canUseEndOfChapterSleepTimer)
        }
        .padding(20)
        .frame(minWidth: 300)
    }

    private var gate2CompactValidation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Compact Controls")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppColors.watchSecondary)
            Text(model.gate2CompactSnapshot?.chapterTitle ?? "No compact snapshot")
                .font(.caption)
                .foregroundStyle(.white)
                .accessibilityIdentifier("gate2.compact.chapter")
                .accessibilityValue(model.snapshot.status.rawValue)
            HStack(spacing: 8) {
                Button {
                    model.dispatchGate2CompactCommand(.skipBack)
                } label: {
                    Image(systemName: "gobackward.15")
                }
                .buttonStyle(WatchSecondaryButtonStyle())
                .accessibilityLabel("Compact controls skip back")
                .accessibilityIdentifier("gate2.compact.back.button")

                Button {
                    model.dispatchGate2CompactCommand(.togglePlayPause)
                } label: {
                    Image(systemName: "playpause")
                }
                .buttonStyle(WatchSecondaryButtonStyle())
                .accessibilityLabel("Compact controls play or pause")
                .accessibilityIdentifier("gate2.compact.playPause.button")

                Button {
                    model.dispatchGate2CompactCommand(.skipForward)
                } label: {
                    Image(systemName: "goforward.15")
                }
                .buttonStyle(WatchSecondaryButtonStyle())
                .accessibilityLabel("Compact controls skip forward")
                .accessibilityIdentifier("gate2.compact.forward.button")
            }
        }
        .padding(.top, 8)
    }

    private var mediaDurationMs: Int {
        max(0, model.snapshot.currentPlaybackDurationMs ?? 0)
    }

    private var canonicalMediaSeconds: Double {
        Double(model.snapshot.currentMediaTimeMs ?? 0) / 1_000
    }

    private var mediaScrubRange: ClosedRange<Double> {
        0...Double(mediaDurationMs) / 1_000
    }

    private var scrubberDisplaySeconds: Double {
        mediaScrubState.displayedValue(canonicalValue: canonicalMediaSeconds, range: mediaScrubRange)
    }

    private var displayMediaRemainingMs: Int {
        let remainingMs = max(0, mediaDurationMs - Int(scrubberDisplaySeconds * 1_000))
        guard !mediaScrubState.isEditing, model.snapshot.status.isPlaybackActive else { return remainingMs }
        // Millisecond truncation must not claim zero time remains while the
        // canonical transport is still active. Completion will publish paused
        // and allow the terminal 0:00 state.
        return max(1_000, remainingMs)
    }

    private var textLength: Int {
        if model.snapshot.targetType == TargetType.assistantTurnTTS.rawValue || model.snapshot.targetType == TargetType.summaryTurnTTS.rawValue,
           let turn = model.selectedItem.turns.first(where: { $0.id == model.snapshot.targetId }) {
            let text = turn.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty { return text.count }
            let summary = turn.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !summary.isEmpty { return summary.count }
            return (turn.rawText ?? "").count
        }
        return model.selectedItem.text.count
    }

    /// The chapters and Margins the bar draws for a playing podcast, where the Timeline lists them (#428).
    private var mediaBarContent: PlaybackBarContent? {
        guard model.snapshot.itemId == model.selectedItem.id else { return nil }
        return PlaybackBarContent.media(
            durationMs: mediaDurationMs,
            chapterStartsMs: PlaybackBarContent.chapterStartsMs(
                mediaChapters: model.selectedItem.mediaChapters,
                scenes: model.selectedItem.listeningMapScenes
            ),
            own: model.selectedItem.interjections,
            shared: activeImportedMargins
        )
    }

    /// The same for a text source. A spoken summary or reply has its own text and no bar content.
    private var textBarContent: PlaybackBarContent? {
        guard model.snapshot.itemId == model.selectedItem.id,
              model.snapshot.targetType != TargetType.assistantTurnTTS.rawValue,
              model.snapshot.targetType != TargetType.summaryTurnTTS.rawValue
        else { return nil }
        return PlaybackBarContent.text(
            length: textLength,
            chapterStartChars: model.selectedItem.chapters.map(\.startChar),
            own: model.selectedItem.interjections,
            shared: activeImportedMargins
        )
    }

    private var activeImportedMargins: [ImportedCommentaryInterjection] {
        model.selectedItem.importedCommentaryLayers
            .filter { $0.deletedAt == nil }
            .flatMap { model.selectedItem.importedCommentaryInterjections[$0.id] ?? [] }
    }

    private var canonicalTextOffset: Double {
        Double(model.snapshot.currentTextStart ?? 0)
    }

    private var textScrubRange: ClosedRange<Double> {
        0...Double(textLength)
    }

    /// "about 12 min left" at the listener's speed, following a drag (#305).
    private var textTimeEstimate: ListeningTimeEstimate? {
        let offset = textScrubState.displayedValue(canonicalValue: canonicalTextOffset, range: textScrubRange)
        return ListeningTimeEstimator.estimate(
            totalCharacters: textLength,
            charactersHeard: Int(offset.rounded()),
            playbackSpeed: model.speechPlaybackRateMultiplier
        )
    }

    private var textScrubberPercent: Int {
        guard textLength > 0 else { return 0 }
        let offset = textScrubState.displayedValue(canonicalValue: canonicalTextOffset, range: textScrubRange)
        return max(0, min(100, Int((offset / Double(textLength) * 100).rounded())))
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Timeline", systemImage: "music.note.list")
                    .font(.headline)
                Spacer()
            }
            if timelineEntries.isEmpty {
                ProductPanel {
                    Text("No chapters or Margins yet.")
                        .foregroundStyle(AppColors.secondaryText)
                }
            } else {
                ForEach(timelineEntries) { entry in
                    switch entry {
                    case .sourceItem:
                        Button {
                            model.playSourceFromBeginning(fromTimeline: true)
                        } label: {
                            TimelineRow(percent: "SRC", title: model.selectedItem.title, subtitle: "Play source from beginning")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("timeline.source.play")
                    case .overview:
                        TimelineRow(percent: "MAP", title: "Listening overview", subtitle: model.selectedItem.overview)
                            .accessibilityIdentifier("timeline.overview")
                    case .chapter(let chapter):
                        Button {
                            model.jumpToChapter(chapter, fromTimeline: true)
                        } label: {
                            TimelineRow(
                                percent: "\(chapter.percent)%",
                                title: chapter.title,
                                subtitle: "Starts around \(chapter.percent)%",
                                isCurrent: model.isCurrentTimelineChapter(chapter)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("timeline.chapter.jump.\(chapter.id)")
                    case .mediaChapter(let chapter, _):
                        Button {
                            model.jumpToMediaChapter(chapter, fromTimeline: true)
                        } label: {
                            TimelineRow(
                                percent: formatPlaybackTime(chapter.startMs),
                                title: chapter.title,
                                subtitle: chapter.description ?? "Starts at \(formatPlaybackTime(chapter.startMs))",
                                isCurrent: model.isCurrentTimelineMediaChapter(chapter)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("timeline.mediaChapter.jump.\(chapter.id)")
                    case .listeningMapScene(let scene, _):
                        Button {
                            model.jumpToListeningMapScene(scene, fromTimeline: true)
                        } label: {
                            TimelineRow(
                                percent: formatPlaybackTime(scene.startMs),
                                title: scene.title,
                                subtitle: scene.description ?? "Private Listening Map scene",
                                isCurrent: model.isCurrentTimelineListeningMapScene(scene)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("timeline.listeningMapScene.jump.\(scene.id)")
                    case .interjection(let interjection):
                        TimelineInterjectionRow(
                            interjectionID: interjection.id,
                            percent: InterjectionPositionPresentation.timelineBadge(
                                for: interjection,
                                durationMs: interjectionMediaDurationMs
                            ),
                            subtitle: interjectionPreview(interjection),
                            isStarred: interjection.isStarredForSharing == true,
                            privateNote: interjection.privateSharingNote,
                            open: {
                                model.recordTimelineInterjectionViewed(interjectionId: interjection.id)
                                selectedInterjection = interjection
                            },
                            toggleStar: {
                                model.setInterjectionStarredForSharing(
                                    interjection.id,
                                    starred: interjection.isStarredForSharing != true
                                )
                            }
                        )
                        .accessibilityIdentifier("timeline.interjection.\(interjection.id)")
                    case .importedCommentary(let layer, let margin, _):
                        Button {
                            model.listenToImportedCommentary(layerID: layer.id, interjectionID: margin.id)
                        } label: {
                            TimelineRow(
                                percent: margin.resolution.localMediaTimeMs.map(formatPlaybackTime) ?? "SHR",
                                title: "Shared Margin · \(layer.displayLabel?.nilIfEmpty ?? "Unsigned sender")",
                                subtitle: margin.approvedTranscript
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("timeline.importedCommentary.\(margin.id)")
                    case .turn(let turn):
                        Button {
                            model.playTurn(turn, fromTimeline: true)
                        } label: {
                            TimelineRow(percent: turnBadge(turn), title: turnTitle(turn), subtitle: turn.summary ?? turn.text ?? humanizedTurnStatus(turn.status))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("timeline.turn.play.\(turn.id)")
                    case .turnChapter(let turn, let chapter):
                        Button {
                            model.jumpToTurnChapter(turn: turn, chapter: chapter, fromTimeline: true)
                        } label: {
                            TimelineRow(
                                percent: "AI \(chapter.percent)%",
                                title: chapter.title,
                                subtitle: turnTitle(turn),
                                isCurrent: model.isCurrentTimelineChapter(chapter, turnId: turn.id)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("timeline.turnChapter.jump.\(turn.id).\(chapter.id)")
                    }
                }
            }
        }
        .disabled(model.snapshot.isRecording)
        .accessibilityIdentifier("timeline.section")
        .id("playback.timeline")
    }

    private var timelineEntries: [PlaybackTimelineEntry] {
        let hasChapters = !model.selectedItem.chapters.isEmpty
            || !visibleMediaChapters.isEmpty
            || !model.selectedItem.listeningMapScenes.isEmpty
        let hasSummary = !model.selectedItem.overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let sourceHeaderEntries: [PlaybackTimelineEntry]
        if hasSummary {
            sourceHeaderEntries = [.overview]
        } else if hasChapters {
            sourceHeaderEntries = []
        } else {
            sourceHeaderEntries = [.sourceItem]
        }
        let mediaDurationMs = max(1, interjectionMediaDurationMs ?? 1)
        let importedEntries = model.selectedItem.importedCommentaryLayers
            .filter { $0.deletedAt == nil }
            .flatMap { layer in
                (model.selectedItem.importedCommentaryInterjections[layer.id] ?? []).map { margin in
                    let percent = margin.resolution.localMediaTimeMs.map {
                        max(0, min(100, Int((Double($0) / Double(mediaDurationMs) * 100).rounded())))
                    } ?? margin.anchorEvidence.roughPercent ?? 100
                    return PlaybackTimelineEntry.importedCommentary(layer, margin, percent)
                }
            }
        let sourceEntries = (model.selectedItem.chapters.map { PlaybackTimelineEntry.chapter($0) } +
            visibleMediaChapters.map { chapter in
                PlaybackTimelineEntry.mediaChapter(
                    chapter,
                    max(0, min(100, Int(
                        (Double(chapter.startMs) / Double(mediaDurationMs) * 100).rounded()
                    )))
                )
            } +
            model.selectedItem.listeningMapScenes.map { scene in
                PlaybackTimelineEntry.listeningMapScene(
                    scene,
                    max(0, min(100, Int(
                        (Double(scene.startMs) / Double(mediaDurationMs) * 100).rounded()
                    )))
                )
            } +
            model.selectedItem.interjections.filter { $0.targetType == .item }.map { PlaybackTimelineEntry.interjection($0) } +
            importedEntries
        )
        .sorted { lhs, rhs in
            let lhsPercent = timelinePercent(for: lhs)
            let rhsPercent = timelinePercent(for: rhs)
            if lhsPercent == rhsPercent {
                if let lhsTime = lhs.interjectionMediaTimeMs,
                   let rhsTime = rhs.interjectionMediaTimeMs,
                   lhsTime != rhsTime {
                    return lhsTime < rhsTime
                }
                return lhs.sortRank < rhs.sortRank
            }
            return lhsPercent < rhsPercent
        }
        let turnEntries = model.selectedItem.turns.flatMap { turn -> [PlaybackTimelineEntry] in
            let chapters = turn.chapters ?? []
            return [PlaybackTimelineEntry.turn(turn)] +
            chapters.map { PlaybackTimelineEntry.turnChapter(turn, $0) } +
            model.selectedItem.interjections
                .filter { $0.targetId == turn.id && $0.targetType != .item }
                .map { PlaybackTimelineEntry.interjection($0) }
        }
        let turnIds = Set(model.selectedItem.turns.map(\.id))
        let orphanedTurnInterjections = model.selectedItem.interjections
            .filter { $0.targetType != .item && !turnIds.contains($0.targetId) }
            .map { PlaybackTimelineEntry.interjection($0) }
        return sourceHeaderEntries + sourceEntries + turnEntries + orphanedTurnInterjections
    }

    private var visibleMediaChapters: [MediaTimelineChapter] {
        let sourceChapterIDs = Set(model.selectedItem.chapters.map(\.id))
        return model.selectedItem.mediaChapters
            .filter {
                !$0.id.hasPrefix("ch-transcript-")
                    && !$0.id.contains("-ch-transcript-")
                    && !sourceChapterIDs.contains($0.id)
            }
            .sorted { $0.startMs < $1.startMs }
    }

    private var interjectionMediaDurationMs: Int? {
        model.selectedItem.mediaDurationMs
            ?? (model.snapshot.itemId == model.selectedItem.id ? model.snapshot.currentPlaybackDurationMs : nil)
    }

    private func timelinePercent(for entry: PlaybackTimelineEntry) -> Int {
        if case .interjection(let interjection) = entry, interjection.targetType == .item {
            return InterjectionPositionPresentation.sortPercent(
                for: interjection,
                durationMs: interjectionMediaDurationMs
            )
        }
        return entry.percent
    }

    private var conversation: some View {
        ProductPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "info.circle")
                        .accessibilityHidden(true)
                    Spacer()
                    Text("Conversation")
                        .font(.headline)
                    Button {
                        if isPlaybackOptionsPresented { closeOptions(to: .paste) }
                        else { isPastingAssistantResponse = true }
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(IconButtonStyle())
                    .disabled(!model.hasActiveSession)
                    .accessibilityLabel("Paste Assistant Response")
                    .accessibilityIdentifier("conversation.pasteResponse.button")
                }
                if model.selectedItem.turns.isEmpty {
                    Text(model.remoteProviderExperienceEnabled
                        ? "Generate a summary or send a follow-up after listening."
                        : "Generate an on-device summary, or paste a response from another chatbot.")
                        .foregroundStyle(AppColors.secondaryText)
                } else {
                    ForEach(model.selectedItem.turns, id: \.id) { turn in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(turnTitle(turn))
                                    .font(.headline)
                                Spacer()
                                if turn.role == "assistant", turn.status == "complete" {
                                    Button {
                                        model.copyTargetInterjections(targetType: turn.turnType == "interjection_summary" ? InterjectionTargetType.summaryTurn.rawValue : InterjectionTargetType.assistantTurn.rawValue, targetId: turn.id)
                                    } label: {
                                        Label("Copy notes", systemImage: "doc.on.doc")
                                            .padding(.horizontal, 10)
                                            .frame(minHeight: 34)
                                    }
                                    .buttonStyle(IconButtonStyle())
                                    .disabled(model.selectedItem.interjections.filter { $0.targetId == turn.id && $0.targetType != .item }.isEmpty)
                                    .accessibilityLabel("Copy Margins for \(turnTitle(turn))")
                                    .accessibilityIdentifier("conversation.copyTurnInterjections.\(turn.id)")
                                    Button {
                                        isPlaybackOptionsPresented = false
                                        model.playTurn(turn)
                                    } label: {
                                        Image(systemName: "play.fill")
                                            .frame(width: 34, height: 34)
                                    }
                                    .buttonStyle(IconButtonStyle())
                                    .accessibilityLabel("Play \(turnTitle(turn))")
                                    .accessibilityIdentifier("conversation.playTurn.\(turn.id)")
                                }
                                Pill(humanizedTurnStatus(turn.status))
                            }
                            Text(turn.summary ?? turn.text ?? turn.rawText ?? "")
                                .font(.subheadline)
                                .foregroundStyle(AppColors.secondaryText)
                        }
                        Divider()
                    }
                }
                if model.canRetryLocalSummary {
                    Button("Retry Summary", action: model.retryPendingAI)
                        .buttonStyle(SecondaryButtonStyle())
                        .accessibilityIdentifier("conversation.retrySummary.button")
                }
                if model.remoteProviderExperienceEnabled {
                    TextField("Ask a follow-up…", text: $followUp, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .focused($followUpFocused)
                        .accessibilityLabel("Ask a follow-up")
                        .accessibilityIdentifier("conversation.followup.field")
                    HStack {
                        Button("Submit") {
                            followUpFocused = false
                            model.followUp(followUp)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!model.hasActiveSession || followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("conversation.submit.button")
                        Button("Retry AI", action: model.retryPendingAI)
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(!model.hasActiveSession)
                            .accessibilityIdentifier("conversation.retry.button")
                    }
                }
            }
        }
        .accessibilityIdentifier("conversation.section")
    }
}

private struct GuidedOnboardingPlaybackCard: View {
    @EnvironmentObject private var model: Gate1AppModel
    let showTimeline: () -> Void

    var body: some View {
        ProductPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Label("Guided Tour", systemImage: "sparkles")
                        .font(.headline)
                    Spacer()
                    Button(action: model.pauseGuidedOnboarding) {
                        TapTargetIcon(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Pause guided tour")
                }
                stageContent
            }
        }
        .frame(maxWidth: 720)
        .accessibilityIdentifier("playback.onboarding.card")
    }

    @ViewBuilder
    private var stageContent: some View {
        switch model.guidedOnboardingStage {
        case .practiceInterjection:
            Text("Practice making a Margin")
                .font(.title3.bold())
                .screenTitle()
            Text("Let the welcome source play until an idea occurs to you, then record a short note. Spoken Margins will keep it with this listening session.")
                .foregroundStyle(AppColors.secondaryText)
            if model.snapshot.isRecording {
                Button("Done Recording", action: model.finishInterjection)
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("onboarding.interjection.done.button")
            } else {
                Button("Add a Margin", action: model.beginInterjection)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!model.hasActiveSession)
                    .accessibilityIdentifier("onboarding.interjection.start.button")
            }
        case .reviewTimeline:
            Text("Use the timeline")
                .font(.title3.bold())
                .screenTitle()
            Text("Tap your saved Margin to review it, or tap any source chapter to jump there. Either action completes this step.")
                .foregroundStyle(AppColors.secondaryText)
            Button("Show Timeline", action: showTimeline)
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("onboarding.timeline.show.button")
        case .optionalAI:
            Text("AI is optional")
                .font(.title3.bold())
                .screenTitle()
            Text(model.remoteProviderExperienceEnabled
                ? "Summarize Notes sums up this session’s Margins. Discuss answers a question using relevant source and session context. Both require your OpenAI API key, network access, and permission to send content."
                : "Summarize Notes uses Apple’s on-device model when it is available. Nothing is sent to a third-party AI service. You can also copy notes to another chatbot and paste its response back here.")
                .foregroundStyle(AppColors.secondaryText)
            if model.remoteProviderExperienceEnabled {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Button("Set Up AI", action: model.openAISettingsFromOnboarding)
                            .buttonStyle(SecondaryButtonStyle())
                        Button("Continue Without AI", action: model.continueGuidedOnboardingPastAI)
                            .buttonStyle(PrimaryButtonStyle())
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Button("Continue Without AI", action: model.continueGuidedOnboardingPastAI)
                            .buttonStyle(PrimaryButtonStyle())
                        Button("Set Up AI", action: model.openAISettingsFromOnboarding)
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
            } else {
                Text(model.localFoundationModelAvailabilityDescription)
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
                Button("Continue", action: model.continueGuidedOnboardingPastAI)
                    .buttonStyle(PrimaryButtonStyle())
            }
        case .exportSession:
            Text("Keep the useful context")
                .font(.title3.bold())
                .screenTitle()
            Text("Open the session export, then share it or copy its Markdown or JSON. Completion is recorded only after a share succeeds or the export is copied.")
                .foregroundStyle(AppColors.secondaryText)
            Button("Open Session Export", action: model.openExport)
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!model.hasActiveSession)
                .accessibilityIdentifier("onboarding.export.open.button")
        case .complete:
            Text("You know the core loop")
                .font(.title3.bold())
                .screenTitle()
            Text("You can now add a source of your own, or keep exploring the welcome session. Source-specific setup remains available in Help.")
                .foregroundStyle(AppColors.secondaryText)
            Button("Finish Tour", action: model.finishGuidedOnboarding)
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("onboarding.finish.button")
        case .inactive:
            EmptyView()
        }
    }
}

private struct PastedAssistantResponseView: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Binding var isPresented: Bool
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Button {
                        model.importPastedAssistantResponse(autoPlay: true)
                        isPresented = false
                    } label: {
                        Label("Import And Play", systemImage: "play.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.pastedAssistantResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("pasteResponse.importPlay.button")

                    Button {
                        model.importPastedAssistantResponse(autoPlay: false)
                        isPresented = false
                    } label: {
                        Label("Import", systemImage: "plus")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.pastedAssistantResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("pasteResponse.import.button")
                }
                TextEditor(text: $model.pastedAssistantResponse)
                    .font(.body)
                    .frame(height: 180)
                    .padding(8)
                    .inputEditorBackground()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppColors.border))
                    .focused($isFocused)
                    .accessibilityLabel("Assistant response text")
                    .accessibilityIdentifier("pasteResponse.editor")
                Spacer()
            }
            .padding(20)
            .navigationTitle("Paste Response")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { isPresented = false }
                        .accessibilityIdentifier("pasteResponse.close.button")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isFocused = false }
                }
            }
            .onAppear { isFocused = true }
        }
    }
}

private enum PlaybackTimelineEntry: Identifiable {
    case sourceItem
    case overview
    case chapter(Chapter)
    case mediaChapter(MediaTimelineChapter, Int)
    case listeningMapScene(MediaTimelineChapter, Int)
    case interjection(Interjection)
    case importedCommentary(ImportedCommentaryLayer, ImportedCommentaryInterjection, Int)
    case turn(ConversationTurn)
    case turnChapter(ConversationTurn, Chapter)

    var id: String {
        switch self {
        case .sourceItem: return "source-item"
        case .overview: return "overview"
        case .chapter(let chapter): return "chapter-\(chapter.id)"
        case .mediaChapter(let chapter, _): return "media-chapter-\(chapter.id)"
        case .listeningMapScene(let scene, _): return "listening-map-scene-\(scene.id)"
        case .interjection(let interjection): return "interjection-\(interjection.id)"
        case .importedCommentary(_, let margin, _): return "imported-commentary-\(margin.id)"
        case .turn(let turn): return "turn-\(turn.id)"
        case .turnChapter(let turn, let chapter): return "turn-chapter-\(turn.id)-\(chapter.id)"
        }
    }

    var percent: Int {
        switch self {
        case .sourceItem: return 0
        case .overview: return 0
        case .chapter(let chapter): return chapter.percent
        case .mediaChapter(_, let percent): return percent
        case .listeningMapScene(_, let percent): return percent
        case .interjection(let interjection): return interjection.targetType == .item ? interjection.roughPercent : 101
        case .importedCommentary(_, _, let percent): return percent
        case .turn: return 101
        case .turnChapter: return 101
        }
    }

    var sortRank: Int {
        switch self {
        case .sourceItem: return -2
        case .overview: return -1
        case .chapter, .mediaChapter: return 0
        case .listeningMapScene: return 1
        case .interjection(let interjection): return interjection.targetType == .item ? 2 : 5
        case .importedCommentary: return 3
        case .turn: return 4
        case .turnChapter: return 5
        }
    }

    var interjectionMediaTimeMs: Int? {
        switch self {
        case .interjection(let interjection): return interjection.anchor.mediaTimeMs
        case .importedCommentary(_, let margin, _): return margin.resolution.localMediaTimeMs
        default: return nil
        }
    }
}

private struct TimelineRow: View {
    let percent: String
    let title: String
    let subtitle: String
    var isCurrent = false

    var body: some View {
        ProductPanel(isHighlighted: isCurrent) {
            HStack(alignment: .top, spacing: 14) {
                Text(percent)
                    .font(.headline)
                    .foregroundStyle(AppColors.green)
                    .frame(width: 64, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.headline)
                        if isCurrent {
                            Text("NOW")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(AppColors.text)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(AppColors.accentSoft)
                                .clipShape(Capsule())
                        }
                    }
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                        .lineLimit(3)
                }
            }
        }
        .accessibilityValue(isCurrent ? "Current chapter" : "")
    }
}

private struct TimelineInterjectionRow: View {
    let interjectionID: String
    let percent: String
    let subtitle: String
    let isStarred: Bool
    let privateNote: String?
    let open: () -> Void
    let toggleStar: () -> Void

    var body: some View {
        ProductPanel {
            HStack(alignment: .top, spacing: 10) {
                Button(action: open) {
                    HStack(alignment: .top, spacing: 14) {
                        Text(percent)
                            .font(.headline)
                            .foregroundStyle(AppColors.green)
                            .frame(width: 64, alignment: .leading)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Margin")
                                .font(.headline)
                                .foregroundStyle(AppColors.text)
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(AppColors.secondaryText)
                                .lineLimit(3)
                            if let privateNote = privateNote?.nilIfEmpty {
                                Label(privateNote, systemImage: "note.text")
                                    .font(.caption)
                                    .foregroundStyle(AppColors.secondaryText)
                                    .lineLimit(2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open Margin")
                .accessibilityIdentifier("timeline.interjection.open.\(interjectionID)")

                Button(action: toggleStar) {
                    Image(systemName: isStarred ? "star.fill" : "star")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(isStarred ? AppColors.star : AppColors.secondaryText)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // The label names the action, which already says the state; a value would read it twice.
                .accessibilityLabel(isStarred ? "Remove sharing star" : "Star Margin for sharing")
                .accessibilityIdentifier("timeline.interjection.star.\(interjectionID)")
            }
        }
    }
}

private struct Pill: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(AppColors.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(AppColors.softGreen)
            .clipShape(Capsule())
    }
}

private func turnTitle(_ turn: ConversationTurn) -> String {
    ConversationTurnTitle.numbered(turn)
}

private func turnBadge(_ turn: ConversationTurn) -> String {
    if turn.role == "user" || turn.turnType == "user_response" {
        return "YOU"
    }
    return "AI"
}

private func interjectionPreview(_ interjection: Interjection) -> String {
    if let displayText = interjection.displayText?.trimmingCharacters(in: .whitespacesAndNewlines),
       !displayText.isEmpty {
        return displayText
    }
    if let cleaned = interjection.cleanedTranscript?.trimmingCharacters(in: .whitespacesAndNewlines),
       !cleaned.isEmpty {
        return cleaned
    }
    if let transcript = interjection.transcript?.trimmingCharacters(in: .whitespacesAndNewlines),
       !transcript.isEmpty {
        return transcript
    }
    return TranscriptionFailureWording.marginStatus(transcriptionStatus: interjection.transcriptionStatus, speechRecognitionOff: SpeechRecognitionAccess.isOff) ?? interjection.transcriptionStatus
}

private struct LightButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.horizontal, 14)
            .frame(minHeight: 42)
            .foregroundStyle(AppColors.text)
            .background(AppColors.panel.opacity(configuration.isPressed ? 0.75 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .expandedHitArea(vertical: 1)
    }
}

private struct RoundPlaybackButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title2)
            .foregroundStyle(.white)
            .frame(width: 62, height: 62)
            .background(AppColors.watchControl.opacity(configuration.isPressed ? 0.72 : 1))
            .clipShape(Circle())
    }
}

private struct PlaybackControlLabel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let title: String
    let systemImage: String

    @ViewBuilder
    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                Text(title)
                    .multilineTextAlignment(.center)
            }
        } else {
            // Short control words ("Sleep", "Mix") shrink a little rather than wrap mid-word
            // when a wide rate label ("2.00×") squeezes the row.
            Label(title, systemImage: systemImage)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}

private struct MainPlaybackButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title2)
            .foregroundStyle(AppColors.interjectText)
            .frame(width: 76, height: 76)
            .background(AppColors.listeningAccent.opacity(configuration.isPressed ? 0.75 : 1))
            .clipShape(Circle())
    }
}

private struct WatchSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(AppColors.watchControl.opacity(configuration.isPressed ? 0.72 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct InterjectButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(minHeight: 52)
            .foregroundStyle(AppColors.interjectText)
            .background(AppColors.captureBackground.opacity(configuration.isPressed ? 0.78 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
