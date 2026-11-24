import SwiftUI
import SessionKit
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

/// Settings: help and diagnostics first, then voice, controls, storage, import and export, privacy and legal, and the
/// developer tools in a debug build. Share Diagnostics is the first row, so it is reached without a scroll (#4781).
///
/// It does not watch `Gate1AppModel`: it reads what it shows through a `ScreenInputsFeed`, so a model publish that
/// leaves its rows as they were does not rebuild the form while the listener scrolls (#4028). The tab bar redraws on every
/// publish and shows it with `.equatable()`: it is equal to its last copy while the model and the notice are the same
/// ones, so the tab bar's redraw stops here. Without that, a hosted run drew it once per publish all the same (24 for 20).
struct SettingsScreen: View, Equatable {
    let model: Gate1AppModel
    /// The notice's identity, for `==`: the observed notice itself is read on the main actor only.
    private let supertonicNoticeID: ObjectIdentifier
    @StateObject private var feed: ScreenInputsFeed<Inputs>
    @Environment(\.isEdgeSwipePreview) private var isEdgeSwipePreview
    @AppStorage(HeadphoneDoublePressAction.storageKey) private var headphoneDoublePress = HeadphoneDoublePressAction.default.rawValue
    /// End a Margin by saying "stop margin" (#3940). On until the listener turns it off.
    @AppStorage(MarginEndPhraseAvailability.storageKey) private var endsMarginByPhrase = true
    /// Where footnotes are heard (#3777). Read at the next play, never mid-listen.
    @AppStorage(FootnoteMode.storageKey) private var footnoteMode = FootnoteMode.default.rawValue
    @State private var showsDeveloperTools = false
    #if DEBUG
    @FocusState private var editingMapJSON: Bool
    #endif
    @State private var showsAboutAndLegal = false
    @State private var pendingPermanentDeletion: LibraryItemRow?
    @State private var isEmptyRecentlyDeletedConfirmationPresented = false
    @State private var showsAllRecentlyDeleted = false
    @State private var isResetConfirmationPresented = false
    @State private var isPreparingDiagnostics = false
    @AppStorage(CommunityMapUploadService.optInKey) private var helpsMakeListeningMaps = false
    @AppStorage(CommunityMapFetchService.optInKey) private var looksUpCommunityMaps = false
    /// The Supertonic download card's "Open Voices" lands here and opens Voices (#1820).
    @ObservedObject private var supertonicNotice: SupertonicDownloadNotice
    /// The pages opened by value: Download Voices and the Import Inbox. "See why" and the Supertonic card set it (#4781).
    @State private var path: [SettingsPage] = []
    @State private var showsControls = false
    /// The Watch card's row in Help & Diagnostics shows only with a paired Watch that has the app (#4563). Not passed
    /// through `init` and out of `==`: a view's own observed object still redraws it.
    @ObservedObject private var watchTip = WatchReturnToAppTipNotice.shared

    init(model: Gate1AppModel, supertonicNotice: SupertonicDownloadNotice) {
        self.model = model
        _supertonicNotice = ObservedObject(wrappedValue: supertonicNotice)
        supertonicNoticeID = ObjectIdentifier(supertonicNotice)
        _feed = StateObject(wrappedValue: ScreenInputsFeed(model: model, read: Inputs.init))
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        #if DEBUG
        ScreenRedrawProbe.recordEqualityCheck("settings")
        #endif
        return lhs.model === rhs.model && lhs.supertonicNoticeID == rhs.supertonicNoticeID
    }

