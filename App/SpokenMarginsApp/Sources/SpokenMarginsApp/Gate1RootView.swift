import SwiftUI
import SessionKit
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

struct Gate1RootView: View {
    @EnvironmentObject private var model: Gate1AppModel
    @EnvironmentObject private var sharingCoordinator: Build23SharingCoordinator
    @State private var navigation = AppNavigationState()
    @State private var keyboardIsPresented = false

    var body: some View {
        Group {
            if model.snapshot.isRecording || model.isRequestingRecordingPermission {
                ExperienceRecordingView()
            } else {
                switch model.screen {
                case .home:
                    ExperienceRootTabs(navigation: $navigation)
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
            if !model.snapshot.isRecording,
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
            if !model.snapshot.isRecording && model.shouldShowMiniPlayer && !keyboardIsPresented {
                MiniPlayerBar()
                    .padding(.horizontal, 12)
                    .padding(.bottom, model.screen == .home ? 54 : 4)
            }
        }
        .edgeSwipeBack(enabled: !model.recordingNavigationIsLocked && model.screen != .home, action: model.openHome)
        .onAppear {
            model.bootstrapLibraryIfNeeded()
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
            Text("Summarize Notes uses your OpenAI API key to turn this session’s interjections into a spoken debrief. Your session and saved position have not changed.")
        }
    }
}

@MainActor
private struct Build23SenderSharingHost: View {
    @EnvironmentObject private var model: Gate1AppModel
    @ObservedObject var coordinator: Build23SharingCoordinator

    var body: some View {
        Build23SenderSharingExperience(coordinator: coordinator)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if coordinator.verifiedShareFileURL != nil {
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

private struct SourceLinkCandidateReviewView: View {
    @EnvironmentObject private var model: Gate1AppModel
    let review: SourceLinkCandidateReviewState

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(review.result.candidates.enumerated()), id: \.offset) { index, candidate in
                    Button {
                        model.selectSourceLinkCandidate(candidate)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(candidate.title)
                                .font(.headline)
                                .foregroundStyle(AppColors.text)
                            if let show = candidate.showTitle, !show.isEmpty {
                                Text(show)
                                    .foregroundStyle(AppColors.secondaryText)
                            }
                            HStack(spacing: 10) {
                                if let published = candidate.publishedAt, !published.isEmpty {
                                    Text(String(published.prefix(10)))
                                }
                                if let durationMs = candidate.durationMs, durationMs > 0 {
                                    Text(Self.duration(durationMs))
                                }
                                Text("\(Int((candidate.confidence * 100).rounded()))% match")
                            }
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(AppColors.secondaryText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    }
                    .accessibilityIdentifier("sourceLink.candidate.\(index)")
                }
            }
            .navigationTitle("Choose Episode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: model.cancelSourceLinkCandidateReview)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("sourceLink.candidateReview.sheet")
    }

    private static func duration(_ milliseconds: Int) -> String {
        let totalSeconds = milliseconds / 1_000
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

private struct UserFeedbackBanner: View {
    @EnvironmentObject private var model: Gate1AppModel
    let feedback: UserFeedbackEvent

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
            Text(feedback.message)
                .font(.subheadline.weight(.semibold))
                .lineLimit(3)
            Spacer(minLength: 8)
        }
        .padding(12)
        .foregroundStyle(AppColors.text)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppColors.border))
        .padding(.top, 44)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("app.feedback.banner")
        .task(id: feedback.id) {
            #if canImport(UIKit)
            UIAccessibility.post(notification: .announcement, argument: feedback.message)
            #endif
            do {
                try await Task.sleep(for: .seconds(feedback.kind == .success ? 3 : 6))
                model.dismissFeedback(id: feedback.id)
            } catch {}
        }
    }

    private var iconName: String {
        switch feedback.kind {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var iconColor: Color {
        switch feedback.kind {
        case .success: .green
        case .warning: .orange
        case .error: .red
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
                    Text("A live AI request can include the source text needed for the task, your interjection transcripts, the current follow-up, nearby anchors, and recent conversation turns.")
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

private struct HelpScreen: View {
    @EnvironmentObject private var model: Gate1AppModel

    var body: some View {
        NavigationStack {
            List {
                Section("Getting Started") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Learn the core loop")
                                .font(.headline)
                            Spacer()
                            Text("\(model.onboardingCoreCompletedCount) of \(OnboardingStep.core.count)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(AppColors.secondaryText)
                        }
                        ProgressView(
                            value: Double(model.onboardingCoreCompletedCount),
                            total: Double(OnboardingStep.core.count)
                        )
                        .tint(AppColors.primaryAction)
                    }
                    .padding(.vertical, 4)
                    OnboardingChecklistRow(
                        title: "Make your first interjection",
                        isComplete: model.isOnboardingStepComplete(.firstInterjection)
                    )
                    OnboardingChecklistRow(
                        title: "Find it in the timeline",
                        isComplete: model.isOnboardingStepComplete(.reviewedTimeline)
                    )
                    OnboardingChecklistRow(
                        title: "Export or copy a session",
                        isComplete: model.isOnboardingStepComplete(.exportedSession)
                    )
                    Button(
                        model.hasCompletedCoreOnboarding ? "Replay Guided Tour" : "Start or Resume Guided Tour",
                        action: model.startGuidedOnboarding
                    )
                    .accessibilityIdentifier("help.onboarding.start.button")
                    if model.isOnboardingCardDismissed && !model.hasCompletedCoreOnboarding {
                        Button("Show Progress on Home", action: model.restoreOnboardingCard)
                            .accessibilityIdentifier("help.onboarding.restoreCard.button")
                    }
                }
                Section("Bring In Your Content") {
                    Text("These are optional ways to build your library. You do not need to try every source type to finish onboarding.")
                        .foregroundStyle(AppColors.secondaryText)
                    OnboardingChecklistRow(
                        title: "Add one source of your own",
                        isComplete: model.isOnboardingStepComplete(.addedOwnSource)
                    )
                    OnboardingChecklistRow(
                        title: "Add something from Safari",
                        isComplete: model.isOnboardingStepComplete(.addedFromSafari)
                    )
                    OnboardingChecklistRow(
                        title: "Add something from Files",
                        isComplete: model.isOnboardingStepComplete(.addedFromFiles)
                    )
                    OnboardingChecklistRow(
                        title: "Add a podcast",
                        isComplete: model.isOnboardingStepComplete(.addedPodcast)
                    )
                }
                Section("Listening Sessions") {
                    Text("Continue Listening resumes your most recent unfinished session. Start New Session creates a separate listening pass with its own notes.")
                    Text("The X in the mini-player saves your place, stops playback, and hides the mini-player. It does not delete the session.")
                }
                Section("Interjections") {
                    Text("Tap Interject, speak your note, then tap Done. The note stays attached to the session and the point you were hearing.")
                    Text("Playback restarts before transcription runs in the background. A short pause can still occur while the app saves the recording and switches the audio session back to playback.")
                    Text("Open Timeline and tap an interjection to review its recording or transcript.")
                }
                Section("Optional AI") {
                    if model.remoteProviderExperienceEnabled {
                        Text("Summarize Notes synthesizes the interjections in the current session. Discuss answers a question using relevant source and session context.")
                        Text("Both features require your OpenAI API key, network access, and separate permission to send content. Listening, interjections, the timeline, and export work without AI.")
                        Button("Open AI Settings", action: model.openAISettingsFromOnboarding)
                            .accessibilityIdentifier("help.aiSettings.button")
                    } else {
                        Text("Summarize Notes uses Apple’s on-device Foundation Model when available. Listening Maps use publisher chapters for podcasts and deterministic structure for native text.")
                        Text("AI-generated Listening Maps are reserved for a future server-hosted option and are not included in this release.")
                        Text("Discuss and third-party API settings are disabled. Copy your interjections to another chatbot and paste its response into the Conversation section if you want that workflow.")
                        LabeledContent("Availability", value: model.localFoundationModelAvailabilityDescription)
                    }
                }
                Section("Safari Articles") {
                    Text("In Safari, open Manage Extensions and enable Spoken Margins Text. Tap the extension once to send the readable page to Spoken Margins.")
                    Text("For Safari’s Share menu, run the Add Article to Spoken Margins Shortcut. The Add Link field in the app is for podcast, RSS, or direct audio links.")
                }
                Section("Files and PDFs") {
                    Text("From Home, tap Add Source, then Import Text or PDF Files. You can also share a PDF, Markdown file, or text file to Spoken Margins from another app.")
                    Text("PDFs must contain extractable text. Image-only or scanned PDFs need OCR before Spoken Margins can import them.")
                }
                Section("Podcast Links") {
                    Text("Paste a podcast episode, RSS, or direct audio URL into Add Source. For Spotify, share the specific episode; a show or podcast-page link does not identify one episode.")
                }
                Section("Share and Export") {
                    Text("Choose the listening session, format, and included material. Share Session opens the iOS share sheet; Copy puts the generated Markdown or JSON on the clipboard.")
                    Text("From Home, tap Export Sessions to select multiple listening sessions and save one Markdown file per session. Spoken Margins remembers the export folder you choose.")
                }
            }
            .navigationTitle("Help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { model.isHelpPresented = false }
                        .accessibilityIdentifier("help.done.button")
                }
            }
            .accessibilityIdentifier("help.screen")
        }
    }
}

private struct OnboardingChecklistRow: View {
    let title: String
    let isComplete: Bool

    var body: some View {
        Label {
            Text(title)
                .foregroundStyle(isComplete ? AppColors.secondaryText : AppColors.text)
        } icon: {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isComplete ? AppColors.green : AppColors.secondaryText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isComplete ? "Complete" : "Not complete")
    }
}

private struct MiniPlayerBar: View {
    @EnvironmentObject private var model: Gate1AppModel

    var body: some View {
        HStack(spacing: 10) {
            Button(action: model.openPlayback) {
                HStack(spacing: 11) {
                    Image(systemName: "waveform")
                        .font(.headline)
                        .foregroundStyle(AppColors.evergreen)
                        .frame(width: 40, height: 40)
                        .background(AppColors.softGreen, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.playbackItemHeaderTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppColors.text)
                            .lineLimit(1)
                        HStack(spacing: 7) {
                            if let chapter = model.playbackChapterHeaderTitle {
                                Text(chapter).lineLimit(1)
                            }
                            Text("\(model.displayPlaybackProgressPercent)%")
                                .monospacedDigit()
                        }
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                        ProgressView(value: Double(model.displayPlaybackProgressPercent), total: 100)
                            .tint(AppColors.ochre)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Now Playing")
            .accessibilityIdentifier("miniPlayer.open.button")

            Button(action: model.beginInterjection) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(AppColors.coral)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Record an interjection")
            .accessibilityIdentifier("miniPlayer.interject.button")

            Button(action: model.playPause) {
                Group {
                    if model.snapshot.status == .starting {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: model.snapshot.status.isPlaybackActive ? "pause.fill" : "play.fill")
                    }
                }
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(AppColors.evergreen, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.snapshot.status.isPlaybackActive ? "Pause" : "Play")
            .accessibilityIdentifier("miniPlayer.playPause.button")

            Button(action: model.dismissMiniPlayer) {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppColors.secondaryText)
            .accessibilityLabel("Close and save listening session")
            .accessibilityIdentifier("miniPlayer.close.button")
        }
        .padding(.leading, 10)
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

private enum FileImportPresentationError: LocalizedError {
    case missingRequest

    var errorDescription: String? {
        "File import completed without an active import request."
    }
}

private struct HomeScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @FocusState private var focusedField: Field?
    @State private var isFileImporterPresented = false
    @State private var activeFileImportRequest: FileImportRequest?
    @State private var isAddSourcePresented = false
    @State private var pendingTrashItem: LibraryItemRow?
    @State private var suppressSourceLinkBlurSubmission = false
    @State private var previousFocusedField: Field?
    @State private var isQuickAddExpanded = false

    private enum Field {
        case title
        case text
        case sourceLink
        case followedSource
        case librarySearch
    }

    private enum FileImportRequest {
        case obsidianFiles
        case epub
        case audiobook
        case quickFolder
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    header
                    if model.shouldShowOnboardingCard {
                        onboardingCard
                    }
                    followedSources
                    queue
                }
                .padding(20)
                .frame(maxWidth: horizontalSizeClass == .regular ? 840 : .infinity)
                .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("home.screen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack {
                        Button(action: model.openSettings) {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                        .accessibilityIdentifier("home.settings.button")
                        Button(action: model.openHelp) {
                            Image(systemName: "questionmark.circle")
                        }
                        .accessibilityLabel("Help")
                        .accessibilityIdentifier("home.help.button")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(action: model.openBatchExport) {
                        Image(systemName: "square.and.arrow.up.on.square")
                    }
                    .accessibilityLabel("Export sessions")
                    .accessibilityIdentifier("home.batchExport.button")
                    Button {
                        isAddSourcePresented = true
                    } label: {
                        Label("Add Source", systemImage: "plus")
                    }
                    .accessibilityIdentifier("home.addSource.button")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .sheet(isPresented: sourceModalIsPresented) {
                if let review = model.sourceLinkCandidateReview {
                    SourceLinkCandidateReviewView(review: review)
                        .environmentObject(model)
                } else {
                    NavigationStack {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                createItem
                                quickAccessFolder
                            }
                            .padding(20)
                        }
                        .navigationTitle("Add Source")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Close") {
                                    dismissAddSource()
                                }
                            }
                        }
                        .fileImporter(
                            isPresented: $isFileImporterPresented,
                            allowedContentTypes: fileImportAllowedContentTypes,
                            allowsMultipleSelection: activeFileImportRequest == .obsidianFiles,
                            onCompletion: handleFileImportResult
                        )
                    }
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .onAppear { model.resetSourceLinkImportState() }
                    .onCompatibleChange(of: model.sourceLinkImportState) { state in
                        if state == "success" {
                            dismissAddSource()
                        }
                    }
                }
            }
            .alert(
                "Move to Recently Deleted?",
                isPresented: Binding(
                    get: { pendingTrashItem != nil },
                    set: { if !$0 { pendingTrashItem = nil } }
                ),
                presenting: pendingTrashItem
            ) { item in
                Button("Cancel", role: .cancel) {}
                Button("Move to Recently Deleted", role: .destructive) {
                    model.moveItemToTrash(id: item.id)
                    pendingTrashItem = nil
                }
            } message: { item in
                Text("\(item.title) can be restored from Settings.")
            }
            .onCompatibleChange(of: model.sourceLinkCandidateReview?.request.inputURL) { reviewURL in
                if reviewURL != nil {
                    resignSourceInputFocus()
                }
            }
            .onDisappear {
                resignSourceInputFocus()
            }
        }
    }

    private var followedSources: some View {
        ProductPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Quick Add", systemImage: "tray.full")
                        .font(.headline)
                    Spacer()
                    Button { model.refreshQuickAddFeed() } label: {
                        if model.isRefreshingQuickAddFeed { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                    .buttonStyle(IconButtonStyle())
                    .disabled(model.isRefreshingQuickAddFeed)
                    .accessibilityLabel("Refresh Quick Add")
                    .accessibilityIdentifier("quickAdd.refresh.button")
                }
                HStack {
                    TextField("HTTPS feed URL", text: $model.followedSourceURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .focused($focusedField, equals: .followedSource)
                        .accessibilityIdentifier("sources.follow.url")
                    Button("Follow", action: model.followSource)
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(model.followedSourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("sources.follow.button")
                }
                if !model.followedSourceCandidates.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Choose a feed").font(.subheadline.weight(.semibold))
                        ForEach(model.followedSourceCandidates) { candidate in
                            Button {
                                model.followSourceCandidate(candidate)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(candidate.source.title ?? candidate.source.host)
                                    Text(candidate.source.canonicalURL)
                                        .font(.caption2)
                                        .foregroundStyle(AppColors.secondaryText)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                        Button("Cancel", action: model.cancelFollowSourceCandidates)
                            .font(.caption)
                    }
                }
                SourceFollowSuggestionCard()
                if model.hasQuickAccessFolder {
                    Label("Quick Folder · \(model.quickAccessFolderName)", systemImage: "folder")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                        .accessibilityIdentifier("quickAdd.folder.source")
                }
                let quickAddCandidates = model.quickAddCandidates
                if quickAddCandidates.isEmpty {
                    Text("Follow a source or choose a Quick Folder. New feed entries and eligible folder files appear here, but nothing imports until you choose it.")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                } else {
                    ForEach(quickAddCandidates.prefix(isQuickAddExpanded ? quickAddCandidates.count : 3)) { candidate in
                        quickAddCandidateRow(candidate)
                    }
                    if quickAddCandidates.count > 3 {
                        Button(isQuickAddExpanded ? "Show Less" : "Show \(quickAddCandidates.count - 3) More") {
                            withAnimation { isQuickAddExpanded.toggle() }
                        }
                        .font(.caption.weight(.semibold))
                        .accessibilityIdentifier("quickAdd.expand.button")
                    }
                }
                if !model.feedSubscriptions.isEmpty {
                    Menu("Manage Sources") {
                        ForEach(model.feedSubscriptions) { subscription in
                            Button(subscription.state == .muted ? "Unmute \(subscription.source.title ?? subscription.source.host)" : "Mute \(subscription.source.title ?? subscription.source.host)") {
                                model.toggleMuteSource(id: subscription.id)
                            }
                            Button("Unfollow \(subscription.source.title ?? subscription.source.host)", role: .destructive) {
                                model.unfollowSource(id: subscription.id)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func quickAddCandidateRow(_ candidate: QuickAddCandidate) -> some View {
        switch candidate {
        case .localFile(let file):
            QuickAddSwipeRow(
                onImport: { model.importQuickAccessFile(file) },
                onDismiss: { model.dismissQuickAccessFile(file) }
            ) {
                VStack(alignment: .leading, spacing: 5) {
                    Button {
                        model.importQuickAccessFile(file, openWhenFinished: true)
                    } label: {
                        Text(file.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(3)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isImportingSources)
                    .accessibilityHint("Imports and opens this item")
                    quickAddMetadataLine(
                        method: "Quick Folder",
                        source: model.quickAccessFolderName,
                        time: file.modifiedAtDescription,
                        systemImage: "folder",
                        isImporting: model.isImportingSources
                    )
                }
            }
            .accessibilityIdentifier("quickAdd.folder.\(file.id)")
        case .followedSource(let entry):
            QuickAddSwipeRow(
                onImport: { model.importFollowedSourceEntry(entry) },
                onDismiss: { model.dismissFollowedSourceEntry(id: entry.id) }
            ) {
                VStack(alignment: .leading, spacing: 5) {
                    Button {
                        model.importFollowedSourceEntry(entry, openWhenFinished: true)
                    } label: {
                        Text(entry.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(3)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.importingFollowedSourceEntryIds.contains(entry.id))
                    .accessibilityHint("Imports and opens this item")
                    quickAddMetadataLine(
                        method: "Followed Feed",
                        source: followedSourceName(for: entry),
                        time: entry.publishedAt.map(relativeDateDescription),
                        systemImage: "dot.radiowaves.left.and.right",
                        isImporting: model.importingFollowedSourceEntryIds.contains(entry.id)
                    )
                }
            }
            .accessibilityIdentifier("sources.entry.\(entry.id)")
        }
    }

    private func followedSourceName(for entry: FeedEntry) -> String {
        if let source = model.feedSubscriptions.first(where: { $0.id == entry.subscriptionId })?.source {
            return source.title ?? source.host
        }
        return URL(string: entry.canonicalURL)?.host ?? entry.author ?? "Source"
    }

    private func relativeDateDescription(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func quickAddMetadataLine(
        method: String,
        source: String?,
        time: String?,
        systemImage: String,
        isImporting: Bool
    ) -> some View {
        let description = [method, source, time]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")

        return HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(description)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if isImporting {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "arrow.left.and.right")
                    .accessibilityHidden(true)
            }
        }
        .font(.caption)
        .foregroundStyle(AppColors.secondaryText)
    }

    private var sourceModalIsPresented: Binding<Bool> {
        Binding(
            get: { isAddSourcePresented || model.sourceLinkCandidateReview != nil },
            set: { isPresented in
                guard !isPresented else { return }
                dismissAddSource()
                if model.sourceLinkCandidateReview != nil {
                    model.cancelSourceLinkCandidateReview()
                }
            }
        )
    }

    private var fileImportAllowedContentTypes: [UTType] {
        switch activeFileImportRequest {
        case .quickFolder:
            return [.folder]
        case .epub:
            return [UTType(filenameExtension: "epub") ?? .data]
        case .audiobook:
            return [.mp3, .mpeg4Audio, .mpeg4Movie, UTType(filenameExtension: "m4b") ?? .audio]
        case .obsidianFiles, .none:
            return [UTType(filenameExtension: "md") ?? .plainText, UTType(filenameExtension: "markdown") ?? .plainText, .plainText, .pdf]
        }
    }

    private func presentFileImporter(_ request: FileImportRequest) {
        activeFileImportRequest = request
        isFileImporterPresented = true
    }

    private func handleFileImportResult(_ result: Result<[URL], Error>) {
        let request = activeFileImportRequest
        activeFileImportRequest = nil
        isFileImporterPresented = false
        switch result {
        case .success(let urls):
            switch request {
            case .obsidianFiles:
                model.importObsidianMarkdownFiles(urls: urls)
                dismissAddSource()
            case .quickFolder:
                if let url = urls.first {
                    model.configureQuickAccessFolder(url: url)
                }
            case .epub:
                if let url = urls.first { model.importEPUBFile(url: url); dismissAddSource() }
            case .audiobook:
                if let url = urls.first { model.importAudiobookFile(url: url); dismissAddSource() }
            case .none:
                model.reportImportFailure(FileImportPresentationError.missingRequest)
            }
        case .failure(let error):
            model.reportImportFailure(error)
        }
    }

    private func resignSourceInputFocus() {
        if focusedField == .sourceLink {
            suppressSourceLinkBlurSubmission = true
        }
        focusedField = nil
    }

    private func dismissAddSource() {
        resignSourceInputFocus()
        isAddSourcePresented = false
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spoken Margins")
                .font(.largeTitle.bold())
            Text("Listen, respond, and keep the useful parts.")
                .font(.subheadline)
                .foregroundStyle(AppColors.secondaryText)
        }
    }

    private var onboardingCard: some View {
        ProductPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Button(action: model.openHelp) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label("Getting Started", systemImage: "questionmark.circle.fill")
                                    .font(.headline)
                                Spacer()
                                Text("\(model.onboardingCoreCompletedCount) of \(OnboardingStep.core.count)")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(AppColors.secondaryText)
                            }
                            ProgressView(
                                value: Double(model.onboardingCoreCompletedCount),
                                total: Double(OnboardingStep.core.count)
                            )
                            .tint(AppColors.primaryAction)
                            Text("Practice the listen, interject, review, and export loop.")
                                .font(.subheadline)
                                .foregroundStyle(AppColors.secondaryText)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home.onboarding.checklist.button")

                    Button(action: model.dismissOnboardingCard) {
                        Image(systemName: "xmark")
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Hide getting started progress")
                    .accessibilityIdentifier("home.onboarding.dismiss.button")
                }
                Button("Continue Guided Tour", action: model.startGuidedOnboarding)
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("home.onboarding.continue.button")
            }
        }
        .accessibilityIdentifier("home.onboarding.card")
    }

    private var createItem: some View {
        ProductPanel {
            VStack(alignment: .leading, spacing: 14) {
                podcastLinkSource
                Divider()
                    .padding(.vertical, 4)
                plainTextSource
            }
        }
    }

    @ViewBuilder
    private var podcastLinkSource: some View {
        Text("Podcast Link")
            .font(.headline)
            .accessibilityIdentifier("addSource.podcast.heading")
        HStack(spacing: 8) {
            TextField("Podcast, RSS, or audio URL", text: $model.sourceLinkURL)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .focused($focusedField, equals: .sourceLink)
                .submitLabel(.go)
                .onSubmit {
                    suppressSourceLinkBlurSubmission = focusedField == .sourceLink
                    focusedField = nil
                    _ = model.beginSourceLinkImportFromForm()
                }
                .accessibilityIdentifier("sourceLink.url.field")
            Button {
                suppressSourceLinkBlurSubmission = focusedField == .sourceLink
                focusedField = nil
                model.pasteSourceLinkFromClipboard()
            } label: {
                Image(systemName: "doc.on.clipboard")
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(IconButtonStyle())
            .accessibilityLabel("Paste Link From Clipboard")
            .accessibilityIdentifier("sourceLink.clipboard.button")
        }
        .onCompatibleChange(of: focusedField) { newValue in
            let oldValue = previousFocusedField
            previousFocusedField = newValue
            guard oldValue == .sourceLink, newValue != .sourceLink else { return }
            if suppressSourceLinkBlurSubmission {
                suppressSourceLinkBlurSubmission = false
            } else if isValidSourceLink(model.sourceLinkURL) {
                _ = model.beginSourceLinkImportFromForm()
            }
        }
        if let message = model.sourceLinkImportMessage {
            HStack(spacing: 8) {
                if model.sourceLinkImportState == "resolving" {
                    ProgressView()
                }
                Text(message)
                    .font(.caption)
                    .foregroundStyle(model.sourceLinkImportState == "failure" ? .red : AppColors.secondaryText)
            }
            .accessibilityIdentifier("sourceLink.import.status")
        }
        Button {
            suppressSourceLinkBlurSubmission = focusedField == .sourceLink
            focusedField = nil
            _ = model.beginSourceLinkImportFromForm()
        } label: {
            if model.isResolvingSourceLink {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Resolving Link")
                }
            } else {
                Label("Add Link and Listen", systemImage: "link.badge.plus")
            }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(model.sourceLinkURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isResolvingSourceLink)
        .accessibilityIdentifier("sourceLink.import.button")
    }

    @ViewBuilder
    private var plainTextSource: some View {
        Text("Plain Text")
            .font(.headline)
            .accessibilityIdentifier("addSource.plainText.heading")
        TextField("Title", text: $model.importTitle)
            .textFieldStyle(.roundedBorder)
            .focused($focusedField, equals: .title)
            .accessibilityIdentifier("create.title.field")
        HStack(alignment: .top, spacing: 8) {
            TextEditor(text: $model.importText)
                .frame(height: model.importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 44 : 120)
                .padding(.horizontal, 4)
                .background(AppColors.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppColors.border))
                .focused($focusedField, equals: .text)
                .accessibilityLabel("Source text")
                .accessibilityIdentifier("create.text.editor")
            Button {
                suppressSourceLinkBlurSubmission = focusedField == .sourceLink
                focusedField = nil
                model.pasteImportTextFromClipboard()
            } label: {
                Image(systemName: "doc.on.clipboard")
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(IconButtonStyle())
            .accessibilityLabel("Paste Text From Clipboard")
            .accessibilityIdentifier("create.text.clipboard.button")
        }
        Button(action: {
            suppressSourceLinkBlurSubmission = focusedField == .sourceLink
            focusedField = nil
            isAddSourcePresented = false
            model.importTextItem()
        }) {
            Label("Add and Listen", systemImage: "plus")
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(model.importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityIdentifier("create.start.button")
        Button {
            suppressSourceLinkBlurSubmission = focusedField == .sourceLink
            focusedField = nil
            presentFileImporter(.obsidianFiles)
        } label: {
            Label("Import Text or PDF Files", systemImage: "doc.badge.plus")
        }
        .buttonStyle(SecondaryButtonStyle())
        .accessibilityIdentifier("obsidian.import.button")
        HStack {
            Button {
                focusedField = nil
                presentFileImporter(.epub)
            } label: {
                Label("Import EPUB", systemImage: "book.closed")
            }
            .buttonStyle(SecondaryButtonStyle())
            .accessibilityIdentifier("epub.import.button")

            Button {
                focusedField = nil
                presentFileImporter(.audiobook)
            } label: {
                Label("Import Audiobook", systemImage: "headphones")
            }
            .buttonStyle(SecondaryButtonStyle())
            .accessibilityIdentifier("audiobook.import.button")
        }
    }

    private func isValidSourceLink(_ value: String) -> Bool {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else { return false }
        return url.host != nil
    }

    private var quickAccessFolder: some View {
        ProductPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Quick Folder", systemImage: "folder")
                        .font(.headline)
                    Spacer()
                    Button {
                        model.refreshQuickAccessFolder()
                    } label: {
                        Group {
                            if model.isRefreshingQuickAccessFolder {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(IconButtonStyle())
                    .disabled(model.isRefreshingQuickAccessFolder)
                    .accessibilityLabel("Refresh Quick Folder")
                    .accessibilityIdentifier("quickFolder.refresh.button")
                }
                Text(model.quickAccessFolderName)
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
                    .lineLimit(2)
                HStack {
                    Button {
                        presentFileImporter(.quickFolder)
                    } label: {
                        Label("Choose Folder", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("quickFolder.choose.button")

                    Button {
                        presentFileImporter(.obsidianFiles)
                    } label: {
                        Label("Open Files", systemImage: "folder")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("quickFolder.openFiles.button")
                }
                if !model.quickAccessRecentFiles.isEmpty {
                    ForEach(model.quickAccessRecentFiles) { file in
                        Button {
                            model.importQuickAccessFile(file)
                            isAddSourcePresented = false
                        } label: {
                            HStack {
                                Image(systemName: "doc.text")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.name)
                                        .font(.subheadline.weight(.semibold))
                                    Text(file.modifiedAtDescription)
                                        .font(.caption)
                                        .foregroundStyle(AppColors.secondaryText)
                                }
                                Spacer()
                                if model.isImportingSources {
                                    ProgressView()
                                } else {
                                    Image(systemName: "plus")
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isImportingSources)
                        .accessibilityIdentifier("quickFolder.recent.\(file.id)")
                    }
                }
            }
        }
    }

    private var queue: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Your Library", systemImage: "music.note.list")
                    .font(.headline)
                Spacer()
            }
            if !model.libraryItems.isEmpty {
                TextField("Search title, source, or author", text: $model.libraryQuery.query)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .librarySearch)
                    .submitLabel(.done)
                    .onSubmit { focusedField = nil }
                    .accessibilityIdentifier("library.search.field")
                HStack {
                    Menu {
                        Picker("Content Type", selection: $model.libraryQuery.contentType) {
                            ForEach(LibraryContentTypeFilter.allCases, id: \.self) { Text($0.rawValue.replacingOccurrences(of: "_", with: " ").capitalized).tag($0) }
                        }
                        Picker("Listening", selection: $model.libraryQuery.listeningState) {
                            ForEach(LibraryListeningStateFilter.allCases, id: \.self) { Text($0.rawValue.replacingOccurrences(of: "_", with: " ").capitalized).tag($0) }
                        }
                        Picker("Offline", selection: $model.libraryQuery.offlineState) {
                            ForEach(LibraryOfflineStateFilter.allCases, id: \.self) { Text($0.rawValue.replacingOccurrences(of: "_", with: " ").capitalized).tag($0) }
                        }
                    } label: {
                        Text(model.libraryFilterDescription)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .transaction { $0.animation = nil }
                    .accessibilityIdentifier("library.filter.menu")
                    Menu(model.librarySortDescription) {
                        Picker("Sort", selection: $model.libraryQuery.sort) {
                            ForEach(LibrarySort.allCases, id: \.self) { Text($0.rawValue.replacingOccurrences(of: "_", with: " ").capitalized).tag($0) }
                        }
                    }
                    .accessibilityIdentifier("library.sort.menu")
                    Spacer()
                }
                .onCompatibleChange(of: model.libraryQuery) { _ in model.libraryQueryChanged() }
            }
            if let libraryAccessError = model.libraryAccessError {
                ProductPanel {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Your library could not be opened", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(AppColors.dangerText)
                        Text(libraryAccessError)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                }
                .accessibilityIdentifier("home.libraryAccessError")
            } else if model.libraryItems.isEmpty {
                ProductPanel {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Your library is empty")
                            .font(.headline)
                        Text("Add pasted text, a podcast link, or a text/PDF file. You can also explore with a sample.")
                            .foregroundStyle(AppColors.secondaryText)
                        HStack {
                            Button {
                                isAddSourcePresented = true
                            } label: {
                                Label("Add Source", systemImage: "plus")
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            Button("Try a Sample", action: model.addSampleItem)
                                .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }
            } else {
                let visibleLibraryItems = model.visibleLibraryItems
                if visibleLibraryItems.isEmpty {
                    ProductPanel { Text("No library items match these filters.").foregroundStyle(AppColors.secondaryText) }
                }
                ForEach(visibleLibraryItems) { item in
                    ProductPanel {
                        HStack(spacing: 12) {
                            Button {
                                model.openItem(id: item.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title)
                                        .font(.headline)
                                        .foregroundStyle(AppColors.text)
                                        .multilineTextAlignment(.leading)
                                        .lineLimit(3)
                                        .truncationMode(.tail)
                                    Text(item.status)
                                        .font(.subheadline)
                                        .foregroundStyle(AppColors.secondaryText)
                                    if item.hasContinuationSession, let progress = item.continuationProgressPercent {
                                        Text("Progress: \(progress)%")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(AppColors.green)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("queue.row.\(item.id)")

                            Button {
                                model.startItem(id: item.id)
                            } label: {
                                Image(systemName: "play.fill")
                                    .frame(width: 42, height: 42)
                            }
                            .buttonStyle(IconButtonStyle())
                            .accessibilityLabel(item.hasContinuationSession ? "Continue \(item.title)" : "Start \(item.title)")
                            .accessibilityIdentifier("queue.start.\(item.id)")

                            if item.canDelete {
                                Button(role: .destructive) {
                                    pendingTrashItem = item
                                } label: {
                                    Image(systemName: "trash")
                                        .frame(width: 42, height: 42)
                                }
                                .buttonStyle(DangerIconButtonStyle())
                                .accessibilityLabel("Move \(item.title) to Recently Deleted")
                                .accessibilityIdentifier("queue.delete.\(item.id)")
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct QuickAddSwipeRow<Content: View>: View {
    let onImport: () -> Void
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content

    @GestureState private var horizontalDrag: CGFloat = 0

    var body: some View {
        ZStack {
            HStack {
                Label("Import", systemImage: "square.and.arrow.down")
                    .foregroundStyle(.white)
                Spacer()
                Label("Dismiss", systemImage: "xmark")
                    .foregroundStyle(.white)
            }
            .font(.caption.weight(.bold))
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(horizontalDrag >= 0 ? AppColors.green : Color.red)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .opacity(abs(horizontalDrag) < 8 ? 0 : 1)

            content()
                .padding(.vertical, 6)
                .padding(.horizontal, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColors.panel)
                .offset(x: horizontalDrag)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .updating($horizontalDrag) { value, state, _ in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    state = max(-120, min(120, value.translation.width))
                }
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height),
                          abs(value.translation.width) >= 72 else { return }
                    if value.translation.width > 0 {
                        onImport()
                    } else {
                        onDismiss()
                    }
                }
        )
        .accessibilityHint("Swipe right to import, or swipe left to dismiss")
        .accessibilityAction(named: "Import") { onImport() }
        .accessibilityAction(named: "Dismiss") { onDismiss() }
    }
}

private struct ItemScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @State private var isTrashConfirmationPresented = false
    @State private var isStartNewConfirmationPresented = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    detailHeader
                    SourceFollowSuggestionCard()
                    ManualSourceFollowButton()
                    actions
                    if !model.selectedItem.overview.isEmpty {
                        overview
                    }
                    listeningMapTools
                    chapters
                    sessions
                    importedCommentary
                }
                .padding(20)
            }
            .accessibilityIdentifier("item.screen")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: model.openHome) {
                        Label("Home", systemImage: "arrow.left")
                    }
                    .accessibilityIdentifier("item.home.button")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !model.selectedItem.id.isEmpty {
                        Button(role: .destructive) {
                            isTrashConfirmationPresented = true
                        } label: {
                            Label("Move to Recently Deleted", systemImage: "trash")
                        }
                        .accessibilityIdentifier("item.delete.button")
                    }
                }
            }
            .alert("Move to Recently Deleted?", isPresented: $isTrashConfirmationPresented) {
                Button("Cancel", role: .cancel) {}
                Button("Move to Recently Deleted", role: .destructive) {
                    model.moveItemToTrash(id: model.selectedItem.id)
                }
            } message: {
                Text("\(model.selectedItem.title) can be restored from Settings.")
            }
        }
    }

    private var detailHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ITEM")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppColors.secondaryText)
            Text(model.selectedItem.title)
                .font(.system(size: 38, weight: .bold))
                .lineLimit(4)
                .minimumScaleFactor(14.0 / 38.0)
                .truncationMode(.tail)
            if !model.selectedItem.externalReference.isEmpty {
                Text(model.selectedItem.externalReference)
                    .font(.footnote)
                    .foregroundStyle(AppColors.secondaryText)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("item.externalReference")
            }
            ViewThatFits(in: .horizontal) {
                HStack {
                    itemMetadataPills
                }
                VStack(alignment: .leading, spacing: 8) {
                    itemMetadataPills
                }
            }
            if let downloadStatus = model.selectedPodcastDownloadDescription {
                HStack(spacing: 10) {
                    Label(downloadStatus, systemImage: model.selectedPodcastDownloadState == .availableOffline ? "arrow.down.circle.fill" : "antenna.radiowaves.left.and.right")
                    if model.selectedPodcastDownloadState == .failed || model.selectedPodcastDownloadState == .evicted {
                        Button("Retry", action: model.retrySelectedPodcastDownload)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(AppColors.secondaryText)
                .accessibilityIdentifier("item.podcastDownload.status")
            }
        }
    }

    @ViewBuilder
    private var itemMetadataPills: some View {
        Pill(humanizedItemStatus(model.selectedItem.status))
        if !model.selectedItem.chapters.isEmpty {
            Pill("\(model.selectedItem.chapters.count) \(model.selectedItem.chapters.count == 1 ? "chapter" : "chapters")")
        }
        if !model.selectedItem.interjections.isEmpty {
                Pill("\(model.selectedItem.interjections.count) Margins")
        }
    }

    private var overview: some View {
        ProductPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "info.circle")
                    Spacer()
                    Text("Overview")
                        .font(.headline)
                }
                Text(model.selectedItem.overview)
                    .font(.body)
                    .lineSpacing(4)
                Button {
                    model.startItem(id: model.selectedItem.id)
                } label: {
                    Label("Read Item", systemImage: "play")
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("item.read.button")
            }
        }
    }

    private var listeningMapTools: some View {
        ProductPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Listening Map", systemImage: "map")
                        .font(.headline)
                    Spacer()
                }
                if model.canGenerateListeningMap {
                    Button {
                        model.generateListeningMap()
                    } label: {
                        Label(model.isGeneratingListeningMap ? "Generating Listening Map" : "Generate Listening Map", systemImage: "sparkles")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.isGeneratingListeningMap)
                    .accessibilityIdentifier("item.generateMap.button")
                } else {
                    Text(model.listeningMapGenerationAvailabilityDescription)
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                }
            }
        }
    }

    private var chapters: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Structure", systemImage: "list.bullet.indent")
                    .font(.headline)
                Spacer()
            }
            if !model.selectedItem.navigation.isEmpty {
                ProductPanel {
                    ExperienceCanonicalNavigationTree(
                        nodes: model.selectedItem.navigation,
                        chapters: model.selectedItem.chapters,
                        action: { model.jumpToChapter($0) }
                    )
                }
            } else if model.selectedItem.chapters.isEmpty {
                ProductPanel {
                    Text("Mapless playback is available. A Listening Map is optional.")
                        .foregroundStyle(AppColors.secondaryText)
                }
            } else {
                ForEach(model.selectedItem.chapters, id: \.id) { chapter in
                    Button {
                        model.jumpToChapter(chapter)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(chapter.percent)%")
                                .font(.headline)
                                .foregroundStyle(AppColors.green)
                            Text(chapter.title)
                                .font(.headline)
                        }
                    }
                    .buttonStyle(PlainPanelButtonStyle())
                    .accessibilityIdentifier("chapter.jump.\(chapter.id)")
                }
            }
        }
    }

    private var sessions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sessions")
                .font(.headline)
            if model.selectedItem.sessionRows.isEmpty {
                ProductPanel {
                    Text("No sessions yet.")
                        .foregroundStyle(AppColors.secondaryText)
                }
            } else {
                ForEach(Array(model.selectedItem.sessionRows.enumerated()), id: \.element.id) { index, row in
                    let session = row.session
                    ProductPanel {
                        HStack(alignment: .top, spacing: 12) {
                            Button {
                                model.openSession(session)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 6) {
                                        Text(sessionDateDescription(session))
                                            .font(.headline)
                                        if model.snapshot.sessionId == session.id {
                                            Text("CURRENT")
                                                .font(.caption2.bold())
                                                .foregroundStyle(AppColors.green)
                                        } else if index == 0 {
                                            Text("MOST RECENT")
                                                .font(.caption2.bold())
                                                .foregroundStyle(AppColors.secondaryText)
                                        }
                                    }
                                    Text(sessionProgressDescription(session))
                                        .font(.subheadline)
                                        .foregroundStyle(AppColors.secondaryText)
                                    Text("\(row.interjectionCount) \(row.interjectionCount == 1 ? "interjection" : "interjections") · \(humanizedItemStatus(session.status))")
                                        .font(.caption)
                                        .foregroundStyle(AppColors.secondaryText)
                                    if let preview = row.interjectionPreview {
                                        Text(preview)
                                            .font(.caption)
                                            .foregroundStyle(AppColors.secondaryText)
                                            .lineLimit(2)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("session.inspect.\(session.id)")

                            VStack(spacing: 8) {
                                Button {
                                    model.resumeSession(session)
                                } label: {
                                    Label(session.completionPercent >= 100 ? "Open" : "Resume", systemImage: "play")
                                }
                                .buttonStyle(SecondaryButtonStyle())
                                Button {
                                    model.openExport(sessionId: session.id)
                                } label: {
                                    Image(systemName: "square.and.arrow.up")
                                        .frame(width: 42, height: 42)
                                }
                                .buttonStyle(IconButtonStyle())
                                .accessibilityLabel("Share this session")
                                .accessibilityIdentifier("session.export.\(session.id)")
                            }
                        }
                    }
                    .accessibilityIdentifier("session.row.\(session.id)")
                }
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                model.startItem(id: model.selectedItem.id)
            } label: {
                Label(model.selectedItemPreferredContinuationSession == nil ? "Start Listening" : "Continue Listening", systemImage: "play.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("item.start.button")
            if model.selectedItemPreferredContinuationSession != nil {
                Button {
                    isStartNewConfirmationPresented = true
                } label: {
                    Label("Start New Session", systemImage: "plus.circle")
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("item.startNew.button")
                .confirmationDialog(
                    "Start a separate listening session?",
                    isPresented: $isStartNewConfirmationPresented,
                    titleVisibility: .visible
                ) {
                    Button("Start New Session") {
                        model.startNewSession(id: model.selectedItem.id)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Your unfinished session and its interjections will remain available to resume.")
                }
            }
            Button(action: model.openExport) {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(SecondaryButtonStyle())
            .accessibilityIdentifier("item.export.button")
            Button(action: model.prepareShareInterjections) {
                Label("Share Margins", systemImage: "person.wave.2")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(model.selectedItem.interjections.filter { $0.status == "active" && $0.targetType == .item }.isEmpty)
            .accessibilityIdentifier("item.shareMargins.button")
            Button {
                model.copyTargetInterjections(targetType: InterjectionTargetType.item.rawValue, targetId: model.selectedItem.id)
            } label: {
                Label("Copy Item Notes", systemImage: "doc.on.doc")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(model.selectedItem.interjections.filter { $0.targetType == .item }.isEmpty)
            .accessibilityIdentifier("item.copyInterjections.button")
        }
    }

    @ViewBuilder
    private var importedCommentary: some View {
        if !model.selectedItem.importedCommentaryLayers.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Shared Margins")
                    .font(.headline)
                ForEach(model.selectedItem.importedCommentaryLayers) { layer in
                    ProductPanel {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(layer.displayLabel?.nilIfEmpty ?? "Unsigned sender")
                                        .font(.headline)
                                    Text("Integrity checked · Sender identity unverified")
                                        .font(.caption)
                                        .foregroundStyle(AppColors.secondaryText)
                                }
                                Spacer()
                                Text("\(model.selectedItem.importedCommentaryInterjections[layer.id]?.count ?? 0)")
                                    .font(.title3.bold())
                            }
                            Text(importedLayerStatus(layer))
                                .font(.caption)
                                .foregroundStyle(layer.sourceResolutionStatus == .ambiguous ? AppColors.dangerText : AppColors.secondaryText)

                            Toggle("Enabled during listening", isOn: Binding(
                                get: { layer.isEnabled },
                                set: { model.setImportedCommentaryLayerEnabled(layer.id, enabled: $0) }
                            ))
                            Toggle("Mute cue", isOn: Binding(
                                get: { layer.isMuted },
                                set: { model.setImportedCommentaryLayerMuted(layer.id, muted: $0) }
                            ))
                            Picker("Reveal mode", selection: Binding(
                                get: { layer.revealMode ?? .companion },
                                set: { model.setImportedCommentaryRevealMode(layer.id, mode: $0) }
                            )) {
                                Text("Fresh").tag(ImportedCommentaryRevealMode.fresh)
                                Text("Companion").tag(ImportedCommentaryRevealMode.companion)
                                Text("Guided").tag(ImportedCommentaryRevealMode.guided)
                            }
                            .pickerStyle(.segmented)

                            ForEach(model.selectedItem.importedCommentaryInterjections[layer.id] ?? []) { margin in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(margin.approvedTranscript)
                                        .font(.callout)
                                    Text(importedAnchorEvidenceLabel(margin.resolution))
                                        .font(.caption2)
                                        .foregroundStyle(AppColors.secondaryText)
                                }
                            }

                            Button(role: .destructive) {
                                model.deleteImportedCommentaryLayer(layer.id)
                            } label: {
                                Label("Delete Shared Margins", systemImage: "trash")
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }
            }
        }
    }

    private func importedLayerStatus(_ layer: ImportedCommentaryLayer) -> String {
        switch layer.sourceResolutionStatus {
        case .pending: return "Waiting for the recipient podcast download."
        case .resolved: return "Anchors resolved for this downloaded edition."
        case .contextOnly: return "Kept for reading; unresolved Margins will not interrupt playback."
        case .ambiguous: return "Anchor evidence was ambiguous; no automatic placement was made."
        case .wrongSource: return "This package does not match this source."
        case .unavailable: return "The referenced passage was not found in this edition."
        }
    }

    private func importedAnchorEvidenceLabel(_ resolution: ImportedAnchorResolution) -> String {
        let label = resolution.evidenceClass.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        if let time = resolution.localMediaTimeMs {
            return "\(label) · \(formatPlaybackTime(time))"
        }
        return label
    }
}

private struct DiscretePlaybackRateSlider: View {
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

    mutating func begin(at canonicalValue: Double, range: ClosedRange<Double>) {
        guard !isEditing else { return }
        draftValue = Self.clamped(canonicalValue, to: range)
        isEditing = true
    }

    mutating func updateFromGesture(_ value: Double, range: ClosedRange<Double>) {
        // The binding setter may run before Slider's editing callback. Claim
        // gesture ownership here so a simultaneous playback tick cannot snap
        // the thumb back to the transport position.
        isEditing = true
        draftValue = Self.clamped(value, to: range)
    }

    mutating func finish() {
        isEditing = false
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
    @State private var followUp = ""
    @State private var selectedInterjection: Interjection?
    @State private var isPastingAssistantResponse = false
    @State private var mediaScrubState = PlaybackScrubState()
    @State private var textScrubState = PlaybackScrubState()
    @State private var isSleepTimerPresented = false
    @State private var isSourceTextPresented = false
    @State private var sourceTextOffsetAtPresentation = 0
    @State private var timelinePullTriggered = false
    @AppStorage("playbackUsesVerboseActions") private var usesVerbosePlaybackActions = true
    @FocusState private var followUpFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ZStack {
                    LinearGradient(
                        colors: [AppColors.watchBackground, AppColors.evergreen.opacity(0.82)],
                        startPoint: .top,
                        endPoint: .bottomTrailing
                    )
                    .ignoresSafeArea()
                    ScrollView {
                        VStack(spacing: 18) {
                            if model.shouldShowGuidedOnboardingCoach {
                                GuidedOnboardingPlaybackCard {
                                    withAnimation {
                                        proxy.scrollTo("playback.timeline", anchor: .top)
                                    }
                                }
                            }
                            playbackControls
                            sessionActionDock
                            SourceFollowSuggestionCard(appearance: .playback)
                            ManualSourceFollowButton(appearance: .playback)
                        }
                        .padding(.horizontal, horizontalSizeClass == .regular ? 36 : 18)
                        .padding(.vertical, 24)
                        .frame(maxWidth: 620)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollBounceBehavior(.always)
                    .onScrollGeometryChange(for: CGFloat.self) { geometry in
                        TimelinePullPresentation.overscrollDistance(
                            contentOffsetY: geometry.contentOffset.y,
                            contentHeight: geometry.contentSize.height,
                            containerHeight: geometry.containerSize.height,
                            bottomInset: geometry.contentInsets.bottom
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
                }
                .accessibilityIdentifier("playback.screen")
                .onCompatibleChange(of: model.guidedOnboardingStage) { stage in
                    if stage == .reviewTimeline {
                        withAnimation {
                            proxy.scrollTo("playback.timeline", anchor: .top)
                        }
                    }
                }
            }
            .toolbarBackground(AppColors.watchBackground.opacity(0.92), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: model.openHome) {
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
                InterjectionDetailView(interjection: interjection)
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
        }
    }

    private var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing")
            || ProcessInfo.processInfo.environment["SPOKEN_MARGINS_UI_TESTING"] == "1"
    }

    private var playbackControls: some View {
        VStack(spacing: 20) {
            Text("NOW PLAYING")
                .font(.caption.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(AppColors.ochre)
            playbackHeader
            importedCommentaryControl
            if isUITesting {
                gate2CompactValidation
            }
            playbackPosition
            playbackTransport
            playbackRateControl
            onDeviceSpeechGenerationControl
            interjectionControls
        }
        .padding(.horizontal, horizontalSizeClass == .regular ? 34 : 22)
        .padding(.vertical, 28)
        .frame(maxWidth: 560)
        .background(Color.black.opacity(0.22))
        .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .stroke(Color.white.opacity(0.14))
        }
        .shadow(color: .black.opacity(0.22), radius: 28, y: 14)
    }

    private var sessionActionDock: some View {
        HStack(spacing: 8) {
            Button(action: model.openCurrentPlaybackItem) {
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

            Button(action: model.openExport) {
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
        withAnimation(.snappy(duration: 0.34)) {
            model.openTimeline()
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
        if let playing = model.playingImportedCommentary {
            VStack(spacing: 8) {
                Text(playing.senderLabel)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Shared Margin \(playing.index) of \(playing.count)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
                Text("Playing at \(model.playingInterjectionAudioRate.formatted(.number.precision(.fractionLength(0...2))))× to match the item")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.72))
                Text(playing.interjection.approvedTranscript)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(3)
                Button("Return to Source", action: model.returnToSourceFromImportedCommentary)
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("importedCommentary.returnToSource")
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
                HStack(spacing: 10) {
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
    }

    private var playbackHeader: some View {
        VStack(spacing: 6) {
            Button(action: model.openCurrentPlaybackItem) {
                Text(model.playbackItemHeaderTitle)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.85)
                    .truncationMode(.tail)
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
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .truncationMode(.tail)
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
                Slider(
                    value: Binding(
                        get: { mediaScrubState.displayedValue(canonicalValue: canonicalMediaSeconds, range: mediaScrubRange) },
                        set: { mediaScrubState.updateFromGesture($0, range: mediaScrubRange) }
                    ),
                    in: mediaScrubRange,
                    onEditingChanged: { editing in
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
                    }
                )
                .tint(AppColors.accent)
                .accessibilityLabel("Playback position")
                .accessibilityValue("\(formatPlaybackTime(Int(scrubberDisplaySeconds * 1_000))) of \(formatPlaybackTime(mediaDurationMs))")
                .accessibilityIdentifier("playback.scrubber")
                .disabled(model.snapshot.isRecording)
                Text("−\(formatPlaybackTime(displayMediaRemainingMs))")
                    .frame(minWidth: 42, alignment: .leading)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(AppColors.watchSecondary)
        } else if model.snapshot.targetType == TargetType.itemTextTTS.rawValue,
                  textLength > 0,
                  model.canShowFullPlaybackScrubber {
            HStack(spacing: 8) {
                Text("\(textScrubberPercent)%")
                    .frame(minWidth: 34, alignment: .trailing)
                    .accessibilityIdentifier("playback.progress.label")
                Slider(
                    value: Binding(
                        get: { textScrubState.displayedValue(canonicalValue: canonicalTextOffset, range: textScrubRange) },
                        set: { textScrubState.updateFromGesture($0, range: textScrubRange) }
                    ),
                    in: textScrubRange,
                    onEditingChanged: { editing in
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
                    }
                )
                .tint(AppColors.accent)
                .accessibilityLabel("Playback position")
                .accessibilityValue("\(textScrubberPercent) percent")
                .accessibilityIdentifier("playback.scrubber")
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
                    .accessibilityLabel("Playback progress")
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
                            Image(systemName: model.snapshot.skimBridgeState?.status == .playing
                                || model.snapshot.status.isPlaybackActive ? "pause.fill" : "play.fill")
                        }
                    }
                }
                .buttonStyle(MainPlaybackButtonStyle())
                .accessibilityLabel(model.snapshot.skimBridgeState?.status == .playing
                    || model.snapshot.status.isPlaybackActive ? "Pause" : "Play")
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
                        Label("Skim Back", systemImage: "backward.end.alt.fill")
                    }
                    .disabled(!model.snapshot.canSkimBackward)
                    .accessibilityLabel("Skim backward by scene summary")
                    .accessibilityIdentifier("playback.skim.backward.button")

                    Button(action: model.skimForward) {
                        Label("Skim Forward", systemImage: "forward.end.alt.fill")
                    }
                    .disabled(!model.snapshot.canSkimForward)
                    .accessibilityLabel("Skim forward by scene summary")
                    .accessibilityIdentifier("playback.skim.forward.button")
                }
                .buttonStyle(.bordered)
                .font(.caption.weight(.semibold))
            }
        }
        .disabled(model.snapshot.isRecording)
    }

    private var playbackRateControl: some View {
        HStack(spacing: 10) {
            if model.snapshot.targetType == TargetType.itemTextTTS.rawValue {
                Button {
                    sourceTextOffsetAtPresentation = model.snapshot.currentTextStart ?? 0
                    isSourceTextPresented = true
                } label: {
                    if usesVerbosePlaybackActions {
                        PlaybackControlLabel(title: "Text", systemImage: "doc.plaintext")
                    } else {
                        Image(systemName: "doc.plaintext")
                    }
                }
                .accessibilityLabel("View native source text")
                .accessibilityIdentifier("playback.sourceText.button")
            }

            Spacer()

            Button {
                isSleepTimerPresented = true
            } label: {
                if usesVerbosePlaybackActions {
                    PlaybackControlLabel(title: model.sleepTimerDescription, systemImage: "moon.zzz")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                } else {
                    Image(systemName: "moon.zzz")
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
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                } else {
                    Text(model.compactPlaybackRateDescription)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
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
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .buttonStyle(.bordered)
        .tint(AppColors.watchControl)
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

    @ViewBuilder
    private var interjectionControls: some View {
        if model.snapshot.isRecording {
            VStack(spacing: 12) {
                Label("Recording", systemImage: "record.circle.fill").foregroundStyle(.red)
                HStack {
                    Button(action: model.finishInterjection) { Label("Done", systemImage: "checkmark") }
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityIdentifier("interjection.done.button")
                    Button(action: model.cancelInterjection) { Label("Cancel", systemImage: "xmark") }
                        .buttonStyle(LightButtonStyle())
                        .accessibilityIdentifier("interjection.cancel.button")
                }
            }
        } else {
            VStack(spacing: 10) {
                if usesVerbosePlaybackActions {
                    HStack(spacing: 10) {
                        if model.aiSummaryExperienceAvailable {
                            Button(action: model.summarize) {
                                HStack(spacing: 6) {
                                    if model.isSummarizingInterjections {
                                        ProgressView()
                                    } else {
                                        Image(systemName: "sparkles")
                                    }
                                    Text(model.summaryActionTitle)
                                }
                                .frame(maxWidth: .infinity, minHeight: 52)
                            }
                            .buttonStyle(WatchSecondaryButtonStyle())
                            .disabled(!model.canSummarizeInterjections || model.isSummarizingInterjections)
                            .accessibilityLabel(model.canRetryLocalSummary ? "Retry summary" : (model.isSummarizingInterjections ? "Summarizing interjections" : "Summarize interjections"))
                            .accessibilityIdentifier("playback.summary.button")
                        }
                        Button(action: model.beginInterjection) {
                            Label(model.interjectionButtonTitle, systemImage: "mic").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(InterjectButtonStyle())
                        .disabled(!model.hasActiveSession)
                        .accessibilityIdentifier("playback.interject.button")
                    }
                    if !model.aiSummaryExperienceAvailable {
                        Text(model.localFoundationModelAvailabilityDescription)
                            .font(.caption)
                            .foregroundStyle(AppColors.watchSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("playback.summary.description")
                    } else if model.remoteProviderExperienceEnabled && !model.hasConfiguredProviderAPIKey {
                        Text("Add an OpenAI API key in Settings to summarize notes or discuss them.")
                            .font(.caption)
                            .foregroundStyle(AppColors.watchSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("playback.summary.description")
                    }
                    if model.remoteProviderExperienceEnabled {
                        Button {
                            followUpFocused = false
                            model.discuss(followUp: followUp)
                        } label: {
                            Label("Discuss", systemImage: "bubble.left.and.bubble.right.fill")
                        }
                        .buttonStyle(LightButtonStyle())
                        .disabled(!model.hasActiveSession || followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("playback.discuss.button")
                    }
                } else {
                    HStack(spacing: 12) {
                        if model.aiSummaryExperienceAvailable {
                            Button(action: model.summarize) {
                                Group {
                                    if model.isSummarizingInterjections {
                                        ProgressView()
                                    } else {
                                        Image(systemName: "sparkles")
                                    }
                                }
                                .frame(maxWidth: .infinity, minHeight: 52)
                            }
                            .buttonStyle(WatchSecondaryButtonStyle())
                            .disabled(!model.canSummarizeInterjections || model.isSummarizingInterjections)
                            .accessibilityLabel(model.canRetryLocalSummary ? "Retry summary" : (model.isSummarizingInterjections ? "Summarizing interjections" : "Summarize interjections"))
                            .accessibilityIdentifier("playback.summary.button")
                        }

                        Button(action: model.beginInterjection) {
                            Image(systemName: "mic")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(InterjectButtonStyle())
                        .disabled(!model.hasActiveSession)
                        .accessibilityLabel(model.interjectionButtonTitle)
                        .accessibilityIdentifier("playback.interject.button")

                        if model.remoteProviderExperienceEnabled {
                            Button {
                                followUpFocused = false
                                model.discuss(followUp: followUp)
                            } label: {
                                Image(systemName: "bubble.left.and.bubble.right.fill")
                                    .frame(maxWidth: .infinity, minHeight: 52)
                            }
                            .buttonStyle(WatchSecondaryButtonStyle())
                            .disabled(!model.hasActiveSession || followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityLabel("Discuss")
                            .accessibilityIdentifier("playback.discuss.button")
                        }
                    }
                }
            }
        }
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
        model.selectedItem.text.count
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
                    Text("No chapters or interjections yet.")
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
        let hasChapters = !model.selectedItem.chapters.isEmpty || !visibleMediaChapters.isEmpty
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
                    Button("Follow \(candidate.source.title ?? candidate.source.host)") {
                        model.acceptSourceFollowSuggestion(candidate)
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
                        Image(systemName: "dot.radiowaves.left.and.right")
                    }
                    Text(model.isFollowingSelectedSource ? "Following Podcast…" : "Follow Podcast")
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
            Text("Practice making an interjection")
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
            Text("Tap your saved interjection to review it, or tap any source chapter to jump there. Either action completes this step.")
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

private struct SettingsScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @AppStorage("playbackUsesVerboseActions") private var usesVerbosePlaybackActions = true
    @FocusState private var focusedField: Field?
    @State private var showsAdvancedAISettings = false
    @State private var showsDeveloperTools = false
    @State private var pendingPermanentDeletion: LibraryItemRow?
    @State private var isEmptyRecentlyDeletedConfirmationPresented = false
    @State private var isResetConfirmationPresented = false
    @State private var copiedDiagnostics = false

    private enum Field {
        case mapModel
        case summaryModel
        case conversationModel
        case apiKey
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("AI Features") {
                    if model.remoteProviderExperienceEnabled {
                        LabeledContent("Provider", value: "OpenAI")
                            .accessibilityIdentifier("provider.name")
                        LabeledContent("Data Sharing", value: model.aiDataSharingConsentDescription)
                        if model.aiDataSharingConsent == .grantedV1 {
                            Button("Revoke OpenAI Data Sharing", role: .destructive, action: model.revokeAIDataSharingConsent)
                                .accessibilityIdentifier("provider.revokeConsent.button")
                        }
                        SecureField("API Key", text: $model.providerAPIKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .apiKey)
                            .accessibilityIdentifier("provider.apiKey.field")
                        Button("Save Provider Settings", action: model.saveProviderSettings)
                            .accessibilityIdentifier("provider.save.button")
                        Button("Delete API Key", role: .destructive, action: model.deleteProviderAPIKey)
                            .disabled(model.providerAPIKey.isEmpty)
                            .accessibilityIdentifier("provider.deleteAPIKey.button")
                        Button("Probe Provider", action: model.probeProvider)
                            .accessibilityIdentifier("provider.probe.button")
                        LabeledContent("Probe", value: model.providerProbeStatus)
                        DisclosureGroup("Advanced model settings", isExpanded: $showsAdvancedAISettings) {
                            TextField("Listening Map Model", text: $model.listeningMapModel)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focusedField, equals: .mapModel)
                                .accessibilityIdentifier("provider.mapModel.field")
                            TextField("Summary Model", text: $model.summaryModel)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focusedField, equals: .summaryModel)
                                .accessibilityIdentifier("provider.summaryModel.field")
                            TextField("Conversation Model", text: $model.conversationModel)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focusedField, equals: .conversationModel)
                                .accessibilityIdentifier("provider.conversationModel.field")
                        }
                        .accessibilityIdentifier("provider.advanced.disclosure")
                    } else {
                        LabeledContent("Processing", value: "On device")
                            .accessibilityIdentifier("settings.ai.processing")
                        LabeledContent("Apple Foundation Model", value: model.localFoundationModelAvailabilityDescription)
                        Text("Interjection summaries stay on this device. Publisher podcast chapters and deterministic native-text Listening Maps do not require AI. AI-generated Listening Maps, remote providers, and API keys are disabled in this release.")
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                            .accessibilityIdentifier("settings.ai.releaseBoundary")
                    }
                }
                .onCompatibleChange(of: model.listeningMapModel) { _ in model.settingsValueChanged() }
                .onCompatibleChange(of: model.summaryModel) { _ in model.settingsValueChanged() }
                .onCompatibleChange(of: model.conversationModel) { _ in model.settingsValueChanged() }
                Section("Playback & Voice") {
                    Picker("Playback Controls", selection: $usesVerbosePlaybackActions) {
                        Text("Labeled").tag(true)
                        Text("Compact").tag(false)
                    }
                    .accessibilityIdentifier("settings.playbackControlStyle.picker")
                    Text("Labeled controls show Text, Sleep Timer, and playback speed. Compact controls show icons only.")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                    Picker("App Voice", selection: $model.ttsVoiceSelection) {
                        ForEach(AppTTSVoiceSelection.allCases) { voice in
                            Text(voice.displayName).tag(voice)
                        }
                    }
                    .accessibilityIdentifier("settings.ttsVoice.picker")
                    .onCompatibleChange(of: model.ttsVoiceSelection) { _ in
                        model.ttsVoiceSelectionChanged()
                    }
                    Text(model.ttsVoiceSelection.detail)
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                    Text("Voice synthesized on-device. Spoken text comes from your selected source.")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                    if model.ttsVoiceSelection == .system {
                        HStack {
                            Text("iOS Voice")
                            Spacer()
                            Button {
                                model.refreshSpeechVoiceOptions()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .frame(width: 34, height: 34)
                            }
                            .buttonStyle(IconButtonStyle())
                            .accessibilityLabel("Refresh iOS Voices")
                            .accessibilityIdentifier("settings.refreshSpeechVoices.button")
                        }
                        Picker("Speech Voice", selection: $model.speechVoiceIdentifier) {
                            Text("System Spoken Content Voice (Siri falls back)").tag("")
                            ForEach(model.speechVoiceOptions) { voice in
                                Text("\(voice.name) · \(voice.language) · \(voice.quality)")
                                    .tag(voice.id)
                            }
                        }
                        .accessibilityIdentifier("settings.speechVoice.picker")
                        .onCompatibleChange(of: model.speechVoiceIdentifier) { _ in
                            model.ttsVoiceSelectionChanged()
                        }
                    }
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Speaking Rate")
                            Spacer()
                            Text(model.speechRateDescription)
                                .foregroundStyle(AppColors.secondaryText)
                        }
                        DiscretePlaybackRateSlider(
                            value: Binding(
                                get: { model.speechPlaybackRateMultiplier },
                                set: { model.speechRate = $0 * 0.5 }
                            ),
                            accessibilityLabel: "Speaking rate",
                            accessibilityValue: model.speechRateDescription,
                            accessibilityIdentifier: "settings.speechRate.slider"
                        )
                    }
                    .onCompatibleChange(of: model.speechRate) { _ in
                        model.speechSettingsChanged()
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            model.previewSpokenContentVoice()
                        } label: {
                            Label("Try Spoken Content", systemImage: "speaker.wave.2")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .accessibilityIdentifier("settings.preview.spokenContent.button")

                        Button {
                            model.previewAppVoice()
                        } label: {
                            Label("Try App Voice", systemImage: "slider.horizontal.3")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(model.isRenderingSupertonicPreview)
                        .accessibilityIdentifier("settings.preview.appVoice.button")

                        Button {
                            model.previewAssistiveTechnologyVoice()
                        } label: {
                            Label("Try Assistive Tech", systemImage: "accessibility")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .accessibilityIdentifier("settings.preview.assistiveTech.button")
                    }
                    Picker("Text Navigation", selection: $model.skipUnit) {
                        Text("Sentence").tag("sentence")
                        Text("Paragraph").tag("paragraph")
                        Text("Section").tag("section")
                    }
                    .accessibilityIdentifier("settings.skipUnit.picker")
                    .onCompatibleChange(of: model.skipUnit) { _ in
                        model.settingsValueChanged()
                        model.saveProviderSettings()
                    }
                    Picker("Native Audio Back", selection: $model.mediaSkipBackSeconds) {
                        ForEach(Gate1AppModel.supportedMediaSkipSeconds, id: \.self) { seconds in
                            Text("\(seconds) seconds").tag(seconds)
                        }
                    }
                    .accessibilityIdentifier("settings.mediaSkipBack.picker")
                    .onCompatibleChange(of: model.mediaSkipBackSeconds) { _ in
                        model.mediaSkipSettingsChanged()
                    }
                    Picker("Native Audio Forward", selection: $model.mediaSkipForwardSeconds) {
                        ForEach(Gate1AppModel.supportedMediaSkipSeconds, id: \.self) { seconds in
                            Text("\(seconds) seconds").tag(seconds)
                        }
                    }
                    .accessibilityIdentifier("settings.mediaSkipForward.picker")
                    .onCompatibleChange(of: model.mediaSkipForwardSeconds) { _ in
                        model.mediaSkipSettingsChanged()
                    }
                }
                Section("Offline Storage") {
                    Button(action: model.openOfflineStorage) {
                        HStack {
                            Label("Manage Offline Storage", systemImage: "internaldrive")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(AppColors.secondaryText)
                        }
                    }
                    .accessibilityIdentifier("settings.offlineStorage.button")
                    Picker("Storage Budget", selection: $model.offlineStorageLimitGB) {
                        ForEach(OfflineStorageBudget.allowedGigabytes, id: \.self) { gigabytes in
                            Text("\(gigabytes) GB").tag(gigabytes)
                        }
                    }
                    .accessibilityIdentifier("settings.offlineStorageBudget.picker")
                    .onCompatibleChange(of: model.offlineStorageLimitGB) { _ in
                        model.offlineStorageBudgetChanged()
                    }
                    Text(model.offlineStorageUsageDescription)
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                    Picker("Automatic Audio Preparation", selection: $model.automaticAudioPreparationPolicy) {
                        ForEach(AutomaticAudioPreparationPolicy.allCases, id: \.self) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                    .accessibilityIdentifier("settings.automaticAudioPreparation.picker")
                    .onCompatibleChange(of: model.automaticAudioPreparationPolicy) { _ in
                        model.automaticAudioPreparationPolicyChanged()
                    }
                    Picker("Automatic Episode Map Preparation", selection: $model.automaticEpisodeMapPreparationPolicy) {
                        ForEach(AutomaticEpisodeMapPreparationPolicy.allCases, id: \.self) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                    .accessibilityIdentifier("settings.automaticEpisodeMapPreparation.picker")
                    .onCompatibleChange(of: model.automaticEpisodeMapPreparationPolicy) { _ in
                        model.automaticEpisodeMapPreparationPolicyChanged()
                    }
                    Text("Episode maps are private and off by default. While Charging only prepares already-downloaded episodes; full transcripts and temporary audio are deleted after derivative artifacts commit.")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                    Text("While Charging uses durable jobs and pauses before the next chunk when power, thermal, or storage safety changes. Completion timing is not guaranteed.")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                    Text("Use Manage Offline Storage to review protected, reproducible, reserved, and category totals before clearing anything.")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                }
                Section("Recently Deleted") {
                    if model.recentlyDeletedItems.isEmpty {
                        Text("Items moved here can be restored. Nothing is deleted automatically.")
                            .foregroundStyle(AppColors.secondaryText)
                    } else {
                        Button("Empty Recently Deleted", role: .destructive) {
                            isEmptyRecentlyDeletedConfirmationPresented = true
                        }
                        .accessibilityIdentifier("recentlyDeleted.empty.button")
                        ForEach(model.recentlyDeletedItems) { item in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(item.title)
                                    .font(.headline)
                                HStack {
                                    Button("Restore") { model.restoreItem(id: item.id) }
                                        .buttonStyle(.borderless)
                                        .accessibilityLabel("Restore \(item.title)")
                                        .accessibilityIdentifier("recentlyDeleted.restore.\(item.id)")
                                    Button("Delete Permanently", role: .destructive) {
                                        pendingPermanentDeletion = item
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Delete \(item.title) Permanently")
                                    .accessibilityIdentifier("recentlyDeleted.delete.\(item.id)")
                                }
                            }
                        }
                    }
                }
                Section("Import Inbox") {
                    if model.importInbox.isEmpty {
                        Text("No failed shares.")
                            .foregroundStyle(AppColors.secondaryText)
                    } else {
                        ForEach(model.importInbox) { entry in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(entry.title)
                                    .font(.headline)
                                Text(entry.source)
                                    .font(.caption)
                                    .foregroundStyle(AppColors.secondaryText)
                                    .lineLimit(2)
                                Text(entry.reason)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                HStack {
                                    Button("Retry") {
                                        model.retryImportInboxEntry(entry)
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityIdentifier("importInbox.retry.\(entry.id)")
                                    Button("Delete", role: .destructive) {
                                        model.deleteImportInboxEntry(entry)
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityIdentifier("importInbox.delete.\(entry.id)")
                                }
                            }
                        }
                    }
                }
                Section("Support & Privacy") {
                    Button(action: model.openHelp) {
                        Label("How Spoken Margins Works", systemImage: "questionmark.circle")
                    }
                    .accessibilityIdentifier("settings.help.button")
                    Link("Privacy Policy", destination: AppLinks.privacy)
                    Link("Support", destination: AppLinks.support)
                    NavigationLink("Terms of Use") {
                        SpokenMarginsTermsView(allowsAcceptance: !model.hasAcceptedCurrentTerms)
                    }
                    .accessibilityIdentifier("settings.terms.link")
                    LabeledContent("Terms Status", value: model.termsAcceptanceDescription)
                        .accessibilityIdentifier("settings.terms.status")
                    NavigationLink("Legal · On-Device Voice") {
                        SupertonicLegalView()
                    }
                    .accessibilityIdentifier("settings.legal.supertonic.link")
                    Button {
                        model.copyDiagnosticsExport()
                        copiedDiagnostics = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copiedDiagnostics = false
                        }
                    } label: {
                        Label(
                            copiedDiagnostics ? "Copied" : "Copy Privacy-Safe Diagnostics",
                            systemImage: copiedDiagnostics ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .buttonStyle(.borderless)
                        .accessibilityIdentifier("settings.copyDiagnostics.button")
                    LabeledContent("Version", value: AppLinks.versionDescription)
                }
                #if DEBUG
                Section("Developer") {
                    DisclosureGroup("Developer tools", isExpanded: $showsDeveloperTools) {
                        Button("Add Sample Item", action: model.addSampleItem)
                        Picker("Runtime Profile", selection: $model.selectedProfileId) {
                            Text("Phone/Tablet Online").tag("phone-tablet-online")
                            Text("Phone/Tablet Offline").tag("phone-tablet-offline")
                        }
                        .accessibilityIdentifier("runtime.profile.picker")
                        .onCompatibleChange(of: model.selectedProfileId) { _ in
                            model.runtimeProfileChanged()
                        }
                        Button("Reset Library and Load Sample", role: .destructive) {
                            isResetConfirmationPresented = true
                        }
                        .accessibilityIdentifier("settings.reset.button")
                        Button("Refresh Diagnostics", action: model.refreshDiagnostics)
                            .accessibilityIdentifier("settings.diagnostics.button")
                        ForEach(model.diagnostics.keys.sorted(), id: \.self) { key in
                            LabeledContent(key, value: model.diagnostics[key] ?? "")
                        }
                        ForEach(model.knownIssues, id: \.self) { issue in
                            Text(issue)
                                .font(.caption)
                                .foregroundStyle(AppColors.secondaryText)
                        }
                    }
                    Text("Listening Map JSON")
                        .font(.headline)
                    Text("Developer diagnostic for \(model.selectedItem.title.isEmpty ? "the selected item" : model.selectedItem.title).")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                    TextEditor(text: $model.listeningMapJSON)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 130)
                        .accessibilityLabel("Listening Map JSON")
                        .accessibilityIdentifier("settings.developer.mapJSON.editor")
                    Button("Apply Listening Map JSON", systemImage: "checkmark.circle") {
                        model.applyListeningMapJSON()
                    }
                    .disabled(model.listeningMapJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("settings.developer.mapJSON.apply")
                }
                #endif
            }
            .accessibilityIdentifier("settings.screen")
            .navigationTitle("Settings")
            .onAppear {
                model.refreshSpeechVoiceOptions()
                model.refreshImportInbox()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: model.openHome) {
                        Label("Home", systemImage: "arrow.left")
                    }
                    .accessibilityIdentifier("settings.home.button")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
            .alert(
                "Delete Permanently?",
                isPresented: Binding(
                    get: { pendingPermanentDeletion != nil },
                    set: { if !$0 { pendingPermanentDeletion = nil } }
                ),
                presenting: pendingPermanentDeletion
            ) { item in
                Button("Cancel", role: .cancel) {}
                Button("Delete Permanently", role: .destructive) {
                    model.permanentlyDeleteItem(id: item.id)
                    pendingPermanentDeletion = nil
                }
            } message: { item in
                Text("\(item.title) and all of its sessions, notes, and transcripts will be deleted. This cannot be undone.")
            }
            .alert("Empty Recently Deleted?", isPresented: $isEmptyRecentlyDeletedConfirmationPresented) {
                Button("Cancel", role: .cancel) {}
                Button("Delete All Permanently", role: .destructive) {
                    model.permanentlyDeleteRecentlyDeletedItems()
                }
            } message: {
                Text("All \(model.recentlyDeletedItems.count) recently deleted item\(model.recentlyDeletedItems.count == 1 ? "" : "s") and their sessions, notes, transcripts, and downloaded audio will be permanently deleted. This cannot be undone.")
            }
            .alert("Reset the entire library?", isPresented: $isResetConfirmationPresented) {
                Button("Cancel", role: .cancel) {}
                Button("Reset Library", role: .destructive, action: model.resetAndSeed)
            } message: {
                Text("This permanently deletes every item and its related records, then loads the sample.")
            }
        }
    }
}

private struct BatchExportScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var isFolderImporterPresented = false

    private static let destinationAnchor = "batchExport.destination"

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Export Sessions")
                                .font(.largeTitle.bold())
                            Text("Choose listening sessions and save one Markdown file for each session.")
                                .foregroundStyle(AppColors.secondaryText)
                        }

                        ProductPanel {
                            VStack(alignment: .leading, spacing: 14) {
                                Picker("Sessions", selection: $model.batchExportFilter) {
                                    Text("With Interjections").tag(BatchSessionExportFilter.withInterjections)
                                    Text("All Sessions").tag(BatchSessionExportFilter.all)
                                }
                                .pickerStyle(.segmented)
                                .accessibilityIdentifier("batchExport.filter.picker")

                                HStack {
                                    Text("\(model.selectedBatchExportSessionIds.count) selected")
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Button("Select All", action: model.selectAllVisibleBatchExportSessions)
                                        .disabled(model.visibleBatchExportRows.isEmpty)
                                        .accessibilityIdentifier("batchExport.selectAll.button")
                                    Button("Clear", action: model.clearBatchExportSelection)
                                        .disabled(model.selectedBatchExportSessionIds.isEmpty)
                                        .accessibilityIdentifier("batchExport.clear.button")
                                }
                            }
                        }

                        sessionSelection

                        if !model.selectedBatchExportSessionIds.isEmpty {
                            exportOptions
                            destination
                                .id(Self.destinationAnchor)
                        }

                        if let result = model.batchExportResult {
                            exportResult(result)
                        }
                    }
                    .padding(20)
                }
                .navigationBarTitleDisplayMode(.inline)
                .accessibilityIdentifier("batchExport.screen")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: model.openHome) {
                            Label("Home", systemImage: "arrow.left")
                        }
                        .accessibilityIdentifier("batchExport.home.button")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Export") {
                            jumpToDestination(using: proxy)
                        }
                        .disabled(model.selectedBatchExportSessionIds.isEmpty)
                        .accessibilityHint("Jumps to Included Material and Destination.")
                        .accessibilityIdentifier("batchExport.jumpToDestination.button")
                    }
                }
            }
            .fileImporter(
                isPresented: $isFolderImporterPresented,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let folder = urls.first {
                        model.configureBatchExportFolder(url: folder)
                    }
                case .failure(let error):
                    model.reportBatchExportFolderFailure(error)
                }
            }
        }
    }

    private func jumpToDestination(using proxy: ScrollViewProxy) {
        if accessibilityReduceMotion {
            proxy.scrollTo(Self.destinationAnchor, anchor: .top)
        } else {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(Self.destinationAnchor, anchor: .top)
            }
        }
    }

    @ViewBuilder
    private var sessionSelection: some View {
        if model.visibleBatchExportRows.isEmpty {
            ProductPanel {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.batchExportFilter == .withInterjections ? "No sessions with interjections" : "No sessions yet")
                        .font(.headline)
                    if model.batchExportFilter == .withInterjections, !model.batchExportRows.isEmpty {
                        Text("Choose All Sessions to include listening sessions without interjections.")
                            .font(.subheadline)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.visibleBatchExportRows) { row in
                    let selected = model.selectedBatchExportSessionIds.contains(row.id)
                    Button {
                        model.toggleBatchExportSelection(sessionId: row.id)
                    } label: {
                        ProductPanel {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(selected ? AppColors.green : AppColors.secondaryText)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(row.itemTitle)
                                        .font(.headline)
                                        .foregroundStyle(AppColors.text)
                                    Text(sessionDateDescription(row.session))
                                        .font(.subheadline)
                                        .foregroundStyle(AppColors.secondaryText)
                                    Text("\(sessionProgressDescription(row.session)) · \(row.interjectionCount) \(row.interjectionCount == 1 ? "interjection" : "interjections") · \(humanizedItemStatus(row.session.status))")
                                        .font(.caption)
                                        .foregroundStyle(AppColors.secondaryText)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(selected ? "Deselect" : "Select") \(row.itemTitle), \(row.interjectionCount) interjections, \(row.session.completionPercent) percent complete")
                    .accessibilityIdentifier("batchExport.session.\(row.id)")
                }
            }
        }
    }

    private var exportOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Included Material")
                .font(.headline)
            ProductPanel {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("Markdown", systemImage: "doc.text")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("One file per session")
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    Picker("Scope", selection: $model.exportScope) {
                        Text("Original").tag("original")
                        Text("Source Notes").tag("source_interjections")
                        Text("Full Session").tag("full_session")
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("batchExport.scope.picker")
                    .onCompatibleChange(of: model.exportScope) { _ in model.exportOptionsChanged() }

                    Toggle("Source Text", isOn: $model.exportIncludesSourceText)
                        .accessibilityIdentifier("batchExport.includeSourceText.toggle")
                        .onCompatibleChange(of: model.exportIncludesSourceText) { _ in model.exportOptionsChanged() }
                    Toggle("Reference", isOn: $model.exportIncludesReference)
                        .accessibilityIdentifier("batchExport.includeReference.toggle")
                        .onCompatibleChange(of: model.exportIncludesReference) { _ in model.exportOptionsChanged() }
                    Toggle("Listening Map", isOn: $model.exportIncludesListeningMap)
                        .accessibilityIdentifier("batchExport.includeListeningMap.toggle")
                        .onCompatibleChange(of: model.exportIncludesListeningMap) { _ in model.exportOptionsChanged() }
                    Toggle("Interjections", isOn: $model.exportIncludesInterjections)
                        .accessibilityIdentifier("batchExport.includeInterjections.toggle")
                        .onCompatibleChange(of: model.exportIncludesInterjections) { _ in model.exportOptionsChanged() }
                    Toggle("AI Turns", isOn: $model.exportIncludesTurns)
                        .accessibilityIdentifier("batchExport.includeTurns.toggle")
                        .onCompatibleChange(of: model.exportIncludesTurns) { _ in model.exportOptionsChanged() }
                }
            }
        }
    }

    private var destination: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Destination")
                .font(.headline)
            ProductPanel {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Image(systemName: "folder")
                            .foregroundStyle(AppColors.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.hasBatchExportFolder ? model.batchExportFolderName : "Choose a folder")
                                .font(.subheadline.weight(.semibold))
                            Text("Spoken Margins remembers this destination for future exports.")
                                .font(.caption)
                                .foregroundStyle(AppColors.secondaryText)
                        }
                    }
                    Button {
                        isFolderImporterPresented = true
                    } label: {
                        Label(model.hasBatchExportFolder ? "Change Folder" : "Choose Folder", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("batchExport.chooseFolder.button")

                    Button(action: model.exportSelectedSessionsToFolder) {
                        if model.isWritingBatchExport {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Exporting")
                            }
                        } else {
                            Label("Export \(model.selectedBatchExportSessionIds.count) Session\(model.selectedBatchExportSessionIds.count == 1 ? "" : "s")", systemImage: "square.and.arrow.down")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!model.hasBatchExportFolder || model.isWritingBatchExport)
                    .accessibilityIdentifier("batchExport.write.button")
                }
            }
        }
    }

    private func exportResult(_ result: BatchSessionExportResult) -> some View {
        ProductPanel {
            VStack(alignment: .leading, spacing: 8) {
                Text("Export Result")
                    .font(.headline)
                Text("\(result.exportedFileNames.count) saved to \(result.destinationName)")
                    .font(.subheadline)
                ForEach(result.exportedFileNames, id: \.self) { fileName in
                    Label(fileName, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                }
                ForEach(Array(result.failures.enumerated()), id: \.offset) { _, failure in
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .accessibilityIdentifier("batchExport.result")
    }
}

private struct ExportScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @State private var isSharePresented = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Share")
                        .font(.largeTitle.bold())
                    Text("Share reviewed Margins with their voice, or export a session handoff as Markdown or JSON.")
                        .foregroundStyle(AppColors.secondaryText)
                    ProductPanel {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Share Margins")
                                .font(.headline)
                            Text("Review the words, voice version, item transport, and anchor evidence that will leave your device.")
                                .font(.callout)
                                .foregroundStyle(AppColors.secondaryText)
                            Button(action: model.prepareShareInterjections) {
                                Label("Share Margins (\(shareableMarginCount))", systemImage: "person.wave.2")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(shareableMarginCount == 0)
                        }
                    }
                    Text("Export listening session")
                        .font(.headline)
                    ProductPanel {
                        VStack(alignment: .leading, spacing: 14) {
                            Picker(
                                "Listening Session",
                                selection: Binding(
                                    get: { model.exportSessionId ?? "" },
                                    set: {
                                        model.exportSessionId = $0.isEmpty ? nil : $0
                                        model.exportOptionsChanged()
                                    }
                                )
                            ) {
                                ForEach(model.selectedItem.sessionRows) { row in
                                    Text("\(sessionDateDescription(row.session)) · \(sessionProgressDescription(row.session)) · \(row.interjectionCount) notes")
                                        .tag(row.id)
                                }
                            }
                            .accessibilityIdentifier("export.session.picker")

                            Picker("Format", selection: $model.exportFormat) {
                                Text("AI Handoff Markdown").tag("markdown")
                                Text("Full JSON Archive").tag("json")
                            }
                            .pickerStyle(.segmented)
                            .accessibilityIdentifier("export.format.picker")
                            .onCompatibleChange(of: model.exportFormat) { _ in model.exportOptionsChanged() }

                            Picker("Scope", selection: $model.exportScope) {
                                Text("Original").tag("original")
                                Text("Source Notes").tag("source_interjections")
                                Text("Full Session").tag("full_session")
                            }
                            .pickerStyle(.segmented)
                            .accessibilityIdentifier("export.scope.picker")
                            .onCompatibleChange(of: model.exportScope) { _ in model.exportOptionsChanged() }

                            Toggle("Source Text", isOn: $model.exportIncludesSourceText)
                                .accessibilityIdentifier("export.includeSourceText.toggle")
                                .onCompatibleChange(of: model.exportIncludesSourceText) { _ in model.exportOptionsChanged() }
                                .disabled(!model.exportSourceTextAvailable)
                            if !model.exportSourceTextAvailable {
                                Text("Native audio exports include only bounded listening context, not full source text.")
                                    .font(.caption)
                                    .foregroundStyle(AppColors.secondaryText)
                            }
                            Toggle("Reference", isOn: $model.exportIncludesReference)
                                .accessibilityIdentifier("export.includeReference.toggle")
                                .onCompatibleChange(of: model.exportIncludesReference) { _ in model.exportOptionsChanged() }
                            Toggle("Listening Map", isOn: $model.exportIncludesListeningMap)
                                .accessibilityIdentifier("export.includeListeningMap.toggle")
                                .onCompatibleChange(of: model.exportIncludesListeningMap) { _ in model.exportOptionsChanged() }
                            Toggle("Interjections", isOn: $model.exportIncludesInterjections)
                                .accessibilityIdentifier("export.includeInterjections.toggle")
                                .onCompatibleChange(of: model.exportIncludesInterjections) { _ in model.exportOptionsChanged() }
                            Toggle("AI Turns", isOn: $model.exportIncludesTurns)
                                .accessibilityIdentifier("export.includeTurns.toggle")
                                .onCompatibleChange(of: model.exportIncludesTurns) { _ in model.exportOptionsChanged() }
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        if !model.exportPreview.isEmpty {
                            #if canImport(UIKit)
                            Button {
                                isSharePresented = true
                            } label: {
                                Label("Export Session", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            .accessibilityIdentifier("export.share.button")
                            .sheet(isPresented: $isSharePresented) {
                                SessionActivityView(
                                    activityItems: exportActivityItems,
                                    onSuccessfulCompletion: model.recordSessionExported
                                )
                            }
                            #else
                            ShareLink(item: model.exportPreview) {
                                Label("Export Session", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            .accessibilityIdentifier("export.share.button")
                            #endif
                        }
                        Button {
                            model.copyPlainTextExport()
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(model.exportPreview.isEmpty)
                            .accessibilityIdentifier("export.copyPlainText.button")
                        Button("Item", action: { model.openItem(id: model.selectedItem.id) })
                            .buttonStyle(SecondaryButtonStyle())
                            .accessibilityIdentifier("export.item.button")
                    }
                    ProductPanel {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Preview")
                                    .font(.headline)
                                Spacer()
                                if !model.exportPreview.isEmpty {
                                    Text(model.exportPreviewSizeDescription)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(AppColors.secondaryText)
                                }
                            }
                            if model.exportPreviewIsTruncated {
                                Label(
                                    "Preview truncated; Copy and Share use the complete export.",
                                    systemImage: "doc.text.magnifyingglass"
                                )
                                .font(.caption)
                                .foregroundStyle(AppColors.secondaryText)
                                .accessibilityIdentifier("export.preview.truncated")
                            }
                            Text(model.exportPreview.isEmpty ? "No export yet." : model.displayedExportPreview)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityLabel(
                                    model.exportPreviewIsTruncated
                                        ? "Truncated export preview, \(model.exportPreviewSizeDescription). Copy and Share use the complete export."
                                        : "Export preview, \(model.exportPreviewSizeDescription)."
                                )
                                .accessibilityIdentifier("export.preview")
                        }
                    }
                }
                .padding(20)
            }
            .accessibilityIdentifier("export.screen")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: model.openHome) {
                        Label("Home", systemImage: "arrow.left")
                    }
                    .accessibilityIdentifier("export.home.button")
                }
            }
        }
    }

    private var shareableMarginCount: Int {
        model.selectedItem.interjections.filter { $0.status == "active" && $0.targetType == .item }.count
    }

    #if canImport(UIKit)
    private var exportActivityItems: [Any] {
        if model.exportFormat == "markdown", let fileURL = model.exportFileURL {
            return [fileURL]
        }
        return [model.exportPreview]
    }
    #endif
}

