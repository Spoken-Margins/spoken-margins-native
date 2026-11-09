import SwiftUI
import SessionKit
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

struct ExperienceAddSourceFlow: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedRoute: AddSourceRoute
    @State private var showsRoutePicker = true
    @State private var fileRequest: FileRequest?
    @State private var showsFileImporter = false
    @State private var textImportError: String?
    /// What the last Files pick could not import, shown under the Files button (#2373).
    @State private var fileImportError: String?
    /// Live session (#1989, #2481, prototype).
    @State private var showsLiveSession = false
    @State private var showsSpokenNote = false
    @FocusState private var focusedField: Field?

    private enum Field { case link, title, text }
    private enum FileRequest { case files, quickFolder }

    /// Closes the sheet and opens the podcast catalog's search by name; nil hides the button (#1784).
    private let onSearchPodcasts: (() -> Void)?

    init(initialRoute: AddSourceRoute, onSearchPodcasts: (() -> Void)? = nil) {
        _selectedRoute = State(initialValue: initialRoute)
        self.onSearchPodcasts = onSearchPodcasts
    }

    var body: some View {
        NavigationStack {
            Group {
                if showsPinnedTextAction {
                    ScrollView {
                        pastedTextSource
                            .padding(20)
                            .frame(maxWidth: 720)
                            .frame(maxWidth: .infinity)
                    }
                } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let review = model.sourceLinkCandidateReview {
                        candidateReview(review)
                    } else if showsRoutePicker {
                        routePicker
                    } else {
                        selectedRouteHeader
                        routeContent
                    }
                }
                .padding(20)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
                }
            }
            .contentMargins(
                .bottom,
                showsPinnedTextAction ? 16 : Build23ExperiencePolishLayout.addSourceBottomClearance,
                for: .scrollContent
            )
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if showsPinnedTextAction {
                    pastedTextActions
                } else if showsPasteAndGo {
                    PasteAndGoBar { dismiss() }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AppColors.bone)
            .navigationTitle(showsPinnedTextAction ? "Add Text" : "Add to Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsPinnedTextAction {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            focusedField = nil
                            showsRoutePicker = true
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .accessibilityLabel("Choose a different source type")
                        .accessibilityIdentifier("addSource.route.back")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
                // Not while the Live Session or Spoken Note cover is up: this Done clears only this sheet's own
                // fields, and it showed over the cover's keyboard doing nothing (#3547).
                if !showsPinnedTextAction && !showsLiveSession && !showsSpokenNote {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { focusedField = nil }
                    }
                }
            }
            .fileImporter(
                isPresented: $showsFileImporter,
                allowedContentTypes: allowedContentTypes,
                allowsMultipleSelection: fileRequest == .files,
                onCompletion: handleFileImport
            )
            .onChange(of: model.sourceLinkImportState) { _, state in
                if state == "success" { dismiss() }
            }
            .onAppear { model.resetSourceLinkImportState() }
        }
        // Every way in fits at the large detent without scrolling (#3217); a half-height sheet would hide some of them.
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("addSource.sheet")
    }

    private var pastedTextActions: some View {
        // Keep both controls in one inset: a separate floating keyboard toolbar
        // can overlap the primary action at accessibility sizes on iOS 27.
        VStack(spacing: 8) {
            Button {
                model.importTextItem(startListening: false)
                textImportError = model.lastError
                if textImportError == nil { dismiss() }
            } label: {
                Label(dynamicTypeSize.isAccessibilitySize ? "Add" : "Add to Library", systemImage: "plus")
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Add to Library")
            .accessibilityIdentifier("create.start.button")
            if focusedField != nil {
                HStack {
                    Spacer()
                    Button { focusedField = nil } label: { Text("Done").minimumTapTarget() }
                }
                .tint(AppColors.evergreen)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .background(AppColors.bone)
    }

    private var showsPinnedTextAction: Bool {
        !showsRoutePicker && selectedRoute == .pastedText && model.sourceLinkCandidateReview == nil
    }

    /// Paste & go sits in the bottom inset of the route picker, in thumb reach at the medium detent (#145).
    private var showsPasteAndGo: Bool {
        showsRoutePicker && model.sourceLinkCandidateReview == nil
    }

    private var routePicker: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add to Library")
                .font(.title2.weight(.bold))
                .screenTitle()
                .foregroundStyle(AppColors.text)
            // One column at accessibility sizes: two columns broke headline titles mid-word (#1934).
            LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(AddSourcePresentation.tiles(canSearchPodcasts: onSearchPodcasts != nil).filter { $0 != .spokenNote }) { tile in
                    Button { choose(tile) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: tile.systemImage)
                                .font(.title3)
                                .foregroundStyle(AppColors.evergreen)
                                .frame(width: 40, height: 40)
                                .background(AppColors.softGreen, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .accessibilityHidden(true)
                            Text(tile.title)
                                .font(.headline)
                                .foregroundStyle(AppColors.text)
                                .multilineTextAlignment(.leading)
                            Text(tile.detail)
                                .font(.caption)
                                .foregroundStyle(AppColors.secondaryText)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
                        .background(AppColors.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 18).stroke(AppColors.border) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("addSource.route.\(tile.rawValue)")
                }
            }
            // Spoken Note sits in a slim row of its own under the grid, so the six tiles above keep their rows and
            // every way in still fits on screen (#3217, #3108).
            Button { choose(.spokenNote) } label: {
                HStack(spacing: 12) {
                    Image(systemName: AddSourceTile.spokenNote.systemImage)
                        .font(.title3)
                        .foregroundStyle(AppColors.evergreen)
                        .frame(width: 40, height: 40)
                        .background(AppColors.softGreen, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AddSourceTile.spokenNote.title)
                            .font(.headline)
                            .foregroundStyle(AppColors.text)
                        Text(AddSourceTile.spokenNote.detail)
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColors.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 18).stroke(AppColors.border) }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("addSource.route.\(AddSourceTile.spokenNote.rawValue)")
            if let fileImportError {
                FailureMessageLabel(fileImportError)
                    .accessibilityIdentifier("document.import.error")
            }
        }
        .fullScreenCover(isPresented: $showsLiveSession, onDismiss: { dismiss() }) {
            LiveSessionView().environmentObject(model)
        }
        .fullScreenCover(isPresented: $showsSpokenNote, onDismiss: { dismiss() }) {
            SpokenNoteRecordingView().environmentObject(model)
        }
    }

    /// A tile either swaps the sheet to its page, opens the Files picker, closes the sheet to search the catalog,
    /// or starts a Live Session.
    private func choose(_ tile: AddSourceTile) {
        switch tile {
        case .importFromFiles:
            presentFileImporter(.files)
        case .findPodcast:
            focusedField = nil
            onSearchPodcasts?()
        case .liveSession:
            showsLiveSession = true
        case .spokenNote:
            showsSpokenNote = true
        case .linkOrPodcast, .pastedText, .quickFolder:
            guard let route = tile.route else { return }
            selectedRoute = route
            showsRoutePicker = false
        }
    }

    private var selectedRouteHeader: some View {
        HStack(spacing: 12) {
            Button {
                focusedField = nil
                showsRoutePicker = true
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Choose a different source type")
            .accessibilityIdentifier("addSource.route.back")
            Image(systemName: selectedRoute.systemImage)
                .foregroundStyle(AppColors.evergreen)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedRoute.title).font(.headline)
            }
        }
    }

    @ViewBuilder
    private var routeContent: some View {
        switch selectedRoute {
        case .linkOrPodcast: linkSource
        case .pastedText: pastedTextSource
        case .importFromFiles: filesSource
        case .quickFolder: quickFolderSource
        }
    }

    private var linkSource: some View {
        ExperienceSurface(tint: AppColors.evergreen) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Link or Podcast").font(.headline)
                AppTextField("Podcast, RSS, audio, or web URL", text: $model.sourceLinkURL)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .focused($focusedField, equals: .link)
                    .accessibilityIdentifier("sourceLink.url.field")
                HStack {
                    Button {
                        model.pasteSourceLinkFromClipboard()
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Button {
                        focusedField = nil
                        _ = model.beginSourceLinkImportFromForm(startSession: false)
                    } label: {
                        if model.isResolvingSourceLink {
                            ProgressView()
                        } else {
                            Label("Add to Library", systemImage: "plus")
                        }
                    }
                    .filledActionButton()
                    .disabled(model.sourceLinkURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isResolvingSourceLink)
                    .accessibilityIdentifier("sourceLink.import.button")
                }
                SourceLinkImportStatusView()
                Text("Adding a source never replaces what is already in Now Playing.")
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
            }
        }
    }

    private var pastedTextSource: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AppTextField("Title (optional)", text: $model.importTitle)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .title)
                    .accessibilityIdentifier("create.title.field")
            }
            Button {
                model.pasteImportTextFromClipboard()
                textImportError = model.lastError
                guard textImportError == nil else { return }
                model.importTextItem(startListening: false)
                textImportError = model.lastError
                if textImportError == nil { dismiss() }
            } label: {
                Label("Paste & Add", systemImage: "doc.on.clipboard")
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("create.pasteAndAdd.button")
            Text("Text")
                .font(.headline)
            Text("Paste or type your text below. You can edit it before adding.")
                .font(.caption)
                .foregroundStyle(AppColors.secondaryText)
            TextEditor(text: $model.importText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(height: dynamicTypeSize.isAccessibilitySize ? 220 : 180)
                .focused($focusedField, equals: .text)
                .padding(8)
                .background(AppColors.panel, in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).stroke(AppColors.border) }
                .accessibilityLabel("Source text")
                .accessibilityIdentifier("create.text.editor")
            if let textImportError {
                FailureMessageLabel(textImportError)
                    .font(.subheadline)
            }
        }
        .tint(AppColors.evergreen)
    }

    private var filesSource: some View {
        ExperienceSurface {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    presentFileImporter(.files)
                } label: {
                    Label("Choose Files", systemImage: "folder.badge.plus").frame(minHeight: 44).contentShape(Rectangle())
                }
                .filledActionButton()
                .accessibilityIdentifier("files.import.button")
                Text("Documents and books stay local and retain authored structure when the format provides it. Audiobooks are copied into app-owned storage and protected from automatic eviction. A Listening Edition collection (.json) or a Margins packet (.spokenmargins) can be chosen here too.")
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
                if let fileImportError {
                    FailureMessageLabel(fileImportError)
                        .accessibilityIdentifier("document.import.error")
                }
            }
        }
    }

    private var quickFolderSource: some View {
        ExperienceSurface {
            VStack(alignment: .leading, spacing: 12) {
                Text("Quick Folder").font(.headline)
                Text(model.quickAccessFolderName)
                    .foregroundStyle(AppColors.secondaryText)
                Button("Choose Folder", systemImage: "folder.badge.plus") {
                    presentFileImporter(.quickFolder)
                }
                .filledActionButton()
                .accessibilityIdentifier("quickFolder.choose.button")
                if !model.quickAccessRecentFiles.isEmpty {
                    Divider()
                    ForEach(model.quickAccessRecentFiles) { file in
                        Button {
                            model.importQuickAccessFile(file)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "doc.text")
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading) {
                                    Text(file.name).font(.headline)
                                    Text(file.modifiedAtDescription)
                                        .font(.caption)
                                        .foregroundStyle(AppColors.secondaryText)
                                }
                                Spacer()
                                Image(systemName: "plus")
                                    .accessibilityHidden(true)
                            }
                            .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func candidateReview(_ review: SourceLinkCandidateReviewState) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose the matching episode")
                .font(.title2.weight(.bold))
                .screenTitle()
                .foregroundStyle(AppColors.text)
                .accessibilityIdentifier("sourceLink.candidateReview.sheet")
            Text("More than one public episode matches this link.")
                .font(.subheadline)
                .foregroundStyle(AppColors.secondaryText)
            ForEach(Array(review.result.candidates.enumerated()), id: \.offset) { index, candidate in
                Button {
                    model.selectSourceLinkCandidate(candidate)
                } label: {
                    ExperienceSurface {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(candidate.title).font(.headline)
                            if let show = candidate.showTitle { Text(show).foregroundStyle(AppColors.secondaryText) }
                            Text("\(Int((candidate.confidence * 100).rounded()))% match")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(AppColors.secondaryText)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sourceLink.candidate.\(index)")
            }
            Button(role: .cancel, action: model.cancelSourceLinkCandidateReview) { Text("Cancel").minimumTapTarget() }
        }
    }

    /// One picker for everything the Files tile takes; `AddFromFilesPlan` routes each pick by its file type.
    private var allowedContentTypes: [UTType] {
        switch fileRequest {
        case .files, .none:
            Self.filesContentTypes
        case .quickFolder:
            [.folder]
        }
    }

    private static let filesContentTypes: [UTType] = [
        // Documents and books, and Listening Edition collections (`.json`) and folders of them.
        UTType(filenameExtension: "md") ?? .plainText, .plainText, .pdf, UTType(filenameExtension: "epub") ?? .data, .json, .folder,
        // Audiobooks.
        .mp3, .mpeg4Audio, .mpeg4Movie, UTType(filenameExtension: "m4b") ?? .audio,
        // A Margins packet. The app exports this type; the fallback keeps the picker usable if it ever failed to register.
        UTType("com.spokenmargins.package") ?? UTType(filenameExtension: AddFromFilesPlan.packetExtension) ?? .data,
    ]

    private func presentFileImporter(_ request: FileRequest) {
        focusedField = nil
        fileImportError = nil
        fileRequest = request
        showsFileImporter = true
    }

    /// Sends each picked file the way its type goes (#3217): a packet to the review, an audio file to the audiobook
    /// import, a collection, folder or document to the document import, which is what the old tiles did. A mixed pick
    /// runs every part. The sheet closes unless the document import could not take something, and then it says what.
    private func routeFilePick(_ picked: [URL]) {
        let plan = AddFromFilesPlan(picking: picked) { url in
            url.hasDirectoryPath || ((try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true)
        }
        guard !plan.isEmpty else { return }
        // An EPUB goes in alone. Say so before anything else starts, so a re-pick does not meet the audio or packet
        // that already began importing.
        if plan.documents.count > 1, plan.documents.contains(where: { $0.pathExtension.lowercased() == "epub" }) {
            model.reportImportFailure(ExperienceFileImportError.epubMustBeImportedAlone)
            return
        }
        fileImportError = nil
        for packet in plan.packets { model.stageSpokenMarginsPackageImportInBackground(from: packet) }
        for audio in plan.audio { model.importAudiobookFile(url: audio, openWhenFinished: false) }
        if plan.documentsAndCollections.isEmpty {
            dismiss()
        } else {
            importDocumentsAndCollections(plan.documentsAndCollections)
        }
    }

    /// A Listening Edition collection (`.json`) goes to the edition import, like a PDF added from here: it lands in
    /// the Library and nothing opens (#2373). Everything else goes the way it always did. The sheet closes unless
    /// something could not be imported, and then it says what, under the Files button.
    private func importDocumentsAndCollections(_ picked: [URL]) {
        // A picked folder (#2672) goes to the edition import too, which walks it for `.json` collection files.
        let folders = picked.filter { $0.hasDirectoryPath || ((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true) }
        let files = picked.filter { url in !folders.contains(url) }
        let editionURLs = files.filter { $0.pathExtension.lowercased() == "json" }
        let urls = files.filter { $0.pathExtension.lowercased() != "json" }
        fileImportError = nil
        guard !editionURLs.isEmpty || !folders.isEmpty else { importDocuments(urls, closes: !picked.isEmpty); return }
        // The edition files are read off the main thread (#2510), so the rest waits for them.
        Task { @MainActor in
            // A `.json` file that says it is a structured link list (#3767) adds its links; any other `.json` file
            // goes to the edition import as before. Only the file's own `schemaVersion` decides, never its name.
            let picks = await model.splitLinkLists(from: editionURLs)
            var linkResult: (allImported: Bool, message: String?) = (true, nil)
            if !picks.isEmpty { linkResult = await model.importLinkLists(picks) }
            var editionsImported = true
            if !picks.others.isEmpty || !folders.isEmpty {
                editionsImported = await model.importListeningEditionFiles(picks.others, folders: folders)
            }
            let allImported = linkResult.allImported && editionsImported
            if !allImported { fileImportError = editionsImported ? linkResult.message : (model.lastError ?? linkResult.message) }
            model.hangTelemetry.labels.scoped("addSheet.documentImport") { importDocuments(urls, closes: allImported) }
        }
    }

    private func importDocuments(_ urls: [URL], closes: Bool) {
        var closes = closes
        let epubURLs = urls.filter { $0.pathExtension.lowercased() == "epub" }
        if epubURLs.isEmpty, !urls.isEmpty {
            model.importObsidianMarkdownFiles(urls: urls)
        } else if urls.count == 1, let epubURL = epubURLs.first {
            model.importEPUBFile(url: epubURL, openWhenFinished: false)
        } else if !urls.isEmpty {
            model.reportImportFailure(ExperienceFileImportError.epubMustBeImportedAlone)
            closes = false
        }
        if closes { dismiss() }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        let request = fileRequest
        fileRequest = nil
        switch result {
        case .success(let urls):
            switch request {
            case .files:
                routeFilePick(urls)
            case .quickFolder:
                if let url = urls.first { model.configureQuickAccessFolder(url: url) }
            case .none:
                model.reportImportFailure(ExperienceFileImportError.missingRequest)
            }
        case .failure(let error):
            model.reportImportFailure(error)
        }
    }
}

private enum ExperienceFileImportError: LocalizedError {
    case missingRequest
    case epubMustBeImportedAlone

    var errorDescription: String? {
        switch self {
        case .missingRequest:
            "File import completed without an active request."
        case .epubMustBeImportedAlone:
            "Choose one EPUB at a time, or select PDFs and text documents together."
        }
    }
}