    /// Every value the form shows from the model. A publish that changes none of it leaves the screen alone. The
    /// voice downloads, connectivity, hidden senders and diagnostics are objects their own rows watch.
    struct Inputs: Equatable {
        var ttsVoiceSelection: AppTTSVoiceSelection
        var speechVoiceIdentifier: String
        var speechVoiceOptions: [SpeechVoiceChoice]
        var speechRate: Double
        var speechRateDescription: String
        var isRenderingSupertonicPreview: Bool
        var showsMixWithOtherAudioOption: Bool
        var skipUnit: String
        var mediaSkipBackSeconds: Int
        var mediaSkipForwardSeconds: Int
        var offlineStorageLimitGB: Int
        var offlineStorageUsageDescription: String
        var automaticAudioPreparationPolicy: AutomaticAudioPreparationPolicy
        var automaticEpisodeMapPreparationPolicy: AutomaticEpisodeMapPreparationPolicy
        var recentlyDeletedItems: [LibraryItemRow]
        var sourceLinksWaitingForNetwork: Int
        var importInbox: [ImportInboxEntry]
        var requestedSettingsPage: SettingsPage?
        var localFoundationModelAvailabilityDescription: String
        var hasAcceptedCurrentTerms: Bool
        var termsAcceptanceDescription: String
        #if DEBUG
        var developerDiagnosticRecordingEnabled: Bool
        var developerDiagnosticBuild: String
        var selectedProfileId: String
        var hasLibraryAccessError: Bool
        var knownIssues: [String]
        var selectedItemTitle: String
        var listeningMapJSON: String
        #endif

        @MainActor init(_ model: Gate1AppModel) {
            ttsVoiceSelection = model.ttsVoiceSelection
            speechVoiceIdentifier = model.speechVoiceIdentifier
            speechVoiceOptions = model.speechVoiceOptions
            speechRate = model.speechRate
            speechRateDescription = model.speechRateDescription
            isRenderingSupertonicPreview = model.isRenderingSupertonicPreview
            showsMixWithOtherAudioOption = model.showsMixWithOtherAudioOption
            skipUnit = model.skipUnit
            mediaSkipBackSeconds = model.mediaSkipBackSeconds
            mediaSkipForwardSeconds = model.mediaSkipForwardSeconds
            offlineStorageLimitGB = model.offlineStorageLimitGB
            offlineStorageUsageDescription = model.offlineStorageUsageDescription
            automaticAudioPreparationPolicy = model.automaticAudioPreparationPolicy
            automaticEpisodeMapPreparationPolicy = model.automaticEpisodeMapPreparationPolicy
            recentlyDeletedItems = model.recentlyDeletedItems
            sourceLinksWaitingForNetwork = model.sourceLinksWaitingForNetwork
            importInbox = model.importInbox
            requestedSettingsPage = model.requestedSettingsPage
            localFoundationModelAvailabilityDescription = model.localFoundationModelAvailabilityDescription
            hasAcceptedCurrentTerms = model.hasAcceptedCurrentTerms
            termsAcceptanceDescription = model.termsAcceptanceDescription
            #if DEBUG
            developerDiagnosticRecordingEnabled = model.developerDiagnosticRecordingEnabled
            developerDiagnosticBuild = model.developerDiagnosticBuild
            selectedProfileId = model.selectedProfileId
            hasLibraryAccessError = model.libraryAccessError != nil
            knownIssues = model.knownIssues
            selectedItemTitle = model.selectedItem.title
            listeningMapJSON = model.listeningMapJSON
            #endif
        }
    }

