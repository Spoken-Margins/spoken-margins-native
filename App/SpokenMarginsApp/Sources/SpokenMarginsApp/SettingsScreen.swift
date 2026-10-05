import SwiftUI
import SessionKit
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

struct SettingsScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @AppStorage("playbackUsesVerboseActions") private var usesVerbosePlaybackActions = true
    @FocusState private var focusedField: Field?
    @State private var showsAdvancedAISettings = false
    @State private var showsDeveloperTools = false
    @State private var pendingPermanentDeletion: LibraryItemRow?
    @State private var isEmptyRecentlyDeletedConfirmationPresented = false
    @State private var isResetConfirmationPresented = false
    @State private var copiedDiagnostics = false
    @AppStorage(CommunityMapUploadService.optInKey) private var helpsMakeListeningMaps = false

    private enum Field {
        case mapModel
        case summaryModel
        case conversationModel
        case apiKey
    }

    var body: some View {
        NavigationStack {
            Form {
                MarginOutputSettingsSection()
                Section("Bring Your Own Listening Map") {
                    NavigationLink("Import Listening Edition") { ListeningEditionImportScreen() }
                    NavigationLink("Read Later Services") { ReadLaterScreen() }
                }
                Section("Playback & Voice") {
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
                    Text("While Charging uses durable jobs and pauses between parts of an item when power, thermal, or storage safety changes. Completion timing is not guaranteed.")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                }
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
                        Text("Margin summaries stay on this device. Publisher podcast chapters and deterministic native-text Listening Maps do not require AI. AI-generated Listening Maps, remote providers, and API keys are disabled in this release.")
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                            .accessibilityIdentifier("settings.ai.releaseBoundary")
                    }
                }
                .onCompatibleChange(of: model.listeningMapModel) { _ in model.settingsValueChanged() }
                .onCompatibleChange(of: model.summaryModel) { _ in model.settingsValueChanged() }
                .onCompatibleChange(of: model.conversationModel) { _ in model.settingsValueChanged() }
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
                                FailureMessageLabel(entry.reason)
                                    .font(.caption)
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
                    Toggle(isOn: $helpsMakeListeningMaps) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Help make listening maps")
                            Text("Send transcripts of public episodes to the Spoken Margins server, which turns them into maps and then deletes them.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("settings.communityMaps.toggle")
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
                    NavigationLink("Legal · Open-Source Licenses") {
                        OpenSourceLicensesView()
                    }
                    .accessibilityIdentifier("settings.legal.openSource.link")
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
                        Toggle("Record Detailed Device Diagnostics", isOn: $model.developerDiagnosticRecordingEnabled)
                            .accessibilityIdentifier("settings.developer.recordDiagnostics")
                        Text("Basic playback events are saved locally automatically (latest 300 events, no source text or audio). For detailed sampling, turn on, reproduce, then turn off and Copy Privacy-Safe Diagnostics. Detailed recording keeps 1,200 events and is off after restart.")
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

private struct RuntimeDiagnosticRows: View {
    @ObservedObject var diagnostics: RuntimeDiagnostics

    var body: some View {
        ForEach(diagnostics.values.keys.sorted(), id: \.self) { key in
            LabeledContent(key, value: diagnostics.values[key] ?? "")
        }
    }
}
