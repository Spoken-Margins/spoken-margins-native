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
        .safeAreaInset(edge: .top, spacing: 8) {
            if model.lastError != nil || model.trashUndo != nil || model.sourceImportProgressMessage != nil || model.isReviewDemoActive || model.legacyLibraryResetNotice != nil {
                VStack(spacing: 8) {
                    if model.isReviewDemoActive {
                        ReviewDemoBanner()
                    }
                    if let resetNotice = model.legacyLibraryResetNotice {
                        LegacyLibraryResetBanner(message: resetNotice)
                    }
                    if let progressMessage = model.sourceImportProgressMessage {
                        SourceOperationBanner(message: progressMessage)
                    }
                    if model.lastError != nil {
                        StatusBanner()
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
            if model.shouldShowMiniPlayer {
                MiniPlayerBar()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
        }
        .edgeSwipeBack(enabled: model.screen != .home, action: model.openHome)
        .onAppear {
            model.bootstrapLibraryIfNeeded()
        }
        .sheet(isPresented: $model.isAIDataSharingConsentPresented) {
            AIDataSharingConsentView()
                .environmentObject(model)
                .interactiveDismissDisabled()
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

private struct ReviewDemoBanner: View {
    var body: some View {
        Label("Review Demo · simulated AI · no content leaves this device", systemImage: "checkmark.shield")
            .font(.caption.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .foregroundStyle(AppColors.text)
            .background(AppColors.accentSoft)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityIdentifier("reviewDemo.banner")
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

private struct MiniPlayerBar: View {
    @EnvironmentObject private var model: Gate1AppModel

    var body: some View {
        HStack(spacing: 12) {
            Button(action: model.openPlayback) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        if model.snapshot.isRecording {
                            Image(systemName: "waveform.circle.fill")
                                .foregroundStyle(.red)
                            Text("Recording interjection")
                        } else {
                            Text(model.snapshot.chapterTitle ?? model.snapshot.title ?? model.selectedItem.title)
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    ProgressView(value: Double(model.displayPlaybackProgressPercent), total: 100)
                        .tint(AppColors.primaryAction)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Now Playing")
            .accessibilityIdentifier("miniPlayer.open.button")

            if model.snapshot.isRecording {
                Button(action: model.finishInterjection) {
                    Image(systemName: "checkmark")
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(IconButtonStyle())
                .accessibilityLabel("Finish interjection")
            } else {
                Button(action: model.playPause) {
                    Group {
                        if model.snapshot.status == .starting {
                            ProgressView()
                        } else {
                            Image(systemName: model.snapshot.status.isPlaybackActive ? "pause.fill" : "play.fill")
                        }
                    }
                    .frame(width: 42, height: 42)
                }
                .buttonStyle(IconButtonStyle())
                .accessibilityLabel(model.snapshot.status.isPlaybackActive ? "Pause" : "Play")
                .accessibilityIdentifier("miniPlayer.playPause.button")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .foregroundStyle(AppColors.text)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AppColors.border))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
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

    private enum Field {
        case title
        case text
        case sourceLink
    }

    private enum FileImportRequest {
        case obsidianFiles
        case quickFolder
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
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
                    Button(action: model.openSettings) {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                    .accessibilityIdentifier("home.settings.button")
                }
                ToolbarItem(placement: .topBarTrailing) {
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
            .sheet(isPresented: $isAddSourcePresented) {
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
                            Button("Close") { isAddSourcePresented = false }
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
        }
    }

    private var fileImportAllowedContentTypes: [UTType] {
        switch activeFileImportRequest {
        case .quickFolder:
            return [.folder]
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
                isAddSourcePresented = false
            case .quickFolder:
                if let url = urls.first {
                    model.configureQuickAccessFolder(url: url)
                }
            case .none:
                model.reportImportFailure(FileImportPresentationError.missingRequest)
            }
        case .failure(let error):
            model.reportImportFailure(error)
        }
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

    private var createItem: some View {
        ProductPanel {
            VStack(alignment: .leading, spacing: 14) {
                Text("Paste Text")
                    .font(.headline)
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
                    focusedField = nil
                    presentFileImporter(.obsidianFiles)
                } label: {
                    Label("Import Text or PDF Files", systemImage: "doc.badge.plus")
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("obsidian.import.button")
                Divider()
                    .padding(.vertical, 4)
                HStack(spacing: 8) {
                    TextField("Podcast, RSS, or audio URL", text: $model.sourceLinkURL)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .focused($focusedField, equals: .sourceLink)
                        .accessibilityIdentifier("sourceLink.url.field")
                    Button {
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
                Button {
                    focusedField = nil
                    isAddSourcePresented = false
                    model.beginSourceLinkImportFromForm()
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
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.sourceLinkURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isResolvingSourceLink)
                .accessibilityIdentifier("sourceLink.import.button")
            }
        }
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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Your Library", systemImage: "music.note.list")
                    .font(.headline)
                Spacer()
            }
            if model.libraryItems.isEmpty {
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

private struct ItemScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @State private var showsManualListeningMapEditor = false
    @State private var isTrashConfirmationPresented = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    detailHeader
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
                .minimumScaleFactor(0.7)
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
        }
    }

    @ViewBuilder
    private var itemMetadataPills: some View {
        Pill(humanizedItemStatus(model.selectedItem.status))
        if !model.selectedItem.chapters.isEmpty {
            Pill("\(model.selectedItem.chapters.count) \(model.selectedItem.chapters.count == 1 ? "chapter" : "chapters")")
        }
        if !model.selectedItem.interjections.isEmpty {
                Pill("\(model.selectedItem.interjections.count) interjections")
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
                        .accessibilityLabel("Listening Map JSON")
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
                                    Text(humanizedItemStatus(session.status))
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
        VStack(alignment: .leading, spacing: 12) {
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
}

private struct PlaybackScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var followUp = ""
    @State private var selectedInterjection: Interjection?
    @State private var isPastingAssistantResponse = false
    @State private var scrubberSeconds = 0.0
    @State private var isScrubbing = false
    @FocusState private var followUpFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    if horizontalSizeClass == .regular {
                        HStack(alignment: .top, spacing: 24) {
                            playbackControls
                                .frame(width: 430)
                            VStack(spacing: 20) {
                                timeline
                                conversation
                            }
                            .frame(maxWidth: 680)
                        }
                        .frame(maxWidth: 1160, alignment: .topLeading)
                    } else {
                        VStack(spacing: 20) {
                            playbackControls
                            timeline
                            conversation
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
            .sheet(isPresented: $isPastingAssistantResponse) {
                PastedAssistantResponseView(isPresented: $isPastingAssistantResponse)
                    .environmentObject(model)
            }
            .onAppear {
                scrubberSeconds = Double(model.snapshot.currentMediaTimeMs ?? 0) / 1_000
            }
            .onChange(of: model.snapshot.currentMediaTimeMs) { _, mediaTimeMs in
                guard !isScrubbing else { return }
                scrubberSeconds = Double(mediaTimeMs ?? 0) / 1_000
            }
        }
    }

    private var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing")
            || ProcessInfo.processInfo.environment["SPOKEN_MARGINS_UI_TESTING"] == "1"
    }

    private var playbackControls: some View {
        VStack(spacing: 18) {
            playbackHeader
            if isUITesting {
                gate2CompactValidation
            }
            playbackPosition
            playbackTransport
            playbackRateControl
            interjectionControls
        }
        .padding(24)
        .frame(maxWidth: 430)
        .background(AppColors.watchBackground)
        .clipShape(RoundedRectangle(cornerRadius: 34))
        .shadow(color: .black.opacity(0.18), radius: 22, y: 12)
    }

    private var playbackHeader: some View {
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
    }

    @ViewBuilder
    private var playbackPosition: some View {
        if model.isMediaPlaybackSnapshot, mediaDurationMs > 0 {
            VStack(spacing: 6) {
                Slider(
                    value: Binding(
                        get: { isScrubbing ? scrubberSeconds : Double(model.snapshot.currentMediaTimeMs ?? 0) / 1_000 },
                        set: { scrubberSeconds = $0 }
                    ),
                    in: 0...Double(mediaDurationMs) / 1_000,
                    onEditingChanged: { editing in
                        isScrubbing = editing
                        if !editing { model.seekMedia(toMediaTimeMs: Int(scrubberSeconds * 1_000)) }
                    }
                )
                .tint(AppColors.accent)
                .accessibilityLabel("Playback position")
                .accessibilityValue("\(formatPlaybackTime(Int(scrubberSeconds * 1_000))) of \(formatPlaybackTime(mediaDurationMs))")
                .accessibilityIdentifier("playback.scrubber")
                HStack {
                    Text(formatPlaybackTime(Int(scrubberDisplaySeconds * 1_000)))
                    Spacer()
                    Text("−\(formatPlaybackTime(max(0, mediaDurationMs - Int(scrubberDisplaySeconds * 1_000))))")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(AppColors.watchSecondary)
            }
        } else {
            ProgressView(value: Double(model.displayPlaybackProgressPercent), total: 100)
                .tint(AppColors.accent)
                .accessibilityLabel("Playback progress")
                .accessibilityValue("\(model.displayPlaybackProgressPercent) percent")
        }
    }

    private var playbackTransport: some View {
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
                        Image(systemName: model.snapshot.status.isPlaybackActive ? "pause.fill" : "play.fill")
                    }
                }
            }
            .buttonStyle(MainPlaybackButtonStyle())
            .accessibilityLabel(model.snapshot.status.isPlaybackActive ? "Pause" : "Play")
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
    }

    private var playbackRateControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.isMediaPlaybackSnapshot ? "Playback Speed" : "Speech Rate")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(model.isMediaPlaybackSnapshot ? model.mediaPlaybackRateDescription : model.speechRateDescription)
                    .font(.caption.monospacedDigit())
            }
            .foregroundStyle(AppColors.watchSecondary)
            if model.isMediaPlaybackSnapshot {
                Slider(value: Binding(get: { model.mediaPlaybackRate }, set: { model.setMediaPlaybackRate($0) }), in: 0.75...2.0, step: 0.25)
                    .accessibilityLabel("Playback speed")
                    .accessibilityValue(String(format: "%.2f times", model.mediaPlaybackRate))
                    .accessibilityIdentifier("playback.mediaRate.slider")
                Text("Transcript: \(model.sourceTranscriptStatusDescription)")
                    .font(.caption2)
                    .foregroundStyle(AppColors.watchSecondary)
                    .accessibilityIdentifier("playback.sourceTranscript.status")
            } else {
                Slider(value: $model.speechRate, in: 0.35...0.85, step: 0.01)
                    .accessibilityLabel("Speaking rate")
                    .accessibilityValue(model.speechRateDescription)
                    .accessibilityIdentifier("playback.speechRate.slider")
                    .onChange(of: model.speechRate) { _, _ in model.playbackSpeechRateChanged() }
                Text("Prepared audio: \(model.preparedTextAudioStatusDescription)")
                    .font(.caption2)
                    .foregroundStyle(AppColors.watchSecondary)
                    .accessibilityIdentifier("playback.preparedAudio.status")
                if model.canPlayLiveSpeechInstead {
                    Button(action: model.playLiveSpeechInstead) { Label("Play Live Speech Instead", systemImage: "speaker.wave.2") }
                        .buttonStyle(SecondaryButtonStyle())
                        .accessibilityIdentifier("playback.liveSpeechFallback.button")
                }
            }
        }
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
                HStack(spacing: 10) {
                    Button(action: model.summarize) {
                        Group {
                            if model.isSummarizingInterjections { ProgressView() } else { Image(systemName: "sparkles") }
                        }
                        .frame(width: 44, height: 52)
                    }
                    .buttonStyle(WatchSecondaryButtonStyle())
                    .disabled(!model.canSummarizeInterjections || model.isSummarizingInterjections)
                    .accessibilityLabel(model.isSummarizingInterjections ? "Summarizing interjections" : "Summarize interjections")
                    .accessibilityIdentifier("playback.summary.button")
                    Button(action: model.beginInterjection) {
                        Label(model.interjectionButtonTitle, systemImage: "mic").frame(maxWidth: .infinity)
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
                .disabled(!model.hasActiveSession || followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("playback.discuss.button")
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

    private var playbackProgressLabel: String {
        let current = "\(model.snapshot.currentPlaybackProgressPercent)% current"
        if model.snapshot.targetType == "item_text_tts" {
            return model.currentChapter.map { "\(current) · \($0.title)" } ?? current
        }
        return "\(current) · Source \(model.snapshot.sourceProgressPercent)%"
    }

    private var mediaDurationMs: Int {
        max(0, model.snapshot.currentPlaybackDurationMs ?? 0)
    }

    private var scrubberDisplaySeconds: Double {
        isScrubbing ? scrubberSeconds : Double(model.snapshot.currentMediaTimeMs ?? 0) / 1_000
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
                        TimelineRow(percent: "MAP", title: "Listening overview", subtitle: model.selectedItem.overview)
                            .accessibilityIdentifier("timeline.overview")
                    case .chapter(let chapter):
                        Button {
                            model.jumpToChapter(chapter)
                        } label: {
                            TimelineRow(percent: "\(chapter.percent)%", title: chapter.title, subtitle: "Starts around \(chapter.percent)%")
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
                            TimelineRow(percent: turnBadge(turn), title: turnTitle(turn), subtitle: turn.summary ?? turn.text ?? humanizedTurnStatus(turn.status))
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
        .accessibilityIdentifier("conversation.section")
    }
}

private struct SettingsScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @FocusState private var focusedField: Field?
    @State private var showsAdvancedAISettings = false
    @State private var showsDeveloperTools = false
    @State private var pendingPermanentDeletion: LibraryItemRow?
    @State private var isResetConfirmationPresented = false

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
                }
                .onChange(of: model.listeningMapModel) { _, _ in model.settingsValueChanged() }
                .onChange(of: model.summaryModel) { _, _ in model.settingsValueChanged() }
                .onChange(of: model.conversationModel) { _, _ in model.settingsValueChanged() }
                Section("Review Demo") {
                    LabeledContent("Status", value: model.reviewDemoStatus)
                        .accessibilityIdentifier("reviewDemo.status")
                    if model.isReviewDemoActive {
                        Text("AI responses are simulated on this device. No source text, transcripts, or follow-ups are sent to OpenAI.")
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                        Button("Disable Review Demo", role: .destructive, action: model.disableReviewDemo)
                            .accessibilityIdentifier("reviewDemo.disable.button")
                    } else {
                        SecureField("Review access code", text: $model.reviewDemoUnlockCode)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .accessibilityLabel("Review access code")
                            .accessibilityIdentifier("reviewDemo.code.field")
                        Button("Unlock Review Demo", action: model.unlockReviewDemo)
                            .disabled(model.reviewDemoUnlockCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("reviewDemo.unlock.button")
                    }
                }
                Section("Playback & Voice") {
                    HStack {
                        Text("Native Voices")
                        Spacer()
                        Button {
                            model.refreshSpeechVoiceOptions()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(IconButtonStyle())
                        .accessibilityLabel("Refresh Native Voices")
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
                    .onChange(of: model.speechVoiceIdentifier) { _, _ in
                        model.speechSettingsChanged()
                    }
                    Text("Voices installed into iOS, including Piper voices exposed through Accessibility, should appear here after refresh.")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Speaking Rate")
                            Spacer()
                            Text(model.speechRateDescription)
                                .foregroundStyle(AppColors.secondaryText)
                        }
                        Slider(value: $model.speechRate, in: 0.35...0.85, step: 0.01)
                            .accessibilityLabel("Speaking rate")
                            .accessibilityValue(model.speechRateDescription)
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
                    Picker("Text Navigation", selection: $model.skipUnit) {
                        Text("Sentence").tag("sentence")
                        Text("Paragraph").tag("paragraph")
                        Text("Section").tag("section")
                    }
                    .accessibilityIdentifier("settings.skipUnit.picker")
                    .onChange(of: model.skipUnit) { _, _ in
                        model.settingsValueChanged()
                        model.saveProviderSettings()
                    }
                    Picker("Native Audio Back", selection: $model.mediaSkipBackSeconds) {
                        ForEach(Gate1AppModel.supportedMediaSkipSeconds, id: \.self) { seconds in
                            Text("\(seconds) seconds").tag(seconds)
                        }
                    }
                    .accessibilityIdentifier("settings.mediaSkipBack.picker")
                    .onChange(of: model.mediaSkipBackSeconds) { _, _ in
                        model.mediaSkipSettingsChanged()
                    }
                    Picker("Native Audio Forward", selection: $model.mediaSkipForwardSeconds) {
                        ForEach(Gate1AppModel.supportedMediaSkipSeconds, id: \.self) { seconds in
                            Text("\(seconds) seconds").tag(seconds)
                        }
                    }
                    .accessibilityIdentifier("settings.mediaSkipForward.picker")
                    .onChange(of: model.mediaSkipForwardSeconds) { _, _ in
                        model.mediaSkipSettingsChanged()
                    }
                }
                Section("Recently Deleted") {
                    if model.recentlyDeletedItems.isEmpty {
                        Text("Items moved here can be restored. Nothing is deleted automatically.")
                            .foregroundStyle(AppColors.secondaryText)
                    } else {
                        ForEach(model.recentlyDeletedItems) { item in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(item.title)
                                    .font(.headline)
                                HStack {
                                    Button("Restore") { model.restoreItem(id: item.id) }
                                    Button("Delete Permanently", role: .destructive) {
                                        pendingPermanentDeletion = item
                                    }
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
                                    Button("Delete", role: .destructive) {
                                        model.deleteImportInboxEntry(entry)
                                    }
                                }
                            }
                        }
                    }
                }
                Section("Support & Privacy") {
                    Link("Privacy Policy", destination: AppLinks.privacy)
                    Link("Support", destination: AppLinks.support)
                    Button("Copy Privacy-Safe Diagnostics", action: model.copyDiagnosticsExport)
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
                        .onChange(of: model.selectedProfileId) { _, _ in
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
            .alert("Reset the entire library?", isPresented: $isResetConfirmationPresented) {
                Button("Cancel", role: .cancel) {}
                Button("Reset Library", role: .destructive, action: model.resetAndSeed)
            } message: {
                Text("This permanently deletes every item and its related records, then loads the sample.")
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
                    ProductPanel {
                        VStack(alignment: .leading, spacing: 14) {
                            Picker("Format", selection: $model.exportFormat) {
                                Text("AI Handoff Markdown").tag("markdown")
                                Text("Full JSON Archive").tag("json")
                            }
                            .pickerStyle(.segmented)
                            .accessibilityIdentifier("export.format.picker")

                            Picker("Scope", selection: $model.exportScope) {
                                Text("Original").tag("original")
                                Text("Source Notes").tag("source_interjections")
                                Text("Full Session").tag("full_session")
                            }
                            .pickerStyle(.segmented)
                            .accessibilityIdentifier("export.scope.picker")

                            Toggle("Source Text", isOn: $model.exportIncludesSourceText)
                                .accessibilityIdentifier("export.includeSourceText.toggle")
                            Toggle("Reference", isOn: $model.exportIncludesReference)
                                .accessibilityIdentifier("export.includeReference.toggle")
                            Toggle("Listening Map", isOn: $model.exportIncludesListeningMap)
                                .accessibilityIdentifier("export.includeListeningMap.toggle")
                            Toggle("Interjections", isOn: $model.exportIncludesInterjections)
                                .accessibilityIdentifier("export.includeInterjections.toggle")
                            Toggle("AI Turns", isOn: $model.exportIncludesTurns)
                                .accessibilityIdentifier("export.includeTurns.toggle")
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Button {
                            model.buildExport()
                        } label: {
                            Label("Build Export", systemImage: "doc.text")
                        }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(!model.hasActiveSession)
                            .accessibilityIdentifier("export.build.button")
                        Button {
                            model.copyPlainTextExport()
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(model.exportPreview.isEmpty)
                            .accessibilityIdentifier("export.copyPlainText.button")
                        if !model.exportPreview.isEmpty {
                            ShareLink(item: model.exportPreview) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            .accessibilityIdentifier("export.share.button")
                        }
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
    @State private var pendingDeletion: PendingInterjectionDeletion?

    private enum PendingInterjectionDeletion: Equatable {
        case transcript
        case interjection
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Context") {
                    LabeledContent("Attached to", value: interjectionTargetLabel(interjection))
                    LabeledContent("Position", value: "Around \(interjection.roughPercent)%")
                    if interjection.transcriptionStatus != "complete" {
                        LabeledContent("Transcript status", value: humanizedTurnStatus(interjection.transcriptionStatus))
                    }
                }
                Section("Transcript") {
                    Text(interjection.cleanedTranscript ?? interjection.transcript ?? "No transcript yet.")
                        .textSelection(.enabled)
                    Button {
                        model.copyInterjectionWithContext(interjection)
                    } label: {
                        Label("Copy Transcript and Anchors", systemImage: "doc.on.doc")
                    }
                    .accessibilityIdentifier("interjection.detail.copy")
                    Button("Delete Transcript") {
                        pendingDeletion = .transcript
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
                        pendingDeletion = .interjection
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
                        model.deleteTranscript(interjection: interjection)
                        pendingDeletion = nil
                        dismiss()
                    }
                } else {
                    Button("Delete Interjection", role: .destructive) {
                        model.deleteInterjection(interjection)
                        pendingDeletion = nil
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
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

private enum AppColors {
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
            .background(AppColors.primaryAction.opacity(configuration.isPressed ? 0.78 : 1))
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
