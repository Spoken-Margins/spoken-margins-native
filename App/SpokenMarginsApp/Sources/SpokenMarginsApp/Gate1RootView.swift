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
    @StateObject private var supertonicNotice = SupertonicDownloadNotice()

    /// The tabs and the Timeline place their own mini player.
    private var showsRootMiniPlayer: Bool {
        model.screen != .home && model.screen != .timeline && !model.recordingNavigationIsLocked
            && model.shouldShowMiniPlayer && !keyboardIsPresented
    }

    var body: some View {
        MiniPlayerDock(showsMiniPlayer: showsRootMiniPlayer) {
            if model.writtenMarginDraft != nil {
                ExperienceWrittenMarginScreen()
            } else if model.snapshot.isRecording || model.isRequestingRecordingPermission {
                ExperienceRecordingView()
            } else {
                switch model.screen {
                case .home:
                    ExperienceRootTabs(navigation: $navigation, supertonicNotice: supertonicNotice, showsMiniPlayer: !keyboardIsPresented && model.shouldShowMiniPlayer).announcesScreenChange()
                case .item:
                    ExperienceItemDetailScreen()
                case .playback:
                    PlaybackScreen()
                case .timeline:
                    ExperienceTimelineRailScreen().announcesScreenChange()
                        .motionTransition(.move(edge: .bottom).combined(with: .opacity))
                case .offlineStorage:
                    ExperienceStorageScreen().announcesScreenChange()
                case .export:
                    ExportScreen().announcesScreenChange()
                case .batchExport:
                    BatchExportScreen().announcesScreenChange()
                }
            }
        }
        .background(AppColors.background.ignoresSafeArea())
        .modifier(AppFeedbackPresentation())
        .edgeSwipeBack(
            enabled: !model.recordingNavigationIsLocked && model.screen != .home,
            canCommit: { !model.recordingNavigationIsLocked },
            action: model.openHome
        ) {
            // What openHome lands on, so the swipe reveals the tab it will arrive at.
            MiniPlayerDock(showsMiniPlayer: false) {
                ExperienceRootTabs(navigation: .constant(navigation.edgeSwipePreview), supertonicNotice: supertonicNotice, showsMiniPlayer: !keyboardIsPresented && model.shouldShowMiniPlayer)
            }
        }
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
        .tracksKeyboard($keyboardIsPresented).liveSessionLinkCover(model)
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
            Task { await catalogDrawer.playFirstListenIfRequested() }
        }) {
            CatalogDrawerView()
                .environmentObject(catalogDrawer)
        }
        .modifier(SupertonicDownloadNoticePresentation(notice: supertonicNotice))
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

private struct AIDataSharingConsentView: View {
    @EnvironmentObject private var model: Gate1AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label("Send this content to OpenAI?", systemImage: "hand.raised.fill")
                        .font(.title2.bold())
                    Text("A live AI request can include the source text needed for the task, your Margin transcripts, the current follow-up, nearby words, and recent conversation turns.")
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

/// Follow is offered on the Item screen only, not while listening (#280).
struct SourceFollowSuggestionCard: View {
    @EnvironmentObject private var model: Gate1AppModel

