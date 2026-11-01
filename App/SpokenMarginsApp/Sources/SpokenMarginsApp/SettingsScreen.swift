import SwiftUI
import SessionKit
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

struct SettingsScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.isEdgeSwipePreview) private var isEdgeSwipePreview
    @AppStorage("playbackUsesVerboseActions") private var usesVerbosePlaybackActions = true
    @AppStorage(HeadphoneDoublePressAction.storageKey) private var headphoneDoublePress = HeadphoneDoublePressAction.default.rawValue
    @State private var showsDeveloperTools = false
    @State private var showsImportInbox = false
    @State private var showsAboutAndLegal = false
    @State private var pendingPermanentDeletion: LibraryItemRow?
    @State private var pendingInboxDeletion: ImportInboxEntry?
    @State private var isEmptyRecentlyDeletedConfirmationPresented = false
    @State private var isResetConfirmationPresented = false
    @State private var diagnosticsExportURL: URL?
    @State private var isDiagnosticsSharePresented = false
    @State private var isPreparingDiagnostics = false
    @State private var listeningSignalsExportURL: URL?
    @State private var isExportingListeningSignals = false
    @State private var isListeningSignalsSharePresented = false
    @State private var hasNoListeningSignals = false
    @AppStorage(CommunityMapUploadService.optInKey) private var helpsMakeListeningMaps = false
    @AppStorage(CommunityMapFetchService.optInKey) private var looksUpCommunityMaps = false
    /// The Supertonic download card's "Open Voices" lands here and opens Voices (#1820).
    @ObservedObject private var supertonicNotice: SupertonicDownloadNotice
    @State private var showsVoices = false

    init(supertonicNotice: SupertonicDownloadNotice) {
        _supertonicNotice = ObservedObject(wrappedValue: supertonicNotice)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Voice") {
                    Picker("Playback Controls", selection: $usesVerbosePlaybackActions) {
                        Text("Labeled").tag(true)
                        Text("Compact").tag(false)
                    }
                    .accessibilityIdentifier("settings.playbackControlStyle.picker")
                    Text("Choose labels or icons in listening options.")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                    Toggle(
                        "Show “Mix with Other Audio”",
                        isOn: Binding(
                            get: { model.showsMixWithOtherAudioOption },
                            set: { enabled in
                                model.showsMixWithOtherAudioOption = enabled
                                model.mixWithOtherAudioAvailabilityChanged()
                            }
                        )
                    )
                    .accessibilityIdentifier("settings.mixWithOtherAudio.toggle")
                    Text("Adds a per-session option to the listening screen. It lets music or other audio continue, but Lock Screen and headphone controls may control the other app. Each listening session starts with this option off.")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                    NavigationLink {
                        VoicesSettingsScreen(voices: model.requireVoiceDownloads()).miniPlayerKeepOut()
                    } label: {
                        Label("Voices", systemImage: "waveform")
                    }
                    .accessibilityIdentifier("settings.voices.link")
                    AppVoicePicker(selection: $model.ttsVoiceSelection, voices: model.requireVoiceDownloads())
                    .onCompatibleChange(of: model.ttsVoiceSelection) { _ in
                        model.ttsVoiceSelectionChanged()
                    }
                    Text(model.ttsVoiceSelection.detail)
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                    // A new listener starts on Phonon; the backup voice reads until it has downloaded (#2858).
                    PhononStatusLine(model: model, choice: model.ttsVoiceSelection, voices: model.requireVoiceDownloads(), connectivity: model.connectivity)
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
                    DisclosureGroup("Compare voice playback") {
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
                        model.skipUnitChanged()
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
                    Picker("Headphone double-press", selection: $headphoneDoublePress) {
                        Text("Skip forward").tag(HeadphoneDoublePressAction.skipForward.rawValue)
                        Text("Add a Margin").tag(HeadphoneDoublePressAction.addMargin.rawValue)
                    }
                    .accessibilityIdentifier("settings.headphoneDoublePress.picker")
                    Text("Skip forward is the normal double-press. Add a Margin starts a Margin instead, but a headphone press can't end one: stop talking or use the button on the screen. Triple-press still skips back.")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
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
                Section("Storage") {
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
                    Text("While Charging uses durable jobs and pauses between parts of an item when power, thermal, or storage safety changes. Completion timing is not guaranteed.")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                    DisclosureGroup("Recently Deleted\(model.recentlyDeletedItems.isEmpty ? "" : " (\(model.recentlyDeletedItems.count))")") {
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
                }
                MarginOutputSettingsSection()
                Section("Import & Export") {
                    NavigationLink("Import Listening Edition") { ListeningEditionImportScreen().miniPlayerKeepOut() }
                    NavigationLink("Read Later Services") { ReadLaterScreen().miniPlayerKeepOut() }
                    Toggle(isOn: Binding(
                        get: { model.quickAccess.inboxFeedsQueue },
                        set: { model.quickAccess.inboxFeedsQueue = $0 }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Queue New Quick Folder Files")
                            Text("Files that appear in your Quick Folder are imported and added to the end of your play queue, in filename order. Choose the folder under Add Source.")
                                .font(.caption)
                                .foregroundStyle(AppColors.secondaryText)
                        }
                    }
                    .accessibilityIdentifier("settings.quickFolderQueue.toggle")
                    DisclosureGroup("Import Inbox", isExpanded: $showsImportInbox) {
                        PendingLinksWaitingLine(count: model.sourceLinksWaitingForNetwork)
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
                                    FailureMessageLabel(entry.reason)
                                        .font(.caption)
                                    HStack {
                                        Button("Retry") {
                                            model.retryImportInboxEntry(entry)
                                        }
                                        .buttonStyle(.borderless)
                                        .accessibilityIdentifier("importInbox.retry.\(entry.id)")
                                        Button("Delete", role: .destructive) {
                                            pendingInboxDeletion = entry
                                        }
                                        .buttonStyle(.borderless)
                                        .accessibilityIdentifier("importInbox.delete.\(entry.id)")
                                    }
                                }
                            }
                        }
                    }
                }
                Section("Help & Privacy") {
                    Button(action: model.openHelp) {
                        Label("How Spoken Margins Works", systemImage: "questionmark.circle")
                    }
                    .accessibilityIdentifier("settings.help.button")
                    Link("Privacy Policy", destination: AppLinks.privacy)
                    Link("Support", destination: AppLinks.support)
                    Link("Copyright and DMCA", destination: AppLinks.copyright)
                    Toggle(isOn: $helpsMakeListeningMaps) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Help make listening maps")
                            Text("Send transcripts of public episodes to the Spoken Margins server, which turns them into maps and then deletes them.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("settings.communityMaps.toggle")
                    Toggle(isOn: $looksUpCommunityMaps) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Look up community maps")
                            Text("When you open or play a public podcast episode with no chapters, ask the Spoken Margins server for a map other listeners helped make. This tells the server which episode you opened, and it can see your IP address.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("settings.communityMapLookup.toggle")
                    #if canImport(UIKit)
                    Button {
                        isPreparingDiagnostics = true
                        Task {
                            defer { isPreparingDiagnostics = false }
                            diagnosticsExportURL = await model.prepareDiagnosticsExportFileURL()
                            isDiagnosticsSharePresented = diagnosticsExportURL != nil
                        }
                    } label: {
                        Group {
                            if isPreparingDiagnostics {
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text("Preparing diagnostics…")
                                }
                            } else {
                                Label("Share Diagnostics", systemImage: "square.and.arrow.up")
                            }
                        }
                        .fullRowTapTarget()
                    }
                    .buttonStyle(.borderless)
                    .disabled(isPreparingDiagnostics)
                    .accessibilityIdentifier("settings.shareDiagnostics.button")
                    .sheet(isPresented: $isDiagnosticsSharePresented) {
                        if let diagnosticsExportURL {
                            ShareFileActivityView(fileURL: diagnosticsExportURL)
                        }
                    }
                    Text("App state and recent playback events, as a file for a bug report. It includes the titles and links of items in your Library. It stays on this device unless you share it.")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                    Button {
                        isExportingListeningSignals = true
                        Task {
                            defer { isExportingListeningSignals = false }
                            listeningSignalsExportURL = await model.listeningSignals.exportFileURL()
                            isListeningSignalsSharePresented = listeningSignalsExportURL != nil
                            hasNoListeningSignals = listeningSignalsExportURL == nil
                        }
                    } label: {
                        Label(
                            hasNoListeningSignals ? "Nothing Recorded Yet" : "Export Listening Signals",
                            systemImage: "square.and.arrow.up"
                        )
                        .fullRowTapTarget()
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("settings.exportListeningSignals.button")
                    .disabled(isExportingListeningSignals)
                    .sheet(isPresented: $isListeningSignalsSharePresented) {
                        if let listeningSignalsExportURL {
                            ShareFileActivityView(fileURL: listeningSignalsExportURL)
                        }
                    }
                    Text("A private log of listening time, Margins, shares and finishes for followed sources: titles, times and counts, never Margin text or audio. It stays on this device unless you export it.")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                    #endif
                }
                Section {
                    DisclosureGroup("About & Legal", isExpanded: $showsAboutAndLegal) {
                        LabeledContent("Processing", value: "On device")
                            .accessibilityIdentifier("settings.ai.processing")
                        LabeledContent("Apple Foundation Model", value: model.localFoundationModelAvailabilityDescription)
                        Text("Margin summaries are made on this device. Publisher podcast chapters and deterministic native-text Listening Maps do not require AI. Spoken Margins has no third-party AI provider or API key setting. If you turn on Help make listening maps, podcast transcripts go to the Spoken Margins server, which uses an AI service to draft maps.")
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                            .accessibilityIdentifier("settings.ai.releaseBoundary")
                        NavigationLink("Terms of Use") {
                            SpokenMarginsTermsView(allowsAcceptance: !model.hasAcceptedCurrentTerms)
                                .miniPlayerKeepOut()
                        }
                        .accessibilityIdentifier("settings.terms.link")
                        LabeledContent("Terms Status", value: model.termsAcceptanceDescription)
                            .accessibilityIdentifier("settings.terms.status")
                        NavigationLink("Legal · On-Device Voice") {
                            SupertonicLegalView()
                                .miniPlayerKeepOut()
                        }
                        .accessibilityIdentifier("settings.legal.supertonic.link")
                        NavigationLink("Legal · Open-Source Licenses") {
                            OpenSourceLicensesView()
                                .miniPlayerKeepOut()
                        }
                        .accessibilityIdentifier("settings.legal.openSource.link")
                        LabeledContent("Version", value: AppLinks.versionDescription)
                    }
                }
                #if DEBUG
                Section("Developer") {
                    DisclosureGroup("Developer tools", isExpanded: $showsDeveloperTools) {
                        Toggle("Record Detailed Device Diagnostics", isOn: $model.developerDiagnosticRecordingEnabled)
                            .accessibilityIdentifier("settings.developer.recordDiagnostics")
                        Text("Basic playback events are saved locally automatically (latest 300 events, no source text or audio). For detailed sampling, turn on, reproduce, then turn off and Share Diagnostics. Detailed recording keeps 1,200 events and is off after restart.")
                            .font(.caption)
                        Text(model.developerDiagnosticBuild).font(.caption.monospaced())
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
                        .disabled(model.libraryAccessError != nil) // never reset a Library this build couldn't open (#1969)
                        .accessibilityIdentifier("settings.reset.button")
                        Button("Refresh Diagnostics", action: model.refreshDiagnostics)
                            .accessibilityIdentifier("settings.diagnostics.button")
                        RuntimeDiagnosticRows(diagnostics: model.runtimeDiagnostics)
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
            .scrollContentBackground(.hidden)
            .background(AppColors.bone)
            .tint(AppColors.evergreen)
            .navigationTitle("Settings")
            .onAppear {
                guard !isEdgeSwipePreview else { return }  // a swipe's preview starts no refresh (#106)
                model.refreshSpeechVoiceOptions()
                model.refreshImportInbox()
                // A failed share must be seen, so the Inbox opens itself when it has something in it.
                if !model.importInbox.isEmpty || model.sourceLinksWaitingForNetwork > 0 { showsImportInbox = true }
                if supertonicNotice.takeVoicesRequest() { showsVoices = true }
            }
            // Settings is a tab now, so the card's button can land while it is already showing (#1254).
            .onCompatibleChange(of: supertonicNotice.opensVoices) { requested in
                if requested, supertonicNotice.takeVoicesRequest() { showsVoices = true }
            }
            .navigationDestination(isPresented: $showsVoices) {
                VoicesSettingsScreen(voices: model.requireVoiceDownloads()).miniPlayerKeepOut()
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
            .confirmationDialog(
                "Delete this shared item?",
                isPresented: Binding(
                    get: { pendingInboxDeletion != nil },
                    set: { if !$0 { pendingInboxDeletion = nil } }
                ),
                presenting: pendingInboxDeletion
            ) { entry in
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    model.deleteImportInboxEntry(entry)
                    pendingInboxDeletion = nil
                }
                .accessibilityIdentifier("importInbox.delete.confirm")
            } message: { entry in
                Text("\(entry.title) will be removed. You would have to share it again to add it.")
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
            .miniPlayerKeepOut()
        }
    }
}

private struct RuntimeDiagnosticRows: View {
    @ObservedObject var diagnostics: RuntimeDiagnostics

    var body: some View {
        ForEach(diagnostics.values.keys.sorted(), id: \.self) { key in
            LabeledContent(key, value: diagnostics.values[key] ?? "")
        }
    }
}

#if canImport(UIKit)
/// Hands a file (the listening-signals log, #483, or the diagnostics export, #903) to the share sheet.
/// Nothing is uploaded by the app.
private struct ShareFileActivityView: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

private extension View {
    /// A borderless button in a `Form` row only takes taps on its label's own size. Fill the row and
    /// make the empty space hit-testable so a tap beside the words starts the action (#1436).
    func fullRowTapTarget() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}
