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
    /// Live capture (#2481, prototype).
    @State private var showsLiveCapture = false
    @FocusState private var focusedField: Field?

    private enum Field { case link, title, text }
    private enum FileRequest { case documentOrBook, audiobook, quickFolder }

    init(initialRoute: AddSourceRoute) {
        _selectedRoute = State(initialValue: initialRoute)
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
            .navigationTitle(showsPinnedTextAction ? "Add Text" : "Add Source")
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
                if !showsPinnedTextAction {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { focusedField = nil }
                    }
                }
            }
            .fileImporter(
                isPresented: $showsFileImporter,
                allowedContentTypes: allowedContentTypes,
                allowsMultipleSelection: fileRequest == .documentOrBook,
                onCompletion: handleFileImport
            )
            .onChange(of: model.sourceLinkImportState) { _, state in
                if state == "success" { dismiss() }
            }
            .onAppear { model.resetSourceLinkImportState() }
        }
        .presentationDetents(showsRoutePicker && !dynamicTypeSize.isAccessibilitySize ? [.medium, .large] : [.large])
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
                    Button("Done") { focusedField = nil }
                        .frame(minWidth: 44, minHeight: 44)
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
                ForEach(primaryRoutes) { route in
                    Button {
                        if route == .documentOrBook {
                            presentFileImporter(.documentOrBook)
                            return
                        }
                        selectedRoute = route
                        showsRoutePicker = false
                    } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: route.systemImage)
                                .font(.title2)
                                .foregroundStyle(AppColors.evergreen)
                                .frame(width: 46, height: 46)
                                .background(AppColors.softGreen, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                                .accessibilityHidden(true)
                            Text(route.title)
                                .font(.headline)
                                .foregroundStyle(AppColors.text)
                                .multilineTextAlignment(.leading)
                            Text(shortDetail(route))
                                .font(.caption)
                                .foregroundStyle(AppColors.secondaryText)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(15)
                        .frame(maxWidth: .infinity, minHeight: 142, alignment: .topLeading)
                        .background(AppColors.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 18).stroke(AppColors.border) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("addSource.route.\(route.rawValue)")
                }
            }
            Divider()
            Button {
                selectedRoute = .quickFolder
                showsRoutePicker = false
            } label: {
                Label("Manage Quick Folder", systemImage: "folder")
                    .frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("addSource.route.quickFolder")
            Button {
                showsLiveCapture = true
            } label: {
                Label("Live capture from another app", systemImage: "waveform.badge.mic")
                    .frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("addSource.route.liveCapture")
            .fullScreenCover(isPresented: $showsLiveCapture, onDismiss: { dismiss() }) {
                LiveCaptureView().environmentObject(model)
            }
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

    private var primaryRoutes: [AddSourceRoute] {
        AddSourcePresentation.primaryObjectRoutes
    }

    private func shortDetail(_ route: AddSourceRoute) -> String {
        switch route {
        case .linkOrPodcast: "A web article, podcast episode, feed, or public audio link"
        case .pastedText: "Words already copied to your clipboard"
        case .documentOrBook: "Text, Markdown, PDF, DRM-free EPUB, or a Listening Edition"
        case .audiobook: "An MP3, M4A, M4B, or audio MP4 file"
        case .quickFolder: "A folder of eligible local files"
        }
    }

    @ViewBuilder
    private var routeContent: some View {
        switch selectedRoute {
        case .linkOrPodcast: linkSource
        case .pastedText: pastedTextSource
        case .documentOrBook: documentSource
        case .audiobook: audiobookSource
        case .quickFolder: quickFolderSource
        }
    }

    private var linkSource: some View {
        ExperienceSurface(tint: AppColors.evergreen) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Link or Podcast").font(.headline)
                TextField("Podcast, RSS, audio, or web URL", text: $model.sourceLinkURL)
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
                Text("Adding a source never replaces the item already in Now Playing.")
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
            }
        }
    }

    private var pastedTextSource: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                TextField("Title (optional)", text: $model.importTitle)
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

    private var documentSource: some View {
        ExperienceSurface {
            VStack(alignment: .leading, spacing: 12) {
                Button("Choose Document or Book", systemImage: "doc.badge.plus") {
                    presentFileImporter(.documentOrBook)
                }
                .filledActionButton()
                .frame(minHeight: 44)
                .accessibilityIdentifier("document.import.button")
                Text("Documents and books stay local and retain authored structure when the format provides it. A Listening Edition collection (.json) can be chosen here too.")
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
                if let fileImportError {
                    FailureMessageLabel(fileImportError)
                        .accessibilityIdentifier("document.import.error")
                }
            }
        }
    }

    private var audiobookSource: some View {
        ExperienceSurface {
            VStack(alignment: .leading, spacing: 12) {
                Button("Choose Audiobook", systemImage: "headphones") {
                    presentFileImporter(.audiobook)
                }
                .filledActionButton()
                .frame(minHeight: 44)
                .accessibilityIdentifier("audiobook.import.button")
                Text("Audiobooks are copied into app-owned storage and protected from automatic eviction.")
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
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
            Button("Cancel", role: .cancel, action: model.cancelSourceLinkCandidateReview)
                .frame(minHeight: 44)
        }
    }

    private var allowedContentTypes: [UTType] {
        switch fileRequest {
        case .documentOrBook, .none:
            [UTType(filenameExtension: "md") ?? .plainText, .plainText, .pdf, UTType(filenameExtension: "epub") ?? .data, .json]
        case .audiobook:
            [.mp3, .mpeg4Audio, .mpeg4Movie, UTType(filenameExtension: "m4b") ?? .audio]
        case .quickFolder:
            [.folder]
        }
    }

    private func presentFileImporter(_ request: FileRequest) {
        focusedField = nil
        fileImportError = nil
        fileRequest = request
        showsFileImporter = true
    }

    /// A Listening Edition collection (`.json`) goes to the edition import, like a PDF added from here: it lands in
    /// the Library and nothing opens (#2373). Everything else goes the way it always did. The sheet closes unless
    /// something could not be imported, and then it says what, under the Files button.
    private func importDocumentsAndCollections(_ picked: [URL]) {
        let editionURLs = picked.filter { $0.pathExtension.lowercased() == "json" }
        let urls = picked.filter { $0.pathExtension.lowercased() != "json" }
        fileImportError = nil
        var closes = !picked.isEmpty
        if !editionURLs.isEmpty, !model.importListeningEditionFiles(editionURLs) {
            fileImportError = model.lastError
            closes = false
        }
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
            case .documentOrBook:
                importDocumentsAndCollections(urls)
            case .audiobook:
                if let url = urls.first { model.importAudiobookFile(url: url, openWhenFinished: false); dismiss() }
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
