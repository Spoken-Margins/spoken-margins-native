import SwiftUI
import SessionKit
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

struct Gate1RootView: View {
    @EnvironmentObject private var model: Gate1AppModel
    @EnvironmentObject private var sharingCoordinator: Build23SharingCoordinator
    @EnvironmentObject private var catalogDrawer: CatalogDrawerModel
    @State private var navigation = AppNavigationState()
    @State private var keyboardIsPresented = false

    var body: some View {
        Group {
            if model.writtenMarginDraft != nil {
                ExperienceWrittenMarginScreen()
            } else if model.snapshot.isRecording || model.isRequestingRecordingPermission {
                ExperienceRecordingView()
            } else {
                switch model.screen {
                case .home:
                    ExperienceRootTabs(navigation: $navigation, showsMiniPlayer: !keyboardIsPresented && model.shouldShowMiniPlayer)
                case .item:
                    ExperienceItemDetailScreen()
                case .playback:
                    PlaybackScreen()
                case .timeline:
                    ExperienceTimelineRailScreen()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                case .settings:
                    SettingsScreen()
                case .offlineStorage:
                    ExperienceStorageScreen()
                case .export:
                    ExportScreen()
                case .batchExport:
                    BatchExportScreen()
                }
            }
        }
        .background(AppColors.background.ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 8) {
            if !model.recordingNavigationIsLocked,
               model.feedbackEvent != nil || model.trashUndo != nil || model.sourceImportProgressMessage != nil || model.legacyLibraryResetNotice != nil {
                VStack(spacing: 8) {
                    if let resetNotice = model.legacyLibraryResetNotice {
                        LegacyLibraryResetBanner(message: resetNotice)
                    }
                    if let progressMessage = model.sourceImportProgressMessage {
                        SourceOperationBanner(message: progressMessage)
                    }
                    if let feedback = model.feedbackEvent {
                        UserFeedbackBanner(feedback: feedback)
                    }
                    if let undo = model.trashUndo {
                        TrashUndoBanner(undo: undo)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 8) {
            if model.screen != .home && model.screen != .timeline && !model.recordingNavigationIsLocked && model.shouldShowMiniPlayer && !keyboardIsPresented {
                MiniPlayerBar()
                    .padding(.horizontal, 12)
                    .padding(.bottom, model.screen == .home ? 54 : 4)
            }
        }
        .edgeSwipeBack(enabled: !model.recordingNavigationIsLocked && model.screen != .home, action: model.openHome)
        .onAppear {
            model.bootstrapLibraryIfNeeded()
            catalogDrawer.presentIfFirstRun(
                libraryWasEmptyAtLaunch: model.libraryWasEmptyAtLaunch,
                followedSourceCount: model.feedSubscriptions.count
            )
        }
        .onChange(of: model.requestedExperienceRoot) { _, root in
            guard let root else { return }
            navigation.select(root, recordingIsLocked: model.recordingNavigationIsLocked)
            model.requestedExperienceRoot = nil
        }
        #if canImport(UIKit)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardIsPresented = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardIsPresented = false
        }
        #endif
        .sheet(isPresented: $model.isAIDataSharingConsentPresented) {
            AIDataSharingConsentView()
                .environmentObject(model)
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $model.isTermsOfUsePresented) {
            NavigationStack {
                SpokenMarginsTermsView(allowsAcceptance: true)
                    .environmentObject(model)
            }
            .interactiveDismissDisabled(!model.hasAcceptedCurrentTerms)
        }
        .sheet(isPresented: $catalogDrawer.isPresented, onDismiss: {
            catalogDrawer.markSeen()
            model.refreshFollowedSources(force: false)
        }) {
            CatalogDrawerView()
                .environmentObject(catalogDrawer)
        }
        .sheet(isPresented: $model.isHelpPresented) {
            HelpScreen()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.isSharingInterjectionsPresented) {
            Build23SenderSharingHost(coordinator: sharingCoordinator)
                .environmentObject(model)
        }
        .sheet(item: $model.spokenMarginsPackageImportReview) { _ in
            Build23RecipientSharingHost(coordinator: sharingCoordinator)
                .environmentObject(model)
                .interactiveDismissDisabled()
        }
        .alert("AI Setup Needed", isPresented: $model.isAISetupNeededPresented) {
            Button("Open AI Settings", action: model.openAISettingsFromSummaryPrompt)
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("Summarize Notes uses your OpenAI API key to turn this session’s Margins into a spoken debrief. Your session and saved position have not changed.")
        }
    }
}

@MainActor
private struct Build23SenderSharingHost: View {
    @EnvironmentObject private var model: Gate1AppModel
    @ObservedObject var coordinator: Build23SharingCoordinator
    #if DEBUG
    private static let showsRecipientTestTool = true
    #else
    private static let showsRecipientTestTool = false
    #endif

    var body: some View {
        Build23SenderSharingExperience(coordinator: coordinator)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // QA tool only: TestFlight and App Store builds use the Release configuration.
                if Self.showsRecipientTestTool, coordinator.verifiedShareFileURL != nil {
                    VStack(spacing: 10) {
                        Divider()
                        Button("Create recipient test session", systemImage: "person.2.badge.plus") {
                            model.createRecipientTestSessionFromLastSharedPackage()
                        }
                        .buttonStyle(.bordered)
                        .accessibilityHint("Stages this exact verified package in the recipient import experience")
                        .accessibilityIdentifier("build23.sender.recipient-test-session")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)
                }
            }
    }
}

@MainActor
private struct Build23RecipientSharingHost: View {
    @EnvironmentObject private var model: Gate1AppModel
    @ObservedObject var coordinator: Build23SharingCoordinator
    @State private var sourceRequest: Build23RecipientSourceRequest?

    var body: some View {
        Build23RecipientSharingExperience(coordinator: coordinator) { request in
            sourceRequest = request
        }
        .sheet(item: $sourceRequest, onDismiss: resumePendingImport) { request in
            ExperienceAddSourceFlow(initialRoute: addSourceRoute(for: request.itemType))
                .environmentObject(model)
        }
        .accessibilityIdentifier("build23.recipient.experience")
    }

    private func resumePendingImport() {
        coordinator.send(.resumeAfterAddingSource)
    }