#if canImport(UIKit)
private struct SessionActivityView: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let activityItems: [Any]
    let onSuccessfulCompletion: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            if completed {
                onSuccessfulCompletion()
            }
            dismiss()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

private struct PastedAssistantResponseView: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Binding var isPresented: Bool
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                TextEditor(text: $model.pastedAssistantResponse)
                    .font(.body)
                    .frame(minHeight: 260)
                    .padding(8)
                    .background(AppColors.inputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppColors.border))
                    .focused($isFocused)
                    .accessibilityLabel("Assistant response text")
                    .accessibilityIdentifier("pasteResponse.editor")
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
        case .interjection(let interjection): return interjection.targetType == .item ? 1 : 4
        case .importedCommentary: return 2
        case .turn: return 3
        case .turnChapter: return 4
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

private struct InterjectionDetailView: View {
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
        model.selectedItem.interjections.first(where: { $0.id == interjection.id }) ?? interjection
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
                        LabeledContent("Transcript status", value: humanizedTurnStatus(current.transcriptionStatus))
                    }
                }
                Section("Transcript") {
                    Text(current.cleanedTranscript ?? current.transcript ?? "No transcript yet.")
                        .textSelection(.enabled)
                    Button {
                        model.toggleInterjectionAudioPlayback(current)
                    } label: {
                        Label(
                            model.playingInterjectionAudioId == current.id ? "Stop Recording" : "Play Original Recording",
                            systemImage: model.playingInterjectionAudioId == current.id ? "stop.fill" : "play.fill"
                        )
                    }
                    .disabled(current.audioPath == nil)
                    .accessibilityIdentifier("interjection.detail.playRecording")
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
                    Button {
                        model.retryInterjectionTranscription(current)
                    } label: {
                        if model.retryingInterjectionTranscriptionIds.contains(current.id) {
                            Label("Retranscribing Saved Audio", systemImage: "waveform.badge.magnifyingglass")
                        } else {
                            Label("Retranscribe Saved Audio", systemImage: "waveform")
                        }
                    }
                    .disabled(current.audioPath == nil || model.retryingInterjectionTranscriptionIds.contains(current.id))
                    .accessibilityIdentifier("interjection.detail.retryTranscription")
                    Button("Delete Transcript") {
                        pendingDeletion = .transcript
                    }
                    .disabled(current.transcript == nil && current.cleanedTranscript == nil)
                    .accessibilityIdentifier("interjection.detail.deleteTranscript")
                }
                Section("Share later") {
                    Toggle(
                        "Star for sharing",
                        isOn: Binding(
                            get: { currentInterjection.isStarredForSharing == true },
                            set: {
                                model.setInterjectionStarredForSharing(current.id, starred: $0)
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
                            model.setInterjectionPrivateSharingNote(current.id, note: privateSharingNoteDraft)
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
                    Text(anchorContextText(current.anchor.anchorBefore, status: current.anchorContextStatus))
                        .textSelection(.enabled)
                    Text("After")
                        .font(.headline)
                    Text(anchorContextText(current.anchor.anchorAfter, status: current.anchorContextStatus))
                        .textSelection(.enabled)
                    if current.anchorContextStatus == .unavailable {
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
            .navigationTitle("Interjection")
            .onAppear {
                privateSharingNoteDraft = current.privateSharingNote ?? ""
            }
            .onDisappear {
                if model.selectedItem.interjections.contains(where: { $0.id == current.id }),
                   privateSharingNoteDraft != (current.privateSharingNote ?? "") {
                    model.setInterjectionPrivateSharingNote(current.id, note: privateSharingNoteDraft)
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

private struct PlainPanelButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(AppColors.text)
            .background(AppColors.panel.opacity(configuration.isPressed ? 0.72 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppColors.border))
    }
}

private struct StatusBanner: View {
    @EnvironmentObject private var model: Gate1AppModel

    @ViewBuilder
    var body: some View {
        if let error = model.lastError {
            ProductPanel {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Something needs attention", systemImage: "exclamationmark.triangle")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppColors.dangerText)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(AppColors.dangerText)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button(action: model.dismissError) {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Dismiss error")
                }
            }
        }
    }
}

private struct EdgeSwipeBackModifier: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 18, coordinateSpace: .global)
                .onEnded { value in
                    guard enabled else { return }
                    let horizontal = value.translation.width
                    let vertical = abs(value.translation.height)
                    guard value.startLocation.x <= 32,
                          horizontal >= 72,
                          horizontal > vertical * 1.4 else {
                        return
                    }
                    action()
                }
        )
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
    return interjection.transcriptionStatus
}

