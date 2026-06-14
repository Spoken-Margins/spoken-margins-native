import SwiftUI
import SessionKit

struct Gate1RootView: View {
    @EnvironmentObject private var model: Gate1AppModel

    var body: some View {
        Group {
            switch model.screen {
            case .home:
                HomeScreen()
            case .item:
                ItemScreen()
            case .playback:
                PlaybackScreen()
            case .settings:
                SettingsScreen()
            case .export:
                ExportScreen()
            }
        }
        .background(AppColors.background.ignoresSafeArea())
        .onAppear {
            if model.libraryItems.isEmpty {
                model.resetAndSeed()
            }
        }
    }
}

private struct HomeScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @FocusState private var focusedField: Field?

    private enum Field {
        case title
        case text
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    if horizontalSizeClass == .regular {
                        HStack(alignment: .top, spacing: 24) {
                            VStack(alignment: .leading, spacing: 22) {
                                header
                                StatusBanner()
                                createItem
                            }
                            .frame(maxWidth: 620, alignment: .topLeading)

                            VStack(alignment: .leading, spacing: 22) {
                                Color.clear.frame(height: 154)
                                queue
                            }
                            .frame(maxWidth: 520, alignment: .topLeading)
                        }
                        .frame(maxWidth: 1180, alignment: .topLeading)
                    } else {
                        VStack(alignment: .leading, spacing: 22) {
                            header
                            StatusBanner()
                            createItem
                            queue
                        }
                    }
                }
                .padding(20)
            }
            .accessibilityIdentifier("home.screen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: model.openSettings) {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                    .accessibilityIdentifier("home.settings.button")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Spoken Margins")
                .font(.system(size: 44, weight: .bold, design: .default))
                .minimumScaleFactor(0.72)
        }
    }

    private var createItem: some View {
        ProductPanel {
            VStack(alignment: .leading, spacing: 14) {
                Text("Create Item")
                    .font(.headline)
                TextField("Title", text: $model.importTitle)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .title)
                    .accessibilityIdentifier("create.title.field")
                TextEditor(text: $model.importText)
                    .frame(minHeight: 180)
                    .padding(8)
                    .background(AppColors.inputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppColors.border))
                    .focused($focusedField, equals: .text)
                    .accessibilityIdentifier("create.text.editor")
                Button(action: {
                    focusedField = nil
                    model.importTextItem()
                }) {
                    Label("Create And Start", systemImage: "plus")
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("create.start.button")
            }
        }
    }

    private var queue: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Listening Queue", systemImage: "music.note.list")
                    .font(.headline)
                Spacer()
                Button("Reset Samples", action: model.resetAndSeed)
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("reset.samples.button")
            }
            if model.libraryItems.isEmpty {
                ProductPanel {
                    Text("No items yet.")
                        .foregroundStyle(AppColors.secondaryText)
                }
            } else {
                ForEach(model.libraryItems) { item in
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
                                    Text(item.status)
                                        .font(.subheadline)
                                        .foregroundStyle(AppColors.secondaryText)
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
                            .accessibilityLabel("Start \(item.title)")
                            .accessibilityIdentifier("queue.start.\(item.id)")

                            if item.canDelete {
                                Button(role: .destructive) {
                                    model.deleteItem(id: item.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .frame(width: 42, height: 42)
                                }
                                .buttonStyle(DangerIconButtonStyle())
                                .accessibilityLabel("Delete \(item.title)")
                                .accessibilityIdentifier("queue.delete.\(item.id)")
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct ItemScreen: View {
    @EnvironmentObject private var model: Gate1AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    detailHeader
                    StatusBanner()
                    if !model.selectedItem.overview.isEmpty {
                        overview
                    }
                    listeningMapTools
                    chapters
                    sessions
                    actions
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
                    if model.selectedItem.id.hasPrefix("item-import-") {
                        Button(role: .destructive) {
                            model.deleteItem(id: model.selectedItem.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .accessibilityIdentifier("item.delete.button")
                    }
                }
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
                .minimumScaleFactor(0.7)
            HStack {
                Pill(model.selectedItem.status)
                Pill("\(max(1, model.selectedItem.chapters.count)) chapters")
                Pill("\(model.selectedItem.interjections.count) interjections")
            }
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
                Button {
                    model.generateListeningMap()
                } label: {
                    Label("Generate Listening Map", systemImage: "sparkles")
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("item.generateMap.button")
                Text("Listening Map JSON")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.secondaryText)
                TextEditor(text: $model.listeningMapJSON)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 130)
                    .padding(8)
                    .background(AppColors.inputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppColors.border))
                    .accessibilityIdentifier("item.mapJSON.editor")
                Button {
                    model.applyListeningMapJSON()
                } label: {
                    Label("Apply Listening Map JSON", systemImage: "checkmark.circle")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.listeningMapJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("item.applyMap.button")
            }
        }
    }

    private var chapters: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Resolved Chapters", systemImage: "music.note.list")
                    .font(.headline)
                Spacer()
            }
            if model.selectedItem.chapters.isEmpty {
                ProductPanel {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Mapless playback is available.")
                            .foregroundStyle(AppColors.secondaryText)
                        Button {
                            model.generateListeningMap()
                        } label: {
                            Label("Generate Listening Map", systemImage: "sparkles")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .accessibilityIdentifier("chapters.generateMap.button")
                    }
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
            if model.selectedItem.sessions.isEmpty {
                ProductPanel {
                    Text("No sessions yet.")
                        .foregroundStyle(AppColors.secondaryText)
                }
            } else {
                ForEach(model.selectedItem.sessions, id: \.id) { session in
                    ProductPanel {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.status)
                                    .font(.headline)
                                Text("\(session.completionPercent)% complete")
                                    .font(.subheadline)
                                    .foregroundStyle(AppColors.secondaryText)
                            }
                            Spacer()
                            Button {
                                model.startItem(id: session.itemId)
                            } label: {
                                Label("Resume", systemImage: "play")
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }
            }
        }
    }

    private var actions: some View {
        HStack {
            Button {
                model.startItem(id: model.selectedItem.id)
            } label: {
                Label("Start Listening", systemImage: "play.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("item.start.button")
            Button(action: model.openExport) {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(SecondaryButtonStyle())
            .accessibilityIdentifier("item.export.button")
        }
    }
}

private struct PlaybackScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var followUp = "Can you respond to that objection?"
    @State private var selectedInterjection: Interjection?
    @FocusState private var followUpFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    if horizontalSizeClass == .regular {
                        HStack(alignment: .top, spacing: 24) {
                            watchSurface
                                .frame(width: 430)
                            VStack(spacing: 20) {
                                timeline
                                conversation
                                StatusBanner()
                            }
                            .frame(maxWidth: 680)
                        }
                        .frame(maxWidth: 1160, alignment: .topLeading)
                    } else {
                        VStack(spacing: 20) {
                            watchSurface
                            timeline
                            conversation
                            StatusBanner()
                        }
                    }
                }
                .padding(20)
            }
            .accessibilityIdentifier("playback.screen")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: model.openHome) {
                        Label("Home", systemImage: "house")
                    }
                    .accessibilityIdentifier("playback.home.button")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        Button(action: model.endSession) {
                            Image(systemName: "stop.fill")
                        }
                        .disabled(!model.hasActiveSession)
                        .accessibilityLabel("End Session")
                        .accessibilityIdentifier("playback.end.button")
                        Button(action: model.openExport) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .disabled(!model.hasActiveSession)
                        .accessibilityIdentifier("playback.export.button")
                    }
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
        }
    }

    private var watchSurface: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Text(model.snapshot.targetType == "summary_turn_tts" ? "CURRENT SUMMARY" : "CURRENT CHAPTER")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppColors.watchSecondary)
                Text(model.snapshot.chapterTitle ?? model.selectedItem.title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                Text(model.currentChapter.map { "\($0.percent)% · \($0.title)" } ?? "\(model.snapshot.progressPercent)% complete")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.watchSecondary)
            }

            HStack(spacing: 16) {
                Button(action: model.skipBack) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(RoundPlaybackButtonStyle())
                .disabled(!model.hasActiveSession)
                .accessibilityIdentifier("playback.back.button")

                ZStack {
                    Circle()
                        .stroke(AppColors.watchControl, lineWidth: 12)
                    Circle()
                        .trim(from: 0, to: CGFloat(max(0, min(100, model.snapshot.progressPercent))) / 100)
                        .stroke(AppColors.accent, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Button(action: model.playPause) {
                        Image(systemName: model.snapshot.status == .playing ? "pause.fill" : "play.fill")
                            .font(.title)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppColors.text)
                    .accessibilityIdentifier("playback.play.button")
                }
                .frame(width: 108, height: 108)
                .background(Circle().fill(AppColors.accentSoft))

                Button(action: model.skipForward) {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(RoundPlaybackButtonStyle())
                .disabled(!model.hasActiveSession)
                .accessibilityIdentifier("playback.forward.button")
            }

            Text("Session \(model.snapshot.progressPercent)%")
                .font(.subheadline)
                .foregroundStyle(AppColors.watchSecondary)

            if model.snapshot.isRecording {
                VStack(spacing: 12) {
                    Label("Recording", systemImage: "record.circle.fill")
                        .foregroundStyle(.red)
                    HStack {
                        Button(action: model.finishInterjection) {
                            Label("Done", systemImage: "checkmark")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityIdentifier("interjection.done.button")
                        Button(action: model.cancelInterjection) {
                            Label("Cancel", systemImage: "xmark")
                        }
                        .buttonStyle(LightButtonStyle())
                        .accessibilityIdentifier("interjection.cancel.button")
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Button(action: model.summarize) {
                        Image(systemName: "sparkles")
                            .frame(width: 44, height: 52)
                    }
                    .buttonStyle(WatchSecondaryButtonStyle())
                    .disabled(!model.hasActiveSession)
                    .accessibilityIdentifier("playback.summary.button")

                    Button(action: model.beginInterjection) {
                        Label(model.snapshot.phase == .finished ? "Add Addendum" : "Interject", systemImage: "mic")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(InterjectButtonStyle())
                    .disabled(!model.hasActiveSession)
                    .accessibilityIdentifier("playback.interject.button")
                }
                Button(action: model.discuss) {
                    Label("Discuss", systemImage: "play")
                }
                .buttonStyle(LightButtonStyle())
                .disabled(!model.hasActiveSession)
                .accessibilityIdentifier("playback.discuss.button")
            }
        }
        .padding(24)
        .frame(maxWidth: 430)
        .background(AppColors.watchBackground)
        .clipShape(RoundedRectangle(cornerRadius: 34))
        .shadow(color: .black.opacity(0.18), radius: 22, y: 12)
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Timeline", systemImage: "music.note.list")
                    .font(.headline)
                Spacer()
            }
            if model.selectedItem.chapters.isEmpty && model.selectedItem.interjections.isEmpty {
                ProductPanel {
                    Text("No chapters or interjections yet.")
                        .foregroundStyle(AppColors.secondaryText)
                }
            } else {
                ForEach(timelineEntries) { entry in
                    switch entry {
                    case .chapter(let chapter):
                        Button {
                            model.jumpToChapter(chapter)
                        } label: {
                            TimelineRow(percent: "\(chapter.percent)%", title: chapter.title, subtitle: chapter.id)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("timeline.chapter.jump.\(chapter.id)")
                    case .interjection(let interjection):
                        Button {
                            selectedInterjection = interjection
                        } label: {
                            TimelineRow(
                                percent: "\(interjection.roughPercent)%",
                                title: interjection.displayText ?? interjection.transcript ?? interjection.audioStatus,
                                subtitle: "\(interjection.targetType.rawValue) · \(interjection.transcriptionStatus)"
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("timeline.interjection.\(interjection.id)")
                    case .turn(let turn):
                        TimelineRow(percent: "AI", title: turnTitle(turn), subtitle: turn.status)
                    }
                }
            }
        }
        .accessibilityIdentifier("timeline.section")
    }

    private var timelineEntries: [PlaybackTimelineEntry] {
        (
            model.selectedItem.chapters.map { PlaybackTimelineEntry.chapter($0) } +
            model.selectedItem.interjections.map { PlaybackTimelineEntry.interjection($0) } +
            model.selectedItem.turns.map { PlaybackTimelineEntry.turn($0) }
        )
        .sorted { lhs, rhs in
            if lhs.percent == rhs.percent {
                return lhs.sortRank < rhs.sortRank
            }
            return lhs.percent < rhs.percent
        }
    }

    private var conversation: some View {
        ProductPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "info.circle")
                    Spacer()
                    Text("Conversation")
                        .font(.headline)
                }
                if model.selectedItem.turns.isEmpty {
                    Text("Generate a summary or send a follow-up after listening.")
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
                                        model.playTurn(turn)
                                    } label: {
                                        Image(systemName: "play.fill")
                                            .frame(width: 34, height: 34)
                                    }
                                    .buttonStyle(IconButtonStyle())
                                    .accessibilityLabel("Play \(turnTitle(turn))")
                                    .accessibilityIdentifier("conversation.playTurn.\(turn.id)")
                                }
                                Pill(turn.status)
                            }
                            Text(turn.summary ?? turn.text ?? turn.rawText ?? "")
                                .font(.subheadline)
                                .foregroundStyle(AppColors.secondaryText)
                        }
                        Divider()
                    }
                }
                TextField("Continue the conversation...", text: $followUp, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .focused($followUpFocused)
                    .accessibilityIdentifier("conversation.followup.field")
                HStack {
                    Button("Submit") {
                        followUpFocused = false
                        model.followUp(followUp)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!model.hasActiveSession)
                    .accessibilityIdentifier("conversation.submit.button")
                    Button("Retry AI", action: model.retryPendingAI)
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(!model.hasActiveSession)
                        .accessibilityIdentifier("conversation.retry.button")
                }
            }
        }
        .accessibilityIdentifier("conversation.section")
    }
}