    private func addSourceRoute(for itemType: SharedItemType) -> AddSourceRoute {
        switch itemType {
        case .podcast:
            .linkOrPodcast
        case .text:
            .pastedText
        case .pdf, .epub:
            .documentOrBook
        case .other:
            .linkOrPodcast
        }
    }
}

private struct LegacyLibraryResetBanner: View {
    @EnvironmentObject private var model: Gate1AppModel
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "archivebox")
                .foregroundStyle(AppColors.secondaryText)
            Text(message)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(action: model.dismissLegacyLibraryResetNotice) {
                Image(systemName: "xmark")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss library notice")
        }
        .padding(12)
        .foregroundStyle(AppColors.text)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppColors.border))
        .accessibilityIdentifier("libraryReset.notice.banner")
        .task {
            do {
                try await Task.sleep(for: .seconds(8))
                guard model.legacyLibraryResetNotice == message else { return }
                model.dismissLegacyLibraryResetNotice()
            } catch {
                // The banner disappeared or changed before its auto-dismiss timer fired.
            }
        }
    }
}

private struct AIDataSharingConsentView: View {
    @EnvironmentObject private var model: Gate1AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label("Send this content to OpenAI?", systemImage: "hand.raised.fill")
                        .font(.title2.bold())
                    Text("A live AI request can include the source text needed for the task, your Margin transcripts, the current follow-up, nearby anchors, and recent conversation turns.")
                    Text("Spoken Margins does not send recorded audio, local file paths, or internal database identifiers. Requests disable OpenAI response storage. You can revoke permission or delete your API key in Settings.")
                        .foregroundStyle(AppColors.secondaryText)
                    Link("Read the Privacy Policy", destination: AppLinks.privacy)
                    Button("Send to OpenAI", action: model.grantAIDataSharingConsent)
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityIdentifier("aiConsent.allow.button")
                    Button("Not Now", role: .cancel, action: model.declineAIDataSharingConsent)
                        .buttonStyle(SecondaryButtonStyle())
                        .accessibilityIdentifier("aiConsent.decline.button")
                }
                .padding(24)
            }
            .navigationTitle("AI Data Sharing")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("aiConsent.sheet")
    }
}

struct MiniPlayerBar: View {
    @EnvironmentObject private var model: Gate1AppModel

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var layout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 8))
    }

    var body: some View {
        layout {
            Button(action: model.openPlayback) {
                HStack(spacing: 11) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.playbackItemHeaderTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppColors.text)
                            .lineLimit(1)
                        if !dynamicTypeSize.isAccessibilitySize {
                            HStack(spacing: 7) {
                                if let chapter = model.playbackChapterHeaderTitle {
                                    Text(chapter).lineLimit(1)
                                }
                                Text("\(model.displayPlaybackProgressPercent)%")
                                    .monospacedDigit()
                            }
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Now Playing")
            .accessibilityValue("\(model.playbackItemHeaderTitle), \(model.playbackChapterHeaderTitle ?? "Source"), \(model.displayPlaybackProgressPercent) percent")
            .accessibilityIdentifier("miniPlayer.open.button")

            HStack(spacing: 4) {
                if dynamicTypeSize.isAccessibilitySize {
                    if let chapter = model.playbackChapterHeaderTitle {
                        Text(chapter)
                            .font(.caption2)
                            .foregroundStyle(AppColors.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(-1)
                            .accessibilityHidden(true)
                    }
                    Text("\(model.displayPlaybackProgressPercent)%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(AppColors.secondaryText)
                        .fixedSize()
                        .accessibilityHidden(true)
                    Spacer(minLength: 4)
                }
                Button(action: model.beginInterjection) {
                    Image(systemName: "mic.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 26)
                        .foregroundStyle(AppColors.coral)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Record an interjection")
                .accessibilityIdentifier("miniPlayer.interject.button")

                Button {
                    if model.snapshot.phase == .finished {
                        model.startNewSession(id: model.snapshot.itemId ?? model.selectedItem.id)
                    } else {
                        model.playPause()
                    }
                } label: {
                    Group {
                        if model.snapshot.status == .starting {
                            ProgressView().tint(AppColors.onEvergreen)
                        } else {
                            Image(systemName: model.activePlaybackIsPlaying ? "pause.fill" : "play.fill")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 20, height: 24)
                        }
                    }
                    .foregroundStyle(AppColors.onEvergreen)
                    .frame(width: 46, height: 46)
                    .background(AppColors.evergreen, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.activePlaybackIsPlaying ? "Pause" : "Play")
                .accessibilityIdentifier("miniPlayer.playPause.button")

                Button(action: model.dismissMiniPlayer) {
                    Image(systemName: "xmark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppColors.secondaryText)
                .accessibilityLabel("Close and save listening session")
                .accessibilityIdentifier("miniPlayer.close.button")
            }
            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, alignment: .trailing)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .foregroundStyle(AppColors.text)
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(AppColors.evergreen.opacity(0.25)))
        .shadow(color: .black.opacity(0.14), radius: 18, y: 7)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("miniPlayer.bar")
    }
}

private struct SourceOperationBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(message)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            Spacer()
            Text("You can keep listening")
                .font(.caption)
                .foregroundStyle(AppColors.secondaryText)
        }
        .padding(12)
        .foregroundStyle(AppColors.text)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppColors.border))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sourceImport.progress.banner")
    }
}

private struct TrashUndoBanner: View {
    @EnvironmentObject private var model: Gate1AppModel
    let undo: TrashUndoState