private func turnSequenceNumber(_ id: String) -> Int? {
    guard let raw = id.split(separator: "-").last,
          let value = Int(raw) else {
        return nil
    }
    return value
}

private func humanizedItemStatus(_ status: String) -> String {
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

private func sessionDateDescription(_ session: Session) -> String {
    guard let date = session.createdAt ?? session.updatedAt else { return "Older session" }
    return date.formatted(date: .abbreviated, time: .shortened)
}

private func sessionProgressDescription(_ session: Session) -> String {
    if let mediaTimeMs = session.position.mediaTimeMs, mediaTimeMs > 0 {
        return "\(formatPlaybackTime(mediaTimeMs)) · \(session.completionPercent)% complete"
    }
    return "\(session.completionPercent)% complete"
}

private enum AppLinks {
    static var privacy: URL {
        URL(string: "https://spokenmargins.proximitytoprogress.com/privacy/") ?? URL(fileURLWithPath: "/")
    }

    static var support: URL {
        URL(string: "https://spokenmargins.proximitytoprogress.com/support/") ?? URL(fileURLWithPath: "/")
    }

    static var versionDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        return "\(version) (\(build))"
    }
}

enum AppColors {
    static let background = dynamicColor(light: (0.96, 0.97, 0.94), dark: (0.07, 0.09, 0.08))
    static let panel = dynamicColor(light: (1.00, 1.00, 1.00), dark: (0.13, 0.16, 0.14))
    static let inputBackground = dynamicColor(light: (0.98, 0.99, 0.97), dark: (0.10, 0.12, 0.11))
    static let border = dynamicColor(light: (0.84, 0.87, 0.81), dark: (0.28, 0.34, 0.30))
    static let text = dynamicColor(light: (0.09, 0.13, 0.11), dark: (0.92, 0.95, 0.91))
    static let secondaryText = dynamicColor(light: (0.38, 0.44, 0.41), dark: (0.66, 0.72, 0.68))
    static let green = dynamicColor(light: (0.13, 0.43, 0.30), dark: (0.50, 0.84, 0.62))
    static let primaryAction = dynamicColor(light: (0.08, 0.32, 0.22), dark: (0.12, 0.36, 0.23))
    static let softGreen = dynamicColor(light: (0.91, 0.94, 0.88), dark: (0.18, 0.25, 0.20))
    static let accent = dynamicColor(light: (0.48, 0.82, 0.59), dark: (0.56, 0.89, 0.67))
    static let accentSoft = dynamicColor(light: (0.67, 0.91, 0.72), dark: (0.25, 0.39, 0.28))
    static let watchBackground = Color(red: 0.09, green: 0.13, blue: 0.11)
    static let watchControl = Color(red: 0.18, green: 0.24, blue: 0.21)
    static let watchSecondary = Color(red: 0.69, green: 0.75, blue: 0.70)
    static let dangerText = dynamicColor(light: (0.55, 0.13, 0.11), dark: (1.00, 0.55, 0.48))
    static let dangerBackground = dynamicColor(light: (0.96, 0.88, 0.86), dark: (0.34, 0.15, 0.13))
    static let interjectText = Color(red: 0.08, green: 0.10, blue: 0.08)
    static let bone = dynamicColor(light: (0.97, 0.95, 0.89), dark: (0.08, 0.10, 0.09))
    static let evergreen = dynamicColor(light: (0.08, 0.30, 0.21), dark: (0.48, 0.84, 0.62))
    static let ochre = dynamicColor(light: (0.76, 0.52, 0.16), dark: (0.94, 0.72, 0.32))
    static let coral = dynamicColor(light: (0.70, 0.27, 0.20), dark: (1.00, 0.57, 0.48))
    static let plum = dynamicColor(light: (0.39, 0.24, 0.48), dark: (0.78, 0.62, 0.88))

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

private struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(AppColors.text)
            .background(AppColors.softGreen.opacity(configuration.isPressed ? 0.7 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct DangerIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(AppColors.dangerText)
            .background(AppColors.dangerBackground.opacity(configuration.isPressed ? 0.7 : 1))
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
            Label(title, systemImage: systemImage)
        }
    }
}

private struct MainPlaybackButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title2)
            .foregroundStyle(AppColors.interjectText)
            .frame(width: 76, height: 76)
            .background(AppColors.accent.opacity(configuration.isPressed ? 0.75 : 1))
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
            .background(Color(red: 0.94, green: 0.82, blue: 0.42).opacity(configuration.isPressed ? 0.78 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