    var body: some View {
        #if DEBUG
        let _ = ScreenRedrawProbe.record("settings")
        #endif
        let inputs = feed.inputs
        NavigationStack(path: $path) {
            Form {
                helpAndDiagnosticsSection
                Section("Voice") {
                    AppVoicePicker(selection: model.screenBinding(\.ttsVoiceSelection), voices: model.requireVoiceDownloads())
                    .onCompatibleChange(of: inputs.ttsVoiceSelection) { _ in
                        model.ttsVoiceSelectionChanged()
                    }
                    Text(inputs.ttsVoiceSelection.detail)
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                    // A new listener starts on Phonon; the backup voice reads until it has downloaded (#2858).
                    PhononStatusLine(model: model, choice: inputs.ttsVoiceSelection, voices: model.requireVoiceDownloads(), connectivity: model.connectivity)
                    Text("Voice synthesized on-device. Spoken text comes from your selected source.")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                    if inputs.ttsVoiceSelection == .system {
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
                        NavigationLink {
                            SpeechVoiceListScreen(
                                voices: inputs.speechVoiceOptions,
                                chosenIdentifier: inputs.speechVoiceIdentifier,
                                select: { identifier in
                                    model.speechVoiceIdentifier = identifier
                                    model.ttsVoiceSelectionChanged()
                                })
                            .miniPlayerKeepOut()
                        } label: {
                            LabeledContent(
                                "Speech Voice",
                                value: SpeechVoiceListScreen.menu(
                                    voices: inputs.speechVoiceOptions, chosenIdentifier: inputs.speechVoiceIdentifier).valueText)
                        }
                        .accessibilityIdentifier("settings.speechVoice.picker")
                    }
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Speaking Rate")
                            Spacer()
                            Text(inputs.speechRateDescription)
                                .foregroundStyle(AppColors.secondaryText)
                        }
                        DiscretePlaybackRateSlider(
                            value: Binding(
                                get: { model.speechPlaybackRateMultiplier },
                                set: { model.speechRate = $0 * 0.5 }
                            ),
                            accessibilityLabel: "Speaking rate",
                            accessibilityValue: inputs.speechRateDescription,
                            accessibilityIdentifier: "settings.speechRate.slider"
                        )
                    }
                    .onCompatibleChange(of: inputs.speechRate) { _ in
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
                        .disabled(inputs.isRenderingSupertonicPreview)
                        .accessibilityIdentifier("settings.preview.appVoice.button")

                        Button {
                            model.previewAssistiveTechnologyVoice()
                        } label: {
                            Label("Try Assistive Tech", systemImage: "accessibility")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .accessibilityIdentifier("settings.preview.assistiveTech.button")
                    }
                    NavigationLink(value: SettingsPage.voices) {
                        Label("Download Voices", systemImage: "waveform")
                    }
                    .accessibilityIdentifier("settings.voices.link")
                    DisclosureGroup("Controls", isExpanded: $showsControls) {
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
                        Picker("Text Navigation", selection: model.screenBinding(\.skipUnit)) {
                            Text("Sentence").tag("sentence")
                            Text("Paragraph").tag("paragraph")
                            Text("Section").tag("section")
                        }
                        .accessibilityIdentifier("settings.skipUnit.picker")
                        .onCompatibleChange(of: inputs.skipUnit) { _ in
                            model.skipUnitChanged()
                        }
                        Picker("Footnotes", selection: Binding(
                            get: { FootnoteMode.pickerSelection(storedValue: footnoteMode).rawValue },
                            set: { footnoteMode = $0 }
                        )) {
                            ForEach(FootnoteMode.pickerChoices, id: \.self) { mode in
                                Text(mode.pickerTitle).tag(mode.rawValue)
                            }
                        }
                        .accessibilityIdentifier("settings.footnotes.picker")
                        Text(FootnoteMode.pickerCaption)
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                        Picker("Podcast Skip Back", selection: model.screenBinding(\.mediaSkipBackSeconds)) {
                            ForEach(Gate1AppModel.supportedMediaSkipSeconds, id: \.self) { seconds in
                                Text("\(seconds) seconds").tag(seconds)
                            }
                        }
                        .accessibilityIdentifier("settings.mediaSkipBack.picker")
                        .onCompatibleChange(of: inputs.mediaSkipBackSeconds) { _ in
                            model.mediaSkipSettingsChanged()
                        }
                        Picker("Headphone double-press", selection: $headphoneDoublePress) {
                            Text("Skip forward").tag(HeadphoneDoublePressAction.skipForward.rawValue)
                            Text("Add a Margin").tag(HeadphoneDoublePressAction.addMargin.rawValue)
                        }
                        .accessibilityIdentifier("settings.headphoneDoublePress.picker")
                        Text("Add a Margin starts one. End it by saying \u{201C}stop margin\u{201D}, with the button on screen, or by pressing your headphones (not every headset reports a press).")
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                        Toggle("End a Margin by saying \u{201C}stop margin\u{201D}", isOn: $endsMarginByPhrase)
                            .accessibilityIdentifier("settings.marginEndPhrase.toggle")
                        Text("Say \u{201C}stop margin\u{201D} or \u{201C}end margin\u{201D} when you\u{2019}re done. It\u{2019}s heard on this iPhone only. Silence never ends a Margin.")
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                        if SpeechRecognitionAccess.isOff {
                            Text("Needs Speech Recognition, which is off for Spoken Margins in iOS Settings.")
                                .font(.caption)
                                .foregroundStyle(AppColors.secondaryText)
                        }
                        Picker("Podcast Skip Forward", selection: model.screenBinding(\.mediaSkipForwardSeconds)) {
                            ForEach(Gate1AppModel.supportedMediaSkipSeconds, id: \.self) { seconds in
                                Text("\(seconds) seconds").tag(seconds)
                            }
                        }
                        .accessibilityIdentifier("settings.mediaSkipForward.picker")
                        .onCompatibleChange(of: inputs.mediaSkipForwardSeconds) { _ in
                            model.mediaSkipSettingsChanged()
                        }
                    }
                    .accessibilityIdentifier("settings.controls.disclosure")
                }
                Section("Storage") {
                    Button(action: model.openOfflineStorage) {
                        HStack {
                            Label("Manage Offline Storage", systemImage: "internaldrive")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(AppColors.secondaryText)
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityIdentifier("settings.offlineStorage.button")
                    Picker("Storage Budget", selection: model.screenBinding(\.offlineStorageLimitGB)) {
                        ForEach(OfflineStorageBudget.allowedGigabytes, id: \.self) { gigabytes in
                            Text("\(gigabytes) GB").tag(gigabytes)
                        }
                    }
                    .accessibilityIdentifier("settings.offlineStorageBudget.picker")
                    .onCompatibleChange(of: inputs.offlineStorageLimitGB) { _ in
                        model.offlineStorageBudgetChanged()
                    }
                    Text(inputs.offlineStorageUsageDescription)
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                    Picker("Automatic Audio Preparation", selection: model.screenBinding(\.automaticAudioPreparationPolicy)) {
                        ForEach(AutomaticAudioPreparationPolicy.allCases, id: \.self) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                    .accessibilityIdentifier("settings.automaticAudioPreparation.picker")
                    .onCompatibleChange(of: inputs.automaticAudioPreparationPolicy) { _ in
                        model.automaticAudioPreparationPolicyChanged()
                    }
                    Picker("Prepare Chapters and Scenes Ahead", selection: model.screenBinding(\.automaticEpisodeMapPreparationPolicy)) {
                        ForEach(AutomaticEpisodeMapPreparationPolicy.allCases, id: \.self) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                    .accessibilityIdentifier("settings.automaticEpisodeMapPreparation.picker")
                    .onCompatibleChange(of: inputs.automaticEpisodeMapPreparationPolicy) { _ in
                        model.automaticEpisodeMapPreparationPolicyChanged()
                    }
                    Text("Chapters and scenes for podcasts are prepared on your device and are off by default. While Charging only prepares episodes that are already downloaded; the full transcript and temporary audio are deleted once the chapters and scenes are saved.")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                    Text("While Charging uses durable jobs and pauses between parts of what it is preparing when power, thermal, or storage safety changes. Completion timing is not guaranteed.")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                    DisclosureGroup("Recently Deleted\(inputs.recentlyDeletedItems.isEmpty ? "" : " (\(inputs.recentlyDeletedItems.count))")") {
                        if inputs.recentlyDeletedItems.isEmpty {
                            Text("Anything moved here can be restored. Nothing is deleted automatically.")
                                .foregroundStyle(AppColors.secondaryText)
                        } else {
                            Button("Empty Recently Deleted", role: .destructive) {
                                isEmptyRecentlyDeletedConfirmationPresented = true
                            }
                            .accessibilityIdentifier("recentlyDeleted.empty.button")
                            let list = CollapsedListPresentation(
                                total: inputs.recentlyDeletedItems.count, isExpanded: showsAllRecentlyDeleted)
                            ForEach(Array(inputs.recentlyDeletedItems.prefix(list.shownCount))) { item in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title)
                                        .font(.headline)
                                    HStack {
                                        Button { model.restoreItem(id: item.id) } label: {
                                            Text("Restore").frame(minHeight: 44)
                                        }
                                        .buttonStyle(.borderless)
                                        .accessibilityLabel("Restore \(item.title)")
                                        .accessibilityIdentifier("recentlyDeleted.restore.\(item.id)")
                                        Spacer()
                                        // Permanent delete sits behind a menu, not beside Restore, so a slip of the
                                        // thumb restores instead of deleting (#3206). The confirmation stays.
                                        Menu {
                                            Button("Delete Permanently", role: .destructive) {
                                                pendingPermanentDeletion = item
                                            }
                                            .accessibilityIdentifier("recentlyDeleted.delete.\(item.id)")
                                        } label: {
                                            Image(systemName: "ellipsis.circle")
                                                .frame(minWidth: 44, minHeight: 44)
                                        }
                                        .buttonStyle(.borderless)
                                        .accessibilityLabel("More options for \(item.title)")
                                        .accessibilityIdentifier("recentlyDeleted.more.\(item.id)")
                                    }
                                }
                            }
                            if list.showsToggle {
                                Button {
                                    withMotion { showsAllRecentlyDeleted.toggle() }
                                } label: {
                                    Text(list.toggleTitle).frame(minHeight: 44).contentShape(Rectangle())
                                }
                                .accessibilityHint(list.toggleHint)
                                .accessibilityIdentifier("recentlyDeleted.toggle.button")
                            }
                        }
                    }
                }
                MarginOutputSettingsSection()
                HiddenSendersSettingsSection(hidden: model.hiddenSenders, showAgain: { model.showSender($0) }, showMarginAgain: { model.showMargin($0) })
                Section {
                    // Which folder files come in from (#3770): first in the section, drawn from the folder's own state.
                    // The Import Inbox row follows it (#4781).
                    QuickFolderSettingsRow(model: model)
                    // One row that says what is waiting; the list is its own page and never opens by itself (#4781).
                    ImportInboxRow(summary: ImportInboxSummary(
                        failedCount: inputs.importInbox.count, waitingCount: inputs.sourceLinksWaitingForNetwork))
                    NavigationLink {
                        YourAISettingsScreen(model: model).miniPlayerKeepOut()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Your AI", systemImage: "text.bubble")
                            Text("Let Claude, ChatGPT or another AI make your daily brief and suggest shows.")
                                .font(.footnote)
                                .foregroundStyle(AppColors.secondaryText)
                        }
                    }
                    .accessibilityIdentifier("settings.yourAI.row")
                    NavigationLink("Import Listening Edition") { ListeningEditionImportScreen().miniPlayerKeepOut() }
                    // #4341: the listener's own Zotero library, followed as papers from Following.
                    NavigationLink("Zotero") { ZoteroSettingsScreen().miniPlayerKeepOut() }
                        .accessibilityIdentifier("settings.zotero.row")
                    NavigationLink("Read Later Services") { ReadLaterScreen().miniPlayerKeepOut() }
                } header: {
                    Text("Import & Export")
                } footer: {
                    Text(QuickFolderStatus.sectionFooter)
                }
                Section("Privacy & Legal") {
                    Toggle(isOn: $helpsMakeListeningMaps) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Help make listening maps")
                            Text("Send transcripts of public episodes to the Spoken Margins server, which turns them into maps and then deletes them.")
                                .font(.footnote)
                                .foregroundStyle(AppColors.secondaryText)
                        }
                    }
                    .accessibilityIdentifier("settings.communityMaps.toggle")
                    Toggle(isOn: $looksUpCommunityMaps) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Look up community maps")
                            Text("When you open or play a public podcast episode with no chapters, ask the Spoken Margins server for a map other listeners helped make. This tells the server which episode you opened, and it can see your IP address.")
                                .font(.caption)
                                .foregroundStyle(AppColors.secondaryText)
                        }
                    }
                    .accessibilityIdentifier("settings.communityMapLookup.toggle")
                    #if canImport(UIKit)
                    ExportListeningSignalsButton(
                        exportFileURL: { [model] in await model.listeningSignals.exportFileURL() },
                        accessibilityIdentifier: "settings.exportListeningSignals.button"
                    )
                    Text("A private log of listening time, Margins, shares and finishes for followed sources: titles, times and counts, never Margin text or audio. It stays on this device unless you export it.")
                        .font(.footnote)
                        .foregroundStyle(AppColors.secondaryText)
                    #endif
                    Link("Privacy Policy", destination: AppLinks.privacy)
                    Link("Content Policy", destination: AppLinks.contentPolicy)
                    Link("Copyright and DMCA", destination: AppLinks.copyright)
                    DisclosureGroup("About & Legal", isExpanded: $showsAboutAndLegal) {
                        LabeledContent("Processing", value: "On device")
                            .accessibilityIdentifier("settings.ai.processing")
                        LabeledContent("Apple Foundation Model", value: inputs.localFoundationModelAvailabilityDescription)
                        Text("Margin summaries are made on this device. Publisher podcast chapters and deterministic native-text Listening Maps do not require AI. Spoken Margins has no third-party AI provider or API key setting. If you turn on Help make listening maps, podcast transcripts go to the Spoken Margins server, which uses an AI service to draft maps.")
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                            .accessibilityIdentifier("settings.ai.releaseBoundary")
                        NavigationLink("Terms of Use") {
                            SpokenMarginsTermsView(allowsAcceptance: !inputs.hasAcceptedCurrentTerms)
                                .miniPlayerKeepOut()
                        }
                        .accessibilityIdentifier("settings.terms.link")
                        LabeledContent("Terms Status", value: inputs.termsAcceptanceDescription)
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
                        Toggle("Record Detailed Device Diagnostics", isOn: model.screenBinding(\.developerDiagnosticRecordingEnabled))
                            .accessibilityIdentifier("settings.developer.recordDiagnostics")
                        Text("Basic playback events are saved locally automatically (latest 300 events, no source text or audio). For detailed sampling, turn on, reproduce, then turn off and Share Diagnostics. Detailed recording keeps 1,200 events and is off after restart.")
                            .font(.caption)
                        Text(inputs.developerDiagnosticBuild).font(.caption.monospaced())
                        Button("Add Sample Source", action: model.addSampleItem)
                        Picker("Runtime Profile", selection: model.screenBinding(\.selectedProfileId)) {
                            Text("Phone/Tablet Online").tag("phone-tablet-online")
                            Text("Phone/Tablet Offline").tag("phone-tablet-offline")
                        }
                        .accessibilityIdentifier("runtime.profile.picker")
                        .onCompatibleChange(of: inputs.selectedProfileId) { _ in
                            model.runtimeProfileChanged()
                        }
                        Button("Reset Library and Load Sample", role: .destructive) {
                            isResetConfirmationPresented = true
                        }
                        .disabled(inputs.hasLibraryAccessError) // never reset a Library this build couldn't open (#1969)
                        .accessibilityIdentifier("settings.reset.button")
                        Button("Refresh Diagnostics", action: model.refreshDiagnostics)
                            .accessibilityIdentifier("settings.diagnostics.button")
                        RuntimeDiagnosticRows(diagnostics: model.runtimeDiagnostics)
                        ForEach(inputs.knownIssues, id: \.self) { issue in
                            Text(issue)
                                .font(.caption)
                                .foregroundStyle(AppColors.secondaryText)
                        }
                    }
                    Text("Listening Map JSON")
                        .font(.headline)
                    Text("Developer diagnostic for \(inputs.selectedItemTitle.isEmpty ? "what is selected" : inputs.selectedItemTitle).")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                    TextEditor(text: model.screenBinding(\.listeningMapJSON))
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 130)
                        .accessibilityLabel("Listening Map JSON")
                        .accessibilityIdentifier("settings.developer.mapJSON.editor")
                        .focused($editingMapJSON)
                    Button("Apply Listening Map JSON", systemImage: "checkmark.circle") {
                        // Apply ends the editing, as Preview does for a Listening Edition: a keyboard left up
                        // covers the tab bar, so the listener could not reach the Library to see the map (#3924).
                        editingMapJSON = false
                        model.applyListeningMapJSON()
                    }
                    .disabled(inputs.listeningMapJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("settings.developer.mapJSON.apply")
                }
                #endif
            }
            .accessibilityIdentifier("settings.screen")
            .scrollContentBackground(.hidden)
            .background(AppColors.bone)
            .tint(AppColors.evergreen)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline) // the same header as Library, Following and Margins (#4019)
            .onAppear {
                guard !isEdgeSwipePreview else { return }  // a swipe's preview starts no refresh (#106)
                model.refreshSpeechVoiceOptions()
                model.refreshImportInbox()
                // The Inbox no longer opens itself (#4781): "See why" asks for its page, and the row shows the count.
                takeSettingsPageRequest()
                if supertonicNotice.takeVoicesRequest() { path = SettingsNavigation.path(current: path, request: .voices) }
            }
            // "See why" can land while Settings is already showing; it arrives through the feed (#1254, #4781).
            .onCompatibleChange(of: inputs.requestedSettingsPage) { requested in
                guard requested != nil, !isEdgeSwipePreview else { return }  // a swipe's preview must not use it up
                takeSettingsPageRequest()
            }
            // Settings is a tab now, so the card's button can land while it is already showing (#1254).
            .onCompatibleChange(of: supertonicNotice.opensVoices) { requested in
                if requested, supertonicNotice.takeVoicesRequest() { path = SettingsNavigation.path(current: path, request: .voices) }
            }
            .navigationDestination(for: SettingsPage.self) { page in
                switch page {
                case .voices:
                    VoicesSettingsScreen(voices: model.requireVoiceDownloads()).miniPlayerKeepOut()
                case .importInbox:
                    ImportInboxScreen(model: model).equatable().miniPlayerKeepOut()
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
                Text("All \(inputs.recentlyDeletedItems.count) recently deleted \(inputs.recentlyDeletedItems.count == 1 ? "entry" : "entries") and their sessions, notes, transcripts, and downloaded audio will be permanently deleted. This cannot be undone.")
            }
            .alert("Reset the entire library?", isPresented: $isResetConfirmationPresented) {
                Button("Cancel", role: .cancel) {}
                Button("Reset Library", role: .destructive, action: model.resetAndSeed)
            } message: {
                Text("This permanently deletes everything in your Library and its related records, then loads the sample.")
            }
            .miniPlayerKeepOut()
        }
    }

    /// Shows the page "See why" asked for, once. The request is cleared as it is read.
    private func takeSettingsPageRequest() {
        path = SettingsNavigation.path(current: path, request: model.takeSettingsPageRequest())
    }

    /// First, so Share Diagnostics is reached with no scroll at any text size (#4781).
    @ViewBuilder
    private var helpAndDiagnosticsSection: some View {
        Section("Help & Diagnostics") {
            #if canImport(UIKit)
            Button {
                isPreparingDiagnostics = true
                Task {
                    defer { isPreparingDiagnostics = false }
                    if let url = await model.prepareDiagnosticsExportFileURL() {
                        ShareFilePresenter.present(fileURL: url)
                    }
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
            Text("App state and recent playback events, as a file for a bug report. It includes the titles and links of what is in your Library. It stays on this device unless you share it.")
                .font(.footnote)
                .foregroundStyle(AppColors.secondaryText)
            #endif
            Button(action: model.openHelp) {
                Label("How Spoken Margins Works", systemImage: "questionmark.circle")
            }
            .accessibilityIdentifier("settings.help.button")
            Link("Support", destination: AppLinks.support)
            if watchTip.pairing.hasWatchApp {
                Button(action: watchTip.openFromSettings) {
                    Label("Keep Spoken Margins on Your Watch", systemImage: "applewatch")
                }
                .accessibilityIdentifier("settings.watchTip.button")
            }
            // Shown in every build while the app is distributed through TestFlight; removed before the first
            // App Store build (#1770). The whole message is a constant, so nothing from the Library goes with it.
            ShareLink(item: BetaInviteShare.text) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Share beta instructions", systemImage: "square.and.arrow.up")
                    Text("A short message with the link spokenmargins.com/join. Nothing from your Library goes with it.")
                        .font(.footnote)
                        .foregroundStyle(AppColors.secondaryText)
                }
                .fullRowTapTarget()
            }
            .buttonStyle(.borderless)
            .accessibilityHint("Opens the share sheet with a short message and a link to join the beta.")
            .accessibilityIdentifier("settings.shareBeta.button")
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

private extension View {
    /// A borderless button in a `Form` row only takes taps on its label's own size. Fill the row and
    /// make the empty space hit-testable so a tap beside the words starts the action (#1436).
    func fullRowTapTarget() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}