    var body: some View {
        HStack(spacing: 12) {
            Text("Moved \(undo.title) to Recently Deleted")
                .font(.subheadline)
                .lineLimit(2)
            Spacer()
            Button("Undo", action: model.undoLastTrash)
                .font(.subheadline.bold())
            Button(action: model.dismissTrashUndo) {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .foregroundStyle(.white)
        .background(Color.black.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("trash.undo.banner")
    }
}

struct DiscretePlaybackRateSlider: View {
    @Binding var value: Double
    let accessibilityLabel: String
    let accessibilityValue: String
    let accessibilityIdentifier: String

    private let rates = Gate1AppModel.supportedPlaybackRates

    var body: some View {
        VStack(spacing: 3) {
            Slider(value: $value, in: 0.5...2.0, step: 0.25)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityValue(accessibilityValue)
                .accessibilityIdentifier(accessibilityIdentifier)
            HStack(spacing: 0) {
                ForEach(Array(rates.enumerated()), id: \.offset) { index, rate in
                    Capsule()
                        .fill(rate == 1.0 ? AppColors.accent : Color.secondary.opacity(0.55))
                        .frame(width: 2, height: rate == 1.0 ? 8 : 5)
                    if index < rates.count - 1 {
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 14)
            .accessibilityHidden(true)
        }
    }
}

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

private struct PlaybackScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var followUp = ""
    @State private var selectedInterjection: Interjection?
    @State private var isPastingAssistantResponse = false
    @State private var mediaScrubState = PlaybackScrubState()
    @State private var textScrubState = PlaybackScrubState()
    @State private var isSleepTimerPresented = false
    @State private var isSourceTextPresented = false
    @State private var isPlaybackOptionsPresented = false
    @State private var pendingOptionsDestination: OptionsDestination?
    @Environment(\.openURL) private var openURL

    private enum OptionsDestination { case item, timeline, export, margins, write }
    @State private var sourceTextOffsetAtPresentation = 0
    @State private var timelinePullTriggered = false
    @AppStorage("playbackUsesVerboseActions") private var usesVerbosePlaybackActions = true
    @FocusState private var followUpFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ZStack {
                    AppColors.listeningBackground.ignoresSafeArea()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            if model.snapshot.phase == .finished {
                                Text("Finished").font(.headline).foregroundStyle(AppColors.listeningAccent)
                            }
                            playbackHeader
                            capturePermissionRecovery
                            importedCommentaryControl
                            marginMomentControl
                            recentMarginPreview
                            if model.shouldShowGuidedOnboardingCoach {
                                GuidedOnboardingPlaybackCard {
                                    openTimeline()
                                }
                            }
                            SourceFollowSuggestionCard(appearance: .playback)
                            ManualSourceFollowButton(appearance: .playback)
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
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        playbackControls
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("playback.screen")
                .task(id: model.renderFrontierKey) { await model.observeRenderedFrontier() }
                .task(id: "\(model.snapshot.itemId ?? "")|\(model.snapshot.status.rawValue)") {
                    guard model.snapshot.status == .starting, let id = model.snapshot.itemId,
                          model.selectedPodcastDownloadState != nil else { return }
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    model.stopStalledPodcastStart(itemID: id)
                }
                .onCompatibleChange(of: model.guidedOnboardingStage) { stage in
                    if stage == .reviewTimeline {
                        withAnimation {
                            proxy.scrollTo("playback.timeline", anchor: .top)
                        }
                    }
                }
            }
            .toolbarBackground(AppColors.listeningBackground, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: model.openLibrary) {
                        Label("Library", systemImage: "books.vertical")
                    }
                    .accessibilityIdentifier("playback.home.button")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { followUpFocused = false }
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
            .sheet(isPresented: $isSourceTextPresented) {
                NativeTextPeekView(
                    title: model.selectedItem.title,
                    text: model.selectedItem.text,
                    chapters: model.selectedItem.chapters,
                    currentOffset: sourceTextOffsetAtPresentation
                )
            }
            .sheet(isPresented: $isPlaybackOptionsPresented, onDismiss: performPendingOptionsNavigation) {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            playbackRateControl
                            mixedAudioControl
                            onDeviceSpeechGenerationControl
                            Button("Write a Margin", systemImage: "square.and.pencil") {
                                closeOptions(to: .write)
                            }
                            .accessibilityIdentifier("playback.writeMargin.button")
                            reflectionOptions
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
    }

    private var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing")
            || ProcessInfo.processInfo.environment["SPOKEN_MARGINS_UI_TESTING"] == "1"
    }

    private var playbackControls: some View {
        VStack(spacing: 10) {
            playbackPosition
            if model.canJumpToNextChapter {
                Button("Next chapter", systemImage: "forward.end") { model.jumpToNextChapter() }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("playback.nextChapter.button")
            }
            playbackTransport
            if !dynamicTypeSize.isAccessibilitySize {
                PlaybackSecondaryControlsRow {
                    Button(model.compactPlaybackRateDescription, action: model.cyclePlaybackRate)
                        .accessibilityLabel("Playback speed, \(model.compactPlaybackRateDescription)")
                        .accessibilityIdentifier("playback.rate.button")
                    Button {
                        isSleepTimerPresented = true
                    } label: {
                        Label(model.sleepTimerIsActive ? model.sleepTimerDescription : "Sleep", systemImage: "moon.zzz")
                    }
                    .accessibilityIdentifier("playback.sleepTimer.button")
                    .popover(isPresented: $isSleepTimerPresented) {
                        sleepTimerPopover.presentationCompactAdaptation(.popover)
                    }
                    listeningOptionsButton
                }
                .foregroundStyle(.white)
                .buttonStyle(.plain)
                .frame(minHeight: 44)
            }
            if model.playingImportedCommentary != nil {
                Button("Return to Source", action: model.returnToSourceFromImportedCommentary)
                    .buttonStyle(InterjectButtonStyle())
                    .accessibilityIdentifier("importedCommentary.returnToSource")
            } else if model.snapshot.skimBridgeState != nil {
                Button("Return to Source") {
                    model.returnFromSkim()
                }
                .buttonStyle(InterjectButtonStyle())
                .accessibilityIdentifier("playback.skim.return.button")
            } else if model.snapshot.phase == .finished {
                Button("Add a Margin", systemImage: "square.and.pencil", action: model.beginWrittenMargin)
                    .frame(maxWidth: .infinity)
                    .buttonStyle(InterjectButtonStyle())
                    .accessibilityIdentifier("playback.write.button")
                Button("Share", systemImage: "square.and.arrow.up", action: model.openExport)
                    .frame(maxWidth: .infinity)
                    .buttonStyle(InterjectButtonStyle())
                    .accessibilityIdentifier("playback.finished.share.button")
            } else {
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
            HStack(spacing: 18) {
                Button(action: openTimeline) {
                    if dynamicTypeSize.isAccessibilitySize {
                        Image(systemName: "list.bullet.rectangle").frame(minWidth: 52, minHeight: 52)
                    } else {
                        Label("Timeline", systemImage: "list.bullet.rectangle")
                    }
                }
                .accessibilityLabel("Timeline")
                .accessibilityIdentifier("playback.timeline.button")
                Spacer(minLength: 4)
                if dynamicTypeSize.isAccessibilitySize {
                    listeningOptionsButton
                } else {
                    Button(action: model.openMargins) {
                        Label("Margins", systemImage: "quote.bubble")
                    }
                    .accessibilityIdentifier("playback.margins.button")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.white)
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            .id("playback.timeline")
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
        .background(AppColors.listeningBackground)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.18)).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("playback.controls")
    }

    private var listeningOptionsButton: some View {
        Button {
            isPlaybackOptionsPresented = true
        } label: {
            if dynamicTypeSize.isAccessibilitySize {
                Image(systemName: "ellipsis").frame(minWidth: 52, minHeight: 52)
            } else {
                Label("More", systemImage: "ellipsis")
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
                            Text(MarginRow(interjection: note, itemTitle: model.selectedItem.title, sessionDate: nil).preview)
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
        withAnimation(.snappy(duration: 0.34)) {
            model.openTimeline()
        }
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
        case .write: model.beginWrittenMargin()
        }
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
                Text(model.importedCommentaryIsPaused ? "Paused" : "Playing at \(model.playingInterjectionAudioRate.formatted(.number.precision(.fractionLength(0...2))))× to match the item")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.72))
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
        if let moment = model.marginMoment {
            VStack(alignment: .leading, spacing: 10) {
                if moment.isPlayingMargin {
                    Label(model.marginMomentVoiceIsPaused ? "\(model.marginMomentTitle) is paused" : "Playing \(model.marginMomentTitle)",
                          systemImage: "waveform")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Button("Skip to the item", systemImage: "forward.end.fill", action: model.skipMarginMomentVoice)
                        .buttonStyle(SecondaryButtonStyle())
                        .accessibilityIdentifier("marginMoment.skip")
                } else if let remaining = moment.msUntilTarget(currentMediaTimeMs: model.snapshot.currentMediaTimeMs) {
                    Label("\(model.marginMomentTitle) in \(Self.marginMomentCountdown(remaining))", systemImage: "text.bubble")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
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

    private static func marginMomentCountdown(_ ms: Int) -> String {
        let seconds = max(0, Int((Double(ms) / 1000).rounded(.up)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var playbackHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: model.openCurrentPlaybackItem) {
                Text(model.playbackItemHeaderTitle)
                    .font(.system(.largeTitle, design: .serif).weight(.medium))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityHint("Opens item details and listening-session history")
            .accessibilityIdentifier("playback.itemTitle.button")

            if let chapterTitle = model.playbackChapterHeaderTitle {
                Button(action: model.openCurrentPlaybackItem) {
                    Text(chapterTitle)
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(.white.opacity(0.82))
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityHint("Opens item details and listening-session history")
                .accessibilityIdentifier("playback.chapterTitle.button")
            }

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
                    preparedFraction: model.renderedFractionForPlayback
                )
                .tint(AppColors.accent)
                .accessibilityLabel("Playback position")
                .accessibilityHint(model.renderedFractionForPlayback.map { "Prepared audio through \(Int($0 * 100)) percent of source" } ?? "")
                .accessibilityValue("\(formatPlaybackTime(Int(scrubberDisplaySeconds * 1_000))) of \(formatPlaybackTime(mediaDurationMs))")
                .accessibilityIdentifier("playback.scrubber")
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
                    preparedFraction: model.renderedFractionForPlayback
                )
                .tint(AppColors.accent)
                .accessibilityLabel("Playback position")
                .accessibilityHint(model.renderedFractionForPlayback.map { "Prepared audio through \(Int($0 * 100)) percent of source" } ?? "")
                .accessibilityValue("\(textScrubberPercent) percent")
                .accessibilityIdentifier("playback.scrubber")
                .onCompatibleChange(of: canonicalTextOffset) { value in
                    model.recordDeveloperDiagnostic("scrub.text.display", ["canonical": String(value), "displayed": String(textScrubState.displayedValue(canonicalValue: value, range: textScrubRange)), "editing": String(textScrubState.isEditing), "range": String(textScrubRange.upperBound)])
                }
                .disabled(model.snapshot.isRecording)
                Text("100%")
                    .frame(minWidth: 34, alignment: .leading)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(AppColors.watchSecondary)
        } else {
            HStack(spacing: 8) {
                Text("\(model.displayPlaybackProgressPercent)%")
                    .frame(minWidth: 34, alignment: .trailing)
                    .accessibilityIdentifier("playback.progress.label")
                ProgressView(value: Double(model.displayPlaybackProgressPercent), total: 100)
                    .tint(AppColors.accent)
                    .overlay(alignment: .bottomLeading) {
                        if let fraction = model.renderedFractionForPlayback {
                            GeometryReader { geometry in
                                Capsule().fill(Color(uiColor: .systemTeal))
                                    .frame(width: geometry.size.width * fraction, height: 3).offset(y: 7)
                            }.allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                    .accessibilityLabel("Playback progress")
                    .accessibilityHint(model.renderedFractionForPlayback.map { "Prepared audio through \(Int($0 * 100)) percent of source" } ?? "")
                    .accessibilityValue("\(model.displayPlaybackProgressPercent) percent")
                Text("100%")
                    .frame(minWidth: 34, alignment: .leading)
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
                    Image(systemName: model.isMediaPlaybackSnapshot ? "gobackward.\(model.mediaSkipBackSeconds)" : "backward.end.fill")
                }
                .buttonStyle(RoundPlaybackButtonStyle())
                .disabled(!model.hasActiveSession)
                .accessibilityLabel(model.isMediaPlaybackSnapshot ? "Back \(model.mediaSkipBackSeconds) seconds" : "Previous \(model.skipUnit)")
                .accessibilityIdentifier("playback.back.button")

                Button(action: model.playPause) {
                    Group {
                        if model.snapshot.status == .starting {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: model.snapshot.phase == .finished && model.playingImportedCommentary == nil ? "arrow.counterclockwise" : (model.snapshot.skimBridgeState?.status == .playing
                                || model.activePlaybackIsPlaying ? "pause.fill" : "play.fill"))
                        }
                    }
                }
                .buttonStyle(MainPlaybackButtonStyle())
                .accessibilityLabel(model.snapshot.phase == .finished && model.playingImportedCommentary == nil ? "Replay in a new session" : (model.snapshot.skimBridgeState?.status == .playing
                    || model.activePlaybackIsPlaying ? "Pause" : "Play"))
                .accessibilityIdentifier("playback.play.button")

                Button {
                    if model.isMediaPlaybackSnapshot {
                        model.skipForwardMedia()
                    } else {
                        model.skipForward()
                    }
                } label: {
                    Image(systemName: model.isMediaPlaybackSnapshot ? "goforward.\(model.mediaSkipForwardSeconds)" : "forward.end.fill")
                }
                .buttonStyle(RoundPlaybackButtonStyle())
                .disabled(!model.hasActiveSession)
                .accessibilityLabel(model.isMediaPlaybackSnapshot ? "Forward \(model.mediaSkipForwardSeconds) seconds" : "Next \(model.skipUnit)")
                .accessibilityIdentifier("playback.forward.button")
            }

            if model.isMediaPlaybackSnapshot,
               model.snapshot.canSkimBackward || model.snapshot.canSkimForward || model.snapshot.skimBridgeState != nil {
                HStack(spacing: 14) {
                    Button(action: model.skimBackward) {
                        Label(model.skimBackwardTitle, systemImage: "backward.end.alt.fill")
                    }
                    .disabled(!model.snapshot.canSkimBackward)
                    .accessibilityLabel(model.skimBackwardTitle + " by scene summary")
                    .accessibilityIdentifier("playback.skim.backward.button")

                    Button(action: model.skimForward) {
                        Label(model.skimForwardTitle, systemImage: "forward.end.alt.fill")
                    }
                    .disabled(!model.snapshot.canSkimForward)
                    .accessibilityLabel(model.skimForwardTitle + " by scene summary")
                    .accessibilityIdentifier("playback.skim.forward.button")
                }
                .buttonStyle(.bordered)
                .font(.caption.weight(.semibold))
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
            Button(state == .availableOffline ? "Download Again" : "Download Audio", action: model.redownloadSelectedPodcast)
                .disabled(state == .downloading)
                .accessibilityIdentifier("playback.download.button")
        }

        if model.snapshot.targetType == TargetType.itemTextTTS.rawValue {
            Button {
                sourceTextOffsetAtPresentation = model.snapshot.currentTextStart ?? 0
                isSourceTextPresented = true
            } label: {
                if usesVerbosePlaybackActions {
                    PlaybackControlLabel(title: "Text", systemImage: "doc.plaintext")
                    .frame(minHeight: 32)
                } else {
                    Image(systemName: "doc.plaintext")
                    .frame(minWidth: 24, minHeight: 32)
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
            } else {
                Image(systemName: "moon.zzz")
                    .frame(minWidth: 24, minHeight: 32)
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
            } else {
                Text(model.compactPlaybackRateDescription)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .frame(minHeight: 32)
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
        Toggle(
            "Lower Background Audio",
            isOn: Binding(
                get: { model.lowersBackgroundAudio },
                set: { model.setLowersBackgroundAudio($0) }
            )
        )
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
                } else {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(AppColors.accent)
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
                        .tint(.red)
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
                if model.canPlayLiveSpeechInstead {
                    Button(action: model.playLiveSpeechInstead) {
                        Label("Play Live Speech Instead", systemImage: "speaker.wave.2")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("playback.liveSpeechFallback.button")
                }
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

    private var canonicalTextOffset: Double {
        Double(model.snapshot.currentTextStart ?? 0)
    }

    private var textScrubRange: ClosedRange<Double> {
        0...Double(textLength)
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
                    Spacer()
                    Text("Conversation")
                        .font(.headline)
                    Button {
                        isPastingAssistantResponse = true
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
                                    .accessibilityLabel("Copy interjections for \(turnTitle(turn))")
                                    .accessibilityIdentifier("conversation.copyTurnInterjections.\(turn.id)")
                                    Button {
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

struct SourceFollowSuggestionCard: View {
    enum Appearance: Equatable {
        case standard
        case playback
    }

    @EnvironmentObject private var model: Gate1AppModel
    var appearance: Appearance = .standard

    var body: some View {
        if !model.sourceFollowSuggestionCandidates.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("Keep up with this source?", systemImage: "dot.radiowaves.left.and.right")
                    .font(.headline)
                Text("Following only adds future entries to your source inbox. Nothing is imported, downloaded, or prepared automatically.")
                    .font(.caption)
                    .foregroundStyle(secondaryColor)
                ForEach(model.sourceFollowSuggestionCandidates) { candidate in
                    Button {
                        model.acceptSourceFollowSuggestion(candidate)
                    } label: {
                        VStack(alignment: .leading) {
                            Text("Follow \(candidate.displayName)")
                            if model.sourceFollowSuggestionCandidates.filter({ $0.source.title == candidate.source.title }).count > 1 {
                                Text(candidate.source.canonicalURL).font(.caption).lineLimit(2)
                            }
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("source.followSuggestion.accept.\(candidate.id)")
                }
                HStack {
                    Button("Not now", action: model.deferSourceFollowSuggestion)
                        .accessibilityIdentifier("source.followSuggestion.notNow")
                    Button("Don't suggest", role: .destructive, action: model.rejectSourceFollowSuggestion)
                        .accessibilityIdentifier("source.followSuggestion.never")
                }
                .font(.caption)
            }
            .padding(appearance == .playback ? 16 : 10)
            .frame(maxWidth: appearance == .playback ? 430 : .infinity, alignment: .leading)
            .foregroundStyle(foregroundColor)
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: appearance == .playback ? 18 : 12))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("source.followSuggestion.card")
        }
    }

    private var foregroundColor: Color {
        appearance == .playback ? .white : AppColors.text
    }

    private var secondaryColor: Color {
        appearance == .playback ? AppColors.watchSecondary : AppColors.secondaryText
    }

    private var backgroundColor: Color {
        appearance == .playback ? AppColors.watchBackground : AppColors.watchControl.opacity(0.35)
    }
}

struct ManualSourceFollowButton: View {
    @EnvironmentObject private var model: Gate1AppModel
    var appearance: SourceFollowSuggestionCard.Appearance = .standard

    var body: some View {
        if model.canManuallyFollowSelectedSource {
            Button(action: model.followSelectedSource) {
                HStack {
                    if model.isFollowingSelectedSource {
                        ProgressView()
                    } else {
                        Image(systemName: model.manualFollowButtonSymbol)
                    }
                    Text(model.manualFollowButtonTitle)
                }
                .frame(maxWidth: appearance == .playback ? 430 : .infinity)
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(model.isFollowingSelectedSource)
            .accessibilityIdentifier("source.followCurrent.button")
        }
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
                        Image(systemName: "xmark")
                            .frame(width: 32, height: 32)
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
            Text("Practice making an Margin")
                .font(.title3.bold())
            Text("Let the welcome source play until an idea occurs to you, then record a short note. Spoken Margins will anchor it to this listening session.")
                .foregroundStyle(AppColors.secondaryText)
            if model.snapshot.isRecording {
                Button("Done Recording", action: model.finishInterjection)
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("onboarding.interjection.done.button")
            } else {
                Button("Make an Interjection", action: model.beginInterjection)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!model.hasActiveSession)
                    .accessibilityIdentifier("onboarding.interjection.start.button")
            }
        case .reviewTimeline:
            Text("Use the timeline")
                .font(.title3.bold())
            Text("Tap your saved Margin to review it, or tap any source chapter to jump there. Either action completes this step.")
                .foregroundStyle(AppColors.secondaryText)
            Button("Show Timeline", action: showTimeline)
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("onboarding.timeline.show.button")
        case .optionalAI:
            Text("AI is optional")
                .font(.title3.bold())
            Text(model.remoteProviderExperienceEnabled
                ? "Summarize Notes synthesizes this session’s interjections. Discuss answers a question using relevant source and session context. Both require your OpenAI API key, network access, and permission to send content."
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
            Text("Open the session export, then share it or copy its Markdown or JSON. Completion is recorded only after a share succeeds or the export is copied.")
                .foregroundStyle(AppColors.secondaryText)
            Button("Open Session Export", action: model.openExport)
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!model.hasActiveSession)
                .accessibilityIdentifier("onboarding.export.open.button")
        case .complete:
            Text("You know the core loop")
                .font(.title3.bold())
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
                    .background(AppColors.inputBackground)
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

private struct NativeTextPeekView: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let text: String
    let chapters: [Chapter]
    let currentOffset: Int

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(chapterTitle)
                            .font(.headline)
                        Text(chapterText)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppColors.inputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                }
                .padding(20)
            }
            .navigationTitle(title.isEmpty ? "Source Text" : title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
            .accessibilityIdentifier("nativeText.peek.sheet")
        }
    }

    private var selectedChapter: Chapter? {
        guard !chapters.isEmpty else { return nil }
        let offset = max(0, min(currentOffset, text.count))
        return chapters.first(where: { offset >= $0.startChar && offset < $0.endChar })
            ?? chapters.last(where: { $0.startChar <= offset })
            ?? chapters.first
    }

    private var chapterTitle: String {
        selectedChapter?.title ?? "Full Text"
    }

    private var chapterText: String {
        guard !text.isEmpty else { return "No native text is available." }
        guard let chapter = selectedChapter else { return text }
        let characters = Array(text)
        let start = max(0, min(chapter.startChar, characters.count))
        let end = max(start, min(chapter.endChar, characters.count))
        return String(characters[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
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

struct InterjectionDetailView: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dismiss) private var dismiss
    let interjection: Interjection
    @State private var pendingDeletion: PendingInterjectionDeletion?
    @State private var copied = false
    @State private var privateSharingNoteDraft = ""

    private enum PendingInterjectionDeletion: Equatable {
        case transcript
        case interjection
    }

    private var currentInterjection: Interjection {
        model.selectedItem.interjections.first(where: { $0.id == interjection.id && $0.sessionId == interjection.sessionId && $0.itemId == interjection.itemId }) ?? interjection
    }

    var body: some View {
        let current = currentInterjection
        NavigationStack {
            List {
                Section("Context") {
                    if let session = model.selectedItem.sessions.first(where: { $0.id == current.sessionId }) {
                        LabeledContent("Listening session", value: sessionDateDescription(session))
                        LabeledContent("Session position", value: sessionProgressDescription(session))
                    }
                    LabeledContent("Attached to", value: interjectionTargetLabel(current))
                    LabeledContent(
                        "Position",
                        value: InterjectionPositionPresentation.detailDescription(
                            for: current,
                            durationMs: model.selectedItem.mediaDurationMs
                                ?? (model.snapshot.itemId == model.selectedItem.id ? model.snapshot.currentPlaybackDurationMs : nil)
                        )
                    )
                    if current.transcriptionStatus != "complete" {
                        LabeledContent("Transcript status", value: TranscriptionFailureWording.marginStatus(transcriptionStatus: current.transcriptionStatus, speechRecognitionOff: SpeechRecognitionAccess.isOff) ?? humanizedTurnStatus(current.transcriptionStatus))
                    }
                }
                Section("Transcript") {
                    Text(current.cleanedTranscript ?? current.transcript ?? "No transcript yet.")
                        .textSelection(.enabled)
                    if current.captureKind != .written {
                    Button {
                        model.toggleInterjectionAudioPlayback(current)
                    } label: {
                        Label(
                            model.isPlayingInterjectionAudio(current) ? "Stop playing" : "Play Margin",
                            systemImage: model.isPlayingInterjectionAudio(current) ? "stop.fill" : "play.fill"
                        )
                    }
                    .disabled(current.audioPath == nil)
                    .accessibilityIdentifier("interjection.detail.playRecording")
                    }
                    Button {
                        model.copyInterjectionWithContext(current)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copied = false
                        }
                    } label: {
                        Label(copied ? "Copied" : "Copy Transcript and Anchors", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityIdentifier("interjection.detail.copy")
                    if current.captureKind != .written {
                    Button {
                        model.retryInterjectionTranscription(current)
                    } label: {
                        if model.isRetryingInterjectionTranscription(current) {
                            Label("Retranscribing Saved Audio", systemImage: "waveform.badge.magnifyingglass")
                        } else {
                            Label("Retranscribe Saved Audio", systemImage: "waveform")
                        }
                    }
                    .disabled(current.audioPath == nil || model.isRetryingInterjectionTranscription(current))
                    .accessibilityIdentifier("interjection.detail.retryTranscription")
                    Button("Delete Transcript") {
                        pendingDeletion = .transcript
                    }
                    .disabled(current.transcript == nil && current.cleanedTranscript == nil)
                    .accessibilityIdentifier("interjection.detail.deleteTranscript")
                    }
                }
                Section("Share later") {
                    Toggle(
                        "Star for sharing",
                        isOn: Binding(
                            get: { currentInterjection.isStarredForSharing == true },
                            set: {
                                model.setInterjectionStarredForSharing(current.id, sessionId: current.sessionId, starred: $0)
                            }
                        )
                    )
                    .accessibilityIdentifier("interjection.detail.shareStar")
                    TextField("Private note for sender review", text: $privateSharingNoteDraft, axis: .vertical)
                        .lineLimit(2...5)
                        .onCompatibleChange(of: privateSharingNoteDraft) { value in
                            if value.count > Gate1AppModel.privateSharingNoteCharacterLimit {
                                privateSharingNoteDraft = String(value.prefix(Gate1AppModel.privateSharingNoteCharacterLimit))
                            }
                        }
                        .accessibilityIdentifier("interjection.detail.privateSharingNote")
                    HStack {
                        Text("\(privateSharingNoteDraft.count)/\(Gate1AppModel.privateSharingNoteCharacterLimit)")
                            .font(.caption2)
                            .foregroundStyle(AppColors.secondaryText)
                        Spacer()
                        Button("Save Note") {
                            model.setInterjectionPrivateSharingNote(current.id, sessionId: current.sessionId, note: privateSharingNoteDraft)
                        }
                        .disabled(privateSharingNoteDraft == (current.privateSharingNote ?? ""))
                        .accessibilityIdentifier("interjection.detail.savePrivateSharingNote")
                    }
                    Text("This note helps you choose what to send. It stays private and is never included in a shared package.")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                }
                Section("Anchors") {
                    LabeledContent("Context status", value: anchorContextStatusLabel(current))
                    Text("Before")
                        .font(.headline)
                    Text(anchorContextText(current.anchor.anchorBefore, status: current.captureKind == .written ? .unavailable : current.anchorContextStatus))
                        .textSelection(.enabled)
                    Text("After")
                        .font(.headline)
                    Text(anchorContextText(current.anchor.anchorAfter, status: current.captureKind == .written ? .unavailable : current.anchorContextStatus))
                        .textSelection(.enabled)
                    if current.captureKind != .written, current.anchorContextStatus == .unavailable {
                        Button("Retry Context") {
                            model.retryAnchorContext(current)
                        }
                        .accessibilityIdentifier("interjection.detail.retryContext")
                    }
                }
                Section {
                    Button(role: .destructive) {
                        pendingDeletion = .interjection
                    } label: {
                        Label("Delete Interjection", systemImage: "trash")
                    }
                    .accessibilityIdentifier("interjection.detail.delete")
                }
            }
            .navigationTitle("Manage Margin")
            .onAppear {
                privateSharingNoteDraft = current.privateSharingNote ?? ""
            }
            .onDisappear {
                if model.selectedItem.interjections.contains(where: { $0.id == current.id }),
                   privateSharingNoteDraft != (current.privateSharingNote ?? "") {
                    model.setInterjectionPrivateSharingNote(current.id, sessionId: current.sessionId, note: privateSharingNoteDraft)
                }
                model.stopInterjectionAudioPlayback()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier("interjection.detail.close")
                }
            }
            .confirmationDialog(
                pendingDeletion == .transcript ? "Delete this transcript?" : "Delete this interjection?",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                if pendingDeletion == .transcript {
                    Button("Delete Transcript", role: .destructive) {
                        model.deleteTranscript(interjection: current)
                        pendingDeletion = nil
                        dismiss()
                    }
                } else {
                    Button("Delete Interjection", role: .destructive) {
                        model.deleteInterjection(current)
                        pendingDeletion = nil
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
            }
        }
    }
}

private func anchorContextStatusLabel(_ interjection: Interjection) -> String {
    if interjection.captureKind == .written {
        return interjection.anchor.anchorBefore.isEmpty && interjection.anchor.anchorAfter.isEmpty ? "Unavailable" : "Ready"
    }
    if let status = interjection.anchorContextStatus {
        switch status {
        case .pending: return "Pending"
        case .ready: return "Ready"
        case .unavailable: return "Unavailable — retry when audio is available"
        }
    }
    return interjection.anchor.anchorBefore.isEmpty && interjection.anchor.anchorAfter.isEmpty ? "Pending" : "Ready"
}

private func anchorContextText(_ value: String, status: AnchorContextStatus?) -> String {
    guard value.isEmpty else { return value }
    switch status {
    case .pending, .none: return "Preparing context…"
    case .unavailable: return "Context unavailable"
    case .ready: return "No nearby speech was recognized"
    }
}

struct ProductPanel<Content: View>: View {
    let isHighlighted: Bool
    @ViewBuilder let content: Content

    init(isHighlighted: Bool = false, @ViewBuilder content: () -> Content) {
        self.isHighlighted = isHighlighted
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(AppColors.text)
            .background(isHighlighted ? AppColors.softGreen : AppColors.panel)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(isHighlighted ? AppColors.green : AppColors.border, lineWidth: isHighlighted ? 2 : 1))
    }
}

extension Interjection: @retroactive Identifiable {}

private struct EdgeSwipeBackModifier: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        content.overlay(alignment: .leading) {
            if enabled {
                // Attach recognition only to the edge. A gesture on the entire
                // screen competes with slider tracking even when its action
                // later rejects a drag that started away from the edge.
                GeometryReader { geometry in
                    // Native back buttons can overlap the leading edge on
                    // iOS 18. Keep the gesture below the navigation bar so
                    // those buttons receive ordinary center taps.
                    let topClearance = geometry.safeAreaInsets.top + 64
                    Color.clear
                        .frame(width: 32, height: max(0, geometry.size.height - topClearance))
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 18, coordinateSpace: .global)
                                .onEnded { value in
                                    let horizontal = value.translation.width
                                    let vertical = abs(value.translation.height)
                                    guard horizontal >= 72, horizontal > vertical * 1.4 else { return }
                                    action()
                                }
                        )
                        .offset(y: topClearance)
                        .accessibilityHidden(true)
                }
                .frame(width: 32)
            }
        }
    }
}

private extension View {
    func edgeSwipeBack(enabled: Bool, action: @escaping () -> Void) -> some View {
        modifier(EdgeSwipeBackModifier(enabled: enabled, action: action))
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
                                .foregroundStyle(AppColors.primaryAction)
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
                        .foregroundStyle(isStarred ? Color.yellow : AppColors.secondaryText)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isStarred ? "Remove sharing star" : "Star Margin for sharing")
                .accessibilityValue(isStarred ? "Starred" : "Not starred")
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
    switch turn.turnType {
    case "interjection_summary":
        return "Interjection Summary \(turnSequenceNumber(turn.id) ?? 1)"
    case "assistant_response":
        if let number = turnSequenceNumber(turn.id) {
            return "AI Response \(number)"
        }
        return "AI Response"
    case "user_response":
        return "Follow-up"
    default:
        return turn.turnType.replacingOccurrences(of: "_", with: " ").capitalized
    }
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

private func turnSequenceNumber(_ id: String) -> Int? {
    guard let raw = id.split(separator: "-").last,
          let value = Int(raw) else {
        return nil
    }
    return value
}

func humanizedItemStatus(_ status: String) -> String {
    switch status {
    case "needs_listening_map": return "Ready to listen"
    case "ready": return "Ready"
    case "in_progress": return "In progress"
    case "finished": return "Finished"
    case "map_needs_repair": return "Map needs attention"
    default: return status.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private func humanizedTurnStatus(_ status: String) -> String {
    switch status {
    case "complete": return "Ready"
    case "streaming": return "Generating"
    case "failed_partial": return "Needs retry"
    case "pending": return "Waiting"
    default: return status.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private func interjectionTargetLabel(_ interjection: Interjection) -> String {
    switch interjection.targetType {
    case .item: return "Source"
    case .assistantTurn: return "AI response"
    case .summaryTurn: return "Interjection summary"
    }
}

private func formatPlaybackTime(_ milliseconds: Int) -> String {
    let totalSeconds = max(0, milliseconds / 1_000)
    let hours = totalSeconds / 3_600
    let minutes = (totalSeconds % 3_600) / 60
    let seconds = totalSeconds % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%d:%02d", minutes, seconds)
}

func sessionDateDescription(_ session: Session) -> String {
    guard let date = session.createdAt ?? session.updatedAt else { return "Older session" }
    return date.formatted(date: .abbreviated, time: .shortened)
}

func sessionProgressDescription(_ session: Session) -> String {
    if let mediaTimeMs = session.position.mediaTimeMs, mediaTimeMs > 0 {
        return "\(formatPlaybackTime(mediaTimeMs)) · \(session.completionPercent)% complete"
    }
    return "\(session.completionPercent)% complete"
}

enum AppLinks {
    static var privacy: URL {
        URL(string: "https://spokenmargins.proximitytoprogress.com/privacy/") ?? URL(fileURLWithPath: "/")
    }

    static var support: URL {
        URL(string: "https://spokenmargins.proximitytoprogress.com/support/") ?? URL(fileURLWithPath: "/")
    }

    static var versionDescription: String {
        BuildIdentity.describe(info: Bundle.main.infoDictionary ?? [:])
    }
}

enum AppColors {
    static let listeningBackground = dynamicColor(AppSemanticColorRGB.listeningBackground)
    static let captureBackground = dynamicColor(AppSemanticColorRGB.captureBackground)
    static let listeningAccent = dynamicColor(AppSemanticColorRGB.listeningAccent)
    static let background = dynamicColor(AppSemanticColorRGB.background)
    static let panel = dynamicColor(AppSemanticColorRGB.panel)
    static let inputBackground = dynamicColor(light: (0.98, 0.99, 0.97), dark: (0.10, 0.12, 0.11))
    static let border = dynamicColor(light: (0.84, 0.87, 0.81), dark: (0.28, 0.34, 0.30))
    static let text = dynamicColor(AppSemanticColorRGB.text)
    static let secondaryText = dynamicColor(AppSemanticColorRGB.secondaryText)
    static let green = dynamicColor(light: (0.13, 0.43, 0.30), dark: (0.50, 0.84, 0.62))
    static let primaryAction = dynamicColor(AppSemanticColorRGB.primaryAction)
    static let softGreen = dynamicColor(AppSemanticColorRGB.softGreen)
    static let accent = dynamicColor(light: (0.48, 0.82, 0.59), dark: (0.56, 0.89, 0.67))
    static let accentSoft = dynamicColor(light: (0.67, 0.91, 0.72), dark: (0.25, 0.39, 0.28))
    static let watchBackground = Color(red: 0.09, green: 0.13, blue: 0.11)
    static let watchControl = Color(red: 0.18, green: 0.24, blue: 0.21)
    static let watchSecondary = dynamicColor(AppSemanticColorRGB.listeningSecondary)
    static let dangerText = dynamicColor(AppSemanticColorRGB.dangerText)
    static let dangerBackground = dynamicColor(AppSemanticColorRGB.dangerBackground)
    static let interjectText = dynamicColor(AppSemanticColorRGB.captureText)
    static let bone = dynamicColor(AppSemanticColorRGB.bone)
    static let evergreen = dynamicColor(AppSemanticColorRGB.evergreen)
    static let onEvergreen = dynamicColor(AppSemanticColorRGB.onEvergreen)
    static let ochre = dynamicColor(light: (0.76, 0.52, 0.16), dark: (0.94, 0.72, 0.32))
    static let coral = dynamicColor(light: (0.70, 0.27, 0.20), dark: (1.00, 0.57, 0.48))
    static let plum = dynamicColor(AppSemanticColorRGB.plum)

    private static func dynamicColor(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        #if canImport(UIKit)
        return Color(UIColor { traits in
            let values = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: values.0, green: values.1, blue: values.2, alpha: 1)
        })
        #else
        return Color(red: light.0, green: light.1, blue: light.2)
        #endif
    }

    private static func dynamicColor(_ colors: AppDynamicRGB) -> Color {
        #if canImport(UIKit)
        return Color(UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? colors.dark : colors.light
            return UIColor(red: value.red, green: value.green, blue: value.blue, alpha: 1)
        })
        #else
        return Color(red: colors.light.red, green: colors.light.green, blue: colors.light.blue)
        #endif
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .foregroundStyle(.white)
            .background(AppColors.primaryAction.opacity(configuration.isPressed ? 0.78 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.horizontal, 14)
            .frame(minHeight: 42)
            .foregroundStyle(AppColors.text)
            .background(AppColors.softGreen.opacity(configuration.isPressed ? 0.7 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
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
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(AppColors.text)
            .background(AppColors.softGreen.opacity(configuration.isPressed ? 0.7 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
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
