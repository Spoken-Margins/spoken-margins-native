import SwiftUI
import SessionKit
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

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
    @State private var isImportingObsidianFiles = false

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
            .fileImporter(
                isPresented: $isImportingObsidianFiles,
                allowedContentTypes: [UTType(filenameExtension: "md") ?? .plainText],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    model.importObsidianMarkdownFiles(urls: urls)
                case .failure(let error):
                    model.reportImportFailure(error)
                }
            }
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
                Button {
                    focusedField = nil
                    isImportingObsidianFiles = true
                } label: {
                    Label("Import Obsidian Files", systemImage: "doc.badge.plus")
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("obsidian.import.button")
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
    @State private var showsManualListeningMapEditor = false

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
                    if model.selectedItem.id.hasPrefix("item-import-") || model.selectedItem.id.hasPrefix("item-obsidian-") {
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
                    Label(model.isGeneratingListeningMap ? "Generating Listening Map" : "Generate Listening Map", systemImage: "sparkles")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.isGeneratingListeningMap)
                .accessibilityIdentifier("item.generateMap.button")
                Button {
                    showsManualListeningMapEditor.toggle()
                } label: {
                    Label(showsManualListeningMapEditor ? "Hide Manual JSON" : "Paste Listening Map JSON", systemImage: "curlybraces")
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("item.toggleMapJSON.button")
                if showsManualListeningMapEditor {
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
                            Label(model.isGeneratingListeningMap ? "Generating Listening Map" : "Generate Listening Map", systemImage: "sparkles")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(model.isGeneratingListeningMap)
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
                            Button {
                                model.openSession(session)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(session.status)
                                        .font(.headline)
                                    Text("\(session.completionPercent)% complete")
                                        .font(.subheadline)
                                        .foregroundStyle(AppColors.secondaryText)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("session.inspect.\(session.id)")

                            Button {
                                model.resumeSession(session)
                            } label: {
                                Label("Resume", systemImage: "play")
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                    .accessibilityIdentifier("session.row.\(session.id)")
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
    @State private var followUp = "Can you respond to my interjection?"
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
                        if model.snapshot.isRecording {
                            Button(action: model.finishInterjection) {
                                Image(systemName: "checkmark")
                            }
                            .accessibilityLabel("Done Recording")
                            .accessibilityIdentifier("interjection.toolbar.done")
                            Button(action: model.cancelInterjection) {
                                Image(systemName: "xmark")
                            }
                            .accessibilityLabel("Cancel Recording")
                            .accessibilityIdentifier("interjection.toolbar.cancel")
                        }
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
                Text(playbackProgressLabel)
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
                        .trim(from: 0, to: CGFloat(max(0, min(100, model.snapshot.currentPlaybackProgressPercent))) / 100)
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

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Rate")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColors.watchSecondary)
                    Spacer()
                    Text(model.speechRateDescription)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(AppColors.watchSecondary)
                }
                Slider(value: $model.speechRate, in: 0.35...0.85, step: 0.01)
                    .accessibilityIdentifier("playback.speechRate.slider")
                    .onChange(of: model.speechRate) { _, _ in
                        model.saveSpeechSettings()
                    }
            }

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
                        if model.isSummarizingInterjections {
                            ProgressView()
                                .frame(width: 44, height: 52)
                        } else {
                            Image(systemName: "sparkles")
                                .frame(width: 44, height: 52)
                        }
                    }
                    .buttonStyle(WatchSecondaryButtonStyle())
                    .disabled(!model.canSummarizeInterjections || model.isSummarizingInterjections)
                    .accessibilityLabel(model.isSummarizingInterjections ? "Summarizing interjections" : "Summarize interjections")
                    .accessibilityIdentifier("playback.summary.button")

                    Button(action: model.beginInterjection) {
                        Label(model.interjectionButtonTitle, systemImage: "mic")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(InterjectButtonStyle())
                    .disabled(!model.hasActiveSession)
                    .accessibilityIdentifier("playback.interject.button")
                }
                Button {
                    followUpFocused = false
                    model.discuss(followUp: followUp)
                } label: {
                    Label("Discuss", systemImage: "play")
                }
                .buttonStyle(LightButtonStyle())
                .disabled(!model.hasActiveSession)
                .accessibilityIdentifier("playback.discuss.button")
            }

            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                gate2CompactValidation
            }
        }
        .padding(24)
        .frame(maxWidth: 430)
        .background(AppColors.watchBackground)
        .clipShape(RoundedRectangle(cornerRadius: 34))
        .shadow(color: .black.opacity(0.18), radius: 22, y: 12)
    }

    private var gate2CompactValidation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Gate 2 Compact")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppColors.watchSecondary)
            Text(model.gate2CompactSnapshot?.chapterTitle ?? "No compact snapshot")
                .font(.caption)
                .foregroundStyle(.white)
                .accessibilityIdentifier("gate2.compact.chapter")
            HStack(spacing: 8) {
                Button {
                    model.dispatchGate2CompactCommand(.skipBack)
                } label: {
                    Image(systemName: "gobackward.15")
                }
                .buttonStyle(WatchSecondaryButtonStyle())
                .accessibilityLabel("Gate 2 Compact Skip Back")
                .accessibilityIdentifier("gate2.compact.back.button")

                Button {
                    model.dispatchGate2CompactCommand(.togglePlayPause)
                } label: {
                    Image(systemName: "playpause")
                }
                .buttonStyle(WatchSecondaryButtonStyle())
                .accessibilityLabel("Gate 2 Compact Play Pause")
                .accessibilityIdentifier("gate2.compact.playPause.button")

                Button {
                    model.dispatchGate2CompactCommand(.skipForward)
                } label: {
                    Image(systemName: "goforward.15")
                }
                .buttonStyle(WatchSecondaryButtonStyle())
                .accessibilityLabel("Gate 2 Compact Skip Forward")
                .accessibilityIdentifier("gate2.compact.forward.button")
            }
        }
        .padding(.top, 8)
    }

    private var playbackProgressLabel: String {
        let current = "\(model.snapshot.currentPlaybackProgressPercent)% current"
        if model.snapshot.targetType == "item_text_tts" {
            return model.currentChapter.map { "\(current) · \($0.title)" } ?? current
        }
        return "\(current) · Source \(model.snapshot.sourceProgressPercent)%"
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
                            model.playSourceFromBeginning()
                        } label: {
                            TimelineRow(percent: "SRC", title: model.selectedItem.title, subtitle: "Play source from beginning")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("timeline.source.play")
                    case .overview:
                        Button {
                            model.playSourceFromBeginning()
                        } label: {
                            TimelineRow(percent: "SUM", title: "Summary", subtitle: model.selectedItem.overview)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("timeline.overview.play")
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
                                title: "Interjection",
                                subtitle: interjectionPreview(interjection)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("timeline.interjection.\(interjection.id)")
                    case .turn(let turn):
                        Button {
                            model.playTurn(turn)
                        } label: {
                            TimelineRow(percent: turnBadge(turn), title: turnTitle(turn), subtitle: turn.summary ?? turn.text ?? turn.status)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("timeline.turn.play.\(turn.id)")
                    case .turnChapter(let turn, let chapter):
                        Button {
                            model.jumpToTurnChapter(turn: turn, chapter: chapter)
                        } label: {
                            TimelineRow(percent: "AI \(chapter.percent)%", title: chapter.title, subtitle: turnTitle(turn))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("timeline.turnChapter.jump.\(turn.id).\(chapter.id)")
                    }
                }
            }
        }
        .accessibilityIdentifier("timeline.section")
    }

    private var timelineEntries: [PlaybackTimelineEntry] {
        let hasChapters = !model.selectedItem.chapters.isEmpty
        let hasSummary = !model.selectedItem.overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let sourceHeaderEntries: [PlaybackTimelineEntry]
        if hasSummary {
            sourceHeaderEntries = [.overview]
        } else if hasChapters {
            sourceHeaderEntries = []
        } else {
            sourceHeaderEntries = [.sourceItem]
        }
        let sourceEntries = (model.selectedItem.chapters.map { PlaybackTimelineEntry.chapter($0) } +
            model.selectedItem.interjections.filter { $0.targetType == .item }.map { PlaybackTimelineEntry.interjection($0) }
        )
        .sorted { lhs, rhs in
            if lhs.percent == rhs.percent {
                return lhs.sortRank < rhs.sortRank
            }
            return lhs.percent < rhs.percent
        }
        let turnEntries = model.selectedItem.turns.flatMap { turn -> [PlaybackTimelineEntry] in
            let chapters = turn.chapters ?? []
            return [PlaybackTimelineEntry.turn(turn)] +
            chapters.map { PlaybackTimelineEntry.turnChapter(turn, $0) } +
            model.selectedItem.interjections
                .filter { $0.targetId == turn.id && $0.targetType != .item }
                .map { PlaybackTimelineEntry.interjection($0) }
        }
        return sourceHeaderEntries + sourceEntries + turnEntries
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
    @State private var isImportingKokoroAssets = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case baseURL
        case mapModel
        case summaryModel
        case conversationModel
        case apiKey
        case kokoroVoice
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
                    SecureField("API Key", text: $model.providerAPIKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .apiKey)
                        .accessibilityIdentifier("provider.apiKey.field")
                    Button("Save Provider Settings", action: model.saveProviderSettings)
                        .accessibilityIdentifier("provider.save.button")
                    Button("Probe Provider", action: model.probeProvider)
                        .accessibilityIdentifier("provider.probe.button")
                    LabeledContent("Probe", value: model.providerProbeStatus)
                }
                .onChange(of: model.providerBaseURL) { _, _ in model.settingsValueChanged() }
                .onChange(of: model.listeningMapModel) { _, _ in model.settingsValueChanged() }
                .onChange(of: model.summaryModel) { _, _ in model.settingsValueChanged() }
                .onChange(of: model.conversationModel) { _, _ in model.settingsValueChanged() }
                Section("Validation") {
                    Picker("Speech Voice", selection: $model.speechVoiceIdentifier) {
                        Text("System Spoken Content Voice (Siri falls back)").tag("")
                        ForEach(model.speechVoiceOptions) { voice in
                            Text("\(voice.name) · \(voice.language) · \(voice.quality)")
                                .tag(voice.id)
                        }
                    }
                    .accessibilityIdentifier("settings.speechVoice.picker")
                    .onChange(of: model.speechVoiceIdentifier) { _, _ in
                        model.speechSettingsChanged()
                    }
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Speaking Rate")
                            Spacer()
                            Text(model.speechRateDescription)
                                .foregroundStyle(AppColors.secondaryText)
                        }
                        Slider(value: $model.speechRate, in: 0.35...0.85, step: 0.01)
                            .accessibilityIdentifier("settings.speechRate.slider")
                    }
                    .onChange(of: model.speechRate) { _, _ in
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
                        .accessibilityIdentifier("settings.preview.appVoice.button")

                        Button {
                            model.previewAssistiveTechnologyVoice()
                        } label: {
                            Label("Try Assistive Tech", systemImage: "accessibility")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .accessibilityIdentifier("settings.preview.assistiveTech.button")
                    }
                    Picker("Session TTS", selection: $model.ttsMode) {
                        Text("System Speech").tag("systemImmediate")
                        if model.isKokoroDeviceBuild {
                            Text("Kokoro Pre-render").tag("kokoro")
                        }
                    }
                    .accessibilityIdentifier("settings.ttsMode.picker")
                    .onChange(of: model.ttsMode) { _, _ in
                        model.speechSettingsChanged()
                    }
                    Text(model.isKokoroDeviceBuild ? "Kokoro renders bounded segments on device and falls back to system speech if a segment fails." : "Kokoro requires the SpokenMarginsAppDevice scheme on a physical device.")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                    if model.isKokoroDeviceBuild {
                        TextField("Kokoro Voice", text: $model.kokoroVoiceName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .kokoroVoice)
                            .accessibilityIdentifier("settings.kokoroVoice.field")
                            .onChange(of: model.kokoroVoiceName) { _, _ in
                                model.speechSettingsChanged()
                            }
                        LabeledContent("Kokoro MLX Cache", value: "\(model.kokoroCacheLimitMB) MB fixed")
                        VStack(alignment: .leading) {
                            HStack {
                                Text("Kokoro Chunk Size")
                                Spacer()
                                Text("\(Int(model.kokoroChunkCharacters.rounded())) chars")
                                    .foregroundStyle(AppColors.secondaryText)
                            }
                            Slider(value: $model.kokoroChunkCharacters, in: 80...140, step: 10)
                                .accessibilityIdentifier("settings.kokoroChunkCharacters.slider")
                        }
                        .onChange(of: model.kokoroChunkCharacters) { _, _ in
                            model.speechSettingsChanged()
                        }
                        Button {
                            isImportingKokoroAssets = true
                        } label: {
                            Label("Import Kokoro Assets", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .accessibilityIdentifier("settings.import.kokoroAssets.button")
                        Text("Expected: kokoro-v1_0.safetensors, roughly hundreds of MB, and voices.npz, roughly tens of MB. Individual .pt voice files are not enough for this renderer.")
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                        Button {
                            model.previewKokoroVoice()
                        } label: {
                            Label(
                                model.isRenderingKokoroPreview ? "Rendering Kokoro Preview" : "Render Kokoro Preview",
                                systemImage: "waveform"
                            )
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(model.isRenderingKokoroPreview)
                        .accessibilityIdentifier("settings.preview.kokoro.button")
                        Button {
                            model.runKokoroMemoryCheck()
                        } label: {
                            Label(
                                model.isRunningKokoroMemoryCheck ? "Running Kokoro Memory Check" : "Run Kokoro Memory Check",
                                systemImage: "memorychip"
                            )
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(model.isRunningKokoroMemoryCheck || model.isRenderingKokoroPreview)
                        .accessibilityIdentifier("settings.memoryCheck.kokoro.button")
                        LabeledContent("Kokoro", value: model.kokoroStatus)
                    }
                    Picker("Skip Increment", selection: $model.skipUnit) {
                        Text("Sentence").tag("sentence")
                        Text("Paragraph").tag("paragraph")
                        Text("Section").tag("section")
                    }
                    .accessibilityIdentifier("settings.skipUnit.picker")
                    .onChange(of: model.skipUnit) { _, _ in
                        model.settingsValueChanged()
                        model.saveProviderSettings()
                    }
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
            .onAppear {
                model.refreshKokoroAssetStatus()
            }
            .fileImporter(
                isPresented: $isImportingKokoroAssets,
                allowedContentTypes: [
                    UTType(filenameExtension: "safetensors") ?? .data,
                    UTType(filenameExtension: "npz") ?? .data
                ],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    model.importKokoroAssets(urls: urls)
                case .failure(let error):
                    model.reportImportFailure(error)
                }
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
                        Button("Copy Plain Text", action: model.copyPlainTextExport)
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(model.exportPreview.isEmpty)
                            .accessibilityIdentifier("export.copyPlainText.button")
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
    case sourceItem
    case overview
    case chapter(Chapter)
    case interjection(Interjection)
    case turn(ConversationTurn)
    case turnChapter(ConversationTurn, Chapter)

    var id: String {
        switch self {
        case .sourceItem: return "source-item"
        case .overview: return "overview"
        case .chapter(let chapter): return "chapter-\(chapter.id)"
        case .interjection(let interjection): return "interjection-\(interjection.id)"
        case .turn(let turn): return "turn-\(turn.id)"
        case .turnChapter(let turn, let chapter): return "turn-chapter-\(turn.id)-\(chapter.id)"
        }
    }

    var percent: Int {
        switch self {
        case .sourceItem: return 0
        case .overview: return 0
        case .chapter(let chapter): return chapter.percent
        case .interjection(let interjection): return interjection.targetType == .item ? interjection.roughPercent : 101
        case .turn: return 101
        case .turnChapter: return 101
        }
    }

    var sortRank: Int {
        switch self {
        case .sourceItem: return -2
        case .overview: return -1
        case .chapter: return 0
        case .interjection(let interjection): return interjection.targetType == .item ? 1 : 4
        case .turn: return 2
        case .turnChapter: return 3
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
            .foregroundStyle(AppColors.text)
            .background(AppColors.panel)
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
            .foregroundStyle(AppColors.text)
            .background(AppColors.panel.opacity(configuration.isPressed ? 0.72 : 1))
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
                        .lineLimit(3)
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

private enum AppColors {
    static let background = dynamicColor(light: (0.96, 0.97, 0.94), dark: (0.07, 0.09, 0.08))
    static let panel = dynamicColor(light: (1.00, 1.00, 1.00), dark: (0.13, 0.16, 0.14))
    static let inputBackground = dynamicColor(light: (0.98, 0.99, 0.97), dark: (0.10, 0.12, 0.11))
    static let border = dynamicColor(light: (0.84, 0.87, 0.81), dark: (0.28, 0.34, 0.30))
    static let text = dynamicColor(light: (0.09, 0.13, 0.11), dark: (0.92, 0.95, 0.91))
    static let secondaryText = dynamicColor(light: (0.38, 0.44, 0.41), dark: (0.66, 0.72, 0.68))
    static let green = dynamicColor(light: (0.13, 0.43, 0.30), dark: (0.50, 0.84, 0.62))
    static let softGreen = dynamicColor(light: (0.91, 0.94, 0.88), dark: (0.18, 0.25, 0.20))
    static let accent = dynamicColor(light: (0.48, 0.82, 0.59), dark: (0.56, 0.89, 0.67))
    static let accentSoft = dynamicColor(light: (0.67, 0.91, 0.72), dark: (0.25, 0.39, 0.28))
    static let watchBackground = Color(red: 0.09, green: 0.13, blue: 0.11)
    static let watchControl = Color(red: 0.18, green: 0.24, blue: 0.21)
    static let watchSecondary = Color(red: 0.69, green: 0.75, blue: 0.70)
    static let dangerText = dynamicColor(light: (0.55, 0.13, 0.11), dark: (1.00, 0.55, 0.48))
    static let dangerBackground = dynamicColor(light: (0.96, 0.88, 0.86), dark: (0.34, 0.15, 0.13))

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