private struct SettingsScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @FocusState private var focusedField: Field?

    private enum Field {
        case baseURL
        case model
        case apiKey
    }

    var body: some View {
        NavigationStack {
            Form {
                StatusBanner()
                Section("Provider") {
                    TextField("Base URL", text: $model.providerBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .baseURL)
                        .accessibilityIdentifier("provider.baseURL.field")
                    TextField("Model", text: $model.providerModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .model)
                        .accessibilityIdentifier("provider.model.field")
                    SecureField("API Key", text: $model.providerAPIKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .apiKey)
                        .accessibilityIdentifier("provider.apiKey.field")
                    Button("Save Provider Key", action: model.saveProviderSettings)
                        .accessibilityIdentifier("provider.save.button")
                    Button("Probe Provider", action: model.probeProvider)
                        .accessibilityIdentifier("provider.probe.button")
                    LabeledContent("Probe", value: model.providerProbeStatus)
                }
                Section("Validation") {
                    Picker("Runtime Profile", selection: $model.selectedProfileId) {
                        Text("Phone/Tablet Online").tag("phone-tablet-online")
                        Text("Phone/Tablet Offline").tag("phone-tablet-offline")
                    }
                    .accessibilityIdentifier("runtime.profile.picker")
                    .onChange(of: model.selectedProfileId) { _, _ in
                        model.runtimeProfileChanged()
                    }
                    Button("Reset Seed Data", action: model.resetAndSeed)
                        .accessibilityIdentifier("settings.reset.button")
                    Button("Refresh Diagnostics", action: model.refreshDiagnostics)
                        .accessibilityIdentifier("settings.diagnostics.button")
                }
                Section("Diagnostics") {
                    ForEach(model.diagnostics.keys.sorted(), id: \.self) { key in
                        LabeledContent(key, value: model.diagnostics[key] ?? "")
                    }
                }
                Section("Known Issues") {
                    ForEach(model.knownIssues, id: \.self) { issue in
                        Text(issue)
                    }
                }
            }
            .accessibilityIdentifier("settings.screen")
            .navigationTitle("Settings")
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
        }
    }
}