    var body: some View {
        if !model.sourceFollowSuggestionCandidates.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("Keep up with this source?", systemImage: "dot.radiowaves.left.and.right")
                    .font(.headline)
                Text("Following only adds future entries to your source inbox. Nothing is imported, downloaded, or prepared automatically.")
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
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
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(AppColors.text)
            .background(AppColors.watchControl.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("source.followSuggestion.card")
        }
    }
}

struct ManualSourceFollowButton: View {
    @EnvironmentObject private var model: Gate1AppModel

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
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(model.isFollowingSelectedSource)
            .accessibilityIdentifier("source.followCurrent.button")
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
                            model.isPlayingInterjectionAudio(current) ? "Stop playing" : "Hear my recording",
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
                        Label(copied ? "Copied" : "Copy with Context", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityIdentifier("interjection.detail.copy")
                    if current.captureKind != .written {
                    Button {
                        model.retryInterjectionTranscription(current)
                    } label: {
                        if model.isRetryingInterjectionTranscription(current) {
                            Label("Transcribing again", systemImage: "waveform.badge.magnifyingglass")
                        } else {
                            Label("Transcribe again", systemImage: "waveform")
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
                    TextField("Private note for yourself", text: $privateSharingNoteDraft, axis: .vertical)
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
                Section("Where in the source") {
                    LabeledContent("Nearby words", value: anchorContextStatusLabel(current))
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
                        Label("Delete Margin", systemImage: "trash")
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
                pendingDeletion == .transcript ? "Delete this transcript?" : "Delete this Margin?",
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
                    Button("Delete Margin", role: .destructive) {
                        model.deleteInterjection(current)
                        pendingDeletion = nil
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
            } message: { Text(pendingDeletion == .transcript ? "The transcript will be removed." : (current.captureKind == .written ? "Its words will be removed." : "Its voice recording and words will be removed.")) }
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

func humanizedTurnStatus(_ status: String) -> String {
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
    case .summaryTurn: return "Margin summary"
    }
}

func formatPlaybackTime(_ milliseconds: Int) -> String {
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

enum AppColors {
    static let listeningBackground = dynamicColor(AppSemanticColorRGB.listeningBackground)
    static let captureBackground = dynamicColor(AppSemanticColorRGB.captureBackground)
    static let listeningAccent = dynamicColor(AppSemanticColorRGB.listeningAccent)
    static let background = dynamicColor(AppSemanticColorRGB.background)
    static let panel = dynamicColor(AppSemanticColorRGB.panel)
    static let inputBackground = dynamicColor(AppSemanticColorRGB.inputBackground)
    static let border = contrastAware(AppSemanticColorRGB.border, increased: AppSemanticColorRGB.borderIncreased)
    static let text = dynamicColor(AppSemanticColorRGB.text)
    static let secondaryText = dynamicColor(AppSemanticColorRGB.secondaryText)
    static let green = dynamicColor(AppSemanticColorRGB.green)
    static let primaryAction = dynamicColor(AppSemanticColorRGB.primaryAction)
    static let softGreen = dynamicColor(AppSemanticColorRGB.softGreen)
    static let accent = dynamicColor(AppSemanticColorRGB.accent)
    static let accentSoft = dynamicColor(AppSemanticColorRGB.accentSoft)
    static let watchBackground = dynamicColor(AppSemanticColorRGB.watchBackground)
    static let watchControl = dynamicColor(AppSemanticColorRGB.watchControl)
    static let watchSecondary = dynamicColor(AppSemanticColorRGB.listeningSecondary)
    static let dangerText = dynamicColor(AppSemanticColorRGB.dangerText)
    static let dangerBackground = dynamicColor(AppSemanticColorRGB.dangerBackground)
    static let interjectText = dynamicColor(AppSemanticColorRGB.captureText)
    static let bone = dynamicColor(AppSemanticColorRGB.bone)
    static let evergreen = dynamicColor(AppSemanticColorRGB.evergreen)
    static let onEvergreen = dynamicColor(AppSemanticColorRGB.onEvergreen)
    static let ochre = dynamicColor(AppSemanticColorRGB.ochre)
    static let coral = dynamicColor(AppSemanticColorRGB.coral)
    static let plum = dynamicColor(AppSemanticColorRGB.plum)
    static let star = dynamicColor(AppSemanticColorRGB.star)
    static let watchDanger = dynamicColor(AppSemanticColorRGB.watchDanger)

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
            .clipShape(RoundedRectangle(cornerRadius: 8)).expandedHitArea(vertical: 1)
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(AppColors.text)
            .background(AppColors.softGreen.opacity(configuration.isPressed ? 0.7 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 8)).expandedHitArea(horizontal: 5, vertical: 5)
    }
}