private struct ExportScreen: View {
    @EnvironmentObject private var model: Gate1AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Export")
                        .font(.largeTitle.bold())
                    StatusBanner()
                    HStack {
                        Button("Build Session Export", action: model.buildExport)
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(!model.hasActiveSession)
                            .accessibilityIdentifier("export.build.button")
                        Button("Item", action: { model.openItem(id: model.selectedItem.id) })
                            .buttonStyle(SecondaryButtonStyle())
                            .accessibilityIdentifier("export.item.button")
                    }
                    ProductPanel {
                        Text(model.exportPreview.isEmpty ? "No export yet." : model.exportPreview)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("export.preview")
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
}

private enum PlaybackTimelineEntry: Identifiable {
    case chapter(Chapter)
    case interjection(Interjection)
    case turn(ConversationTurn)

    var id: String {
        switch self {
        case .chapter(let chapter): return "chapter-\(chapter.id)"
        case .interjection(let interjection): return "interjection-\(interjection.id)"
        case .turn(let turn): return "turn-\(turn.id)"
        }
    }

    var percent: Int {
        switch self {
        case .chapter(let chapter): return chapter.percent
        case .interjection(let interjection): return interjection.roughPercent
        case .turn: return 101
        }
    }

    var sortRank: Int {
        switch self {
        case .chapter: return 0
        case .interjection: return 1
        case .turn: return 2
        }
    }
}

private struct InterjectionDetailView: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dismiss) private var dismiss
    let interjection: Interjection

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    LabeledContent("Transcription", value: interjection.transcriptionStatus)
                    LabeledContent("Audio", value: interjection.audioPath ?? "none")
                    LabeledContent("Session", value: interjection.sessionId)
                    LabeledContent("Target", value: "\(interjection.targetType.rawValue):\(interjection.targetId)")
                }
                Section("Transcript") {
                    Text(interjection.cleanedTranscript ?? interjection.transcript ?? "No transcript yet.")
                        .textSelection(.enabled)
                    Button("Delete Transcript") {
                        model.deleteTranscript(interjection: interjection)
                        dismiss()
                    }
                    .disabled(interjection.transcript == nil && interjection.cleanedTranscript == nil)
                    .accessibilityIdentifier("interjection.detail.deleteTranscript")
                }
                Section("Anchors") {
                    Text("Before")
                        .font(.headline)
                    Text(interjection.anchor.anchorBefore.isEmpty ? "None" : interjection.anchor.anchorBefore)
                        .textSelection(.enabled)
                    Text("After")
                        .font(.headline)
                    Text(interjection.anchor.anchorAfter.isEmpty ? "None" : interjection.anchor.anchorAfter)
                        .textSelection(.enabled)
                }
                Section {
                    Button(role: .destructive) {
                        model.deleteInterjection(interjection)
                        dismiss()
                    } label: {
                        Label("Delete Interjection", systemImage: "trash")
                    }
                    .accessibilityIdentifier("interjection.detail.delete")
                }
            }
            .navigationTitle("Interjection")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier("interjection.detail.close")
                }
            }
        }
    }
}

private struct ProductPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppColors.border))
    }
}

extension Interjection: @retroactive Identifiable {}

private struct PlainPanelButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(configuration.isPressed ? 0.72 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppColors.border))
    }
}

private struct StatusBanner: View {
    @EnvironmentObject private var model: Gate1AppModel

    var body: some View {
        ProductPanel {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.statusMessage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(model.lastError == nil ? AppColors.text : Color.red)
                if let error = model.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

private struct TimelineRow: View {
    let percent: String
    let title: String
    let subtitle: String

    var body: some View {
        ProductPanel {
            HStack(alignment: .top, spacing: 14) {
                Text(percent)
                    .font(.headline)
                    .foregroundStyle(AppColors.green)
                    .frame(width: 64, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                }
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
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(AppColors.softGreen)
            .clipShape(Capsule())
    }
}

private func turnTitle(_ turn: ConversationTurn) -> String {
    switch turn.turnType {
    case "interjection_summary":
        return "Interjection Summary"
    case "assistant_response":
        return "AI Response"
    case "user_response":
        return "Follow-up"
    default:
        return turn.turnType.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private enum AppColors {
    static let background = Color(red: 0.96, green: 0.97, blue: 0.94)
    static let inputBackground = Color(red: 0.98, green: 0.99, blue: 0.97)
    static let border = Color(red: 0.84, green: 0.87, blue: 0.81)
    static let text = Color(red: 0.09, green: 0.13, blue: 0.11)
    static let secondaryText = Color(red: 0.38, green: 0.44, blue: 0.41)
    static let green = Color(red: 0.13, green: 0.43, blue: 0.30)
    static let softGreen = Color(red: 0.91, green: 0.94, blue: 0.88)
    static let accent = Color(red: 0.48, green: 0.82, blue: 0.59)
    static let accentSoft = Color(red: 0.67, green: 0.91, blue: 0.72)
    static let watchBackground = Color(red: 0.09, green: 0.13, blue: 0.11)
    static let watchControl = Color(red: 0.18, green: 0.24, blue: 0.21)
    static let watchSecondary = Color(red: 0.69, green: 0.75, blue: 0.70)
    static let dangerBackground = Color(red: 0.96, green: 0.88, blue: 0.86)
}

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .foregroundStyle(.white)
            .background(AppColors.green.opacity(configuration.isPressed ? 0.78 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct SecondaryButtonStyle: ButtonStyle {
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
            .background(Color.white.opacity(configuration.isPressed ? 0.75 : 1))
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
            .foregroundStyle(Color(red: 0.55, green: 0.13, blue: 0.11))
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
            .foregroundStyle(AppColors.text)
            .background(Color(red: 0.94, green: 0.82, blue: 0.42).opacity(configuration.isPressed ? 0.78 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
