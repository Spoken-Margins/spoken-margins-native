import SwiftUI
import SessionKit
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

struct ExperienceAddSourceFlow: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedRoute: AddSourceRoute
    @State private var showsRoutePicker = true
    @State private var fileRequest: FileRequest?
    @State private var showsFileImporter = false
    @FocusState private var focusedField: Field?

    private enum Field { case link, title, text }
    private enum FileRequest { case textOrPDF, epub, audiobook, quickFolder }

    init(initialRoute: AddSourceRoute) {
        _selectedRoute = State(initialValue: initialRoute)
    }

    var body: some View {
        NavigationStack {
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
            .background(AppColors.bone)
            .navigationTitle("Add Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
            .fileImporter(
                isPresented: $showsFileImporter,
                allowedContentTypes: allowedContentTypes,
                allowsMultipleSelection: fileRequest == .textOrPDF,
                onCompletion: handleFileImport
            )
            .onChange(of: model.sourceLinkImportState) { _, state in
                if state == "success" { dismiss() }
            }
            .onAppear { model.resetSourceLinkImportState() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("addSource.sheet")
    }

    private var routePicker: some View {
        VStack(alignment: .leading, spacing: 18) {
            ExperienceEditorialHeader(
                eyebrow: "BRING SOMETHING WORTH HEARING",
                title: "What do you have?",
                detail: "Choose the object in front of you. You’ll see only the controls it needs."
            )
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(primaryRoutes) { route in
                Button {
                    selectedRoute = route
                    showsRoutePicker = false
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: route.systemImage)
                            .font(.title2)
                            .foregroundStyle(AppColors.evergreen)
                            .frame(width: 46, height: 46)
                            .background(AppColors.softGreen, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        Text(route.title)
                            .font(.headline)
                            .foregroundStyle(AppColors.text)
                            .multilineTextAlignment(.leading)
                        Text(shortDetail(route))
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                            .multilineTextAlignment(.leading)
                            .lineLimit(3)
                    }
                    .padding(15)
                    .frame(maxWidth: .infinity, minHeight: 156, alignment: .topLeading)
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
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedRoute.title).font(.title2.bold())
                Text(selectedRoute.detail)
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
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
        case .documentOrBook: "Text, Markdown, PDF, or DRM-free EPUB"
        case .audiobook: "An MP3, M4A, M4B, or audio MP4 file"
        case .quickFolder: "A folder of eligible local files"
        }
    }

    @ViewBuilder
    private var routeContent: some View {
        Divider().padding(.vertical, 4)
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
                    .buttonStyle(.borderedProminent)
                    .tint(AppColors.evergreen)
                    .disabled(model.sourceLinkURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isResolvingSourceLink)
                    .accessibilityIdentifier("sourceLink.import.button")
                }
                if let message = model.sourceLinkImportMessage {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(model.sourceLinkImportState == "failure" ? AppColors.coral : AppColors.secondaryText)
                        .accessibilityIdentifier("sourceLink.import.status")
                }
                Text("Adding a source never replaces the item already in Now Playing.")
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
            }
        }
    }

    private var pastedTextSource: some View {
        ExperienceSurface(tint: AppColors.ochre) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Title (optional)", text: $model.importTitle)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .title)
                    .accessibilityIdentifier("create.title.field")
                TextEditor(text: $model.importText)
                    .frame(minHeight: 150)
                    .padding(8)
                    .background(AppColors.inputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppColors.border))
                    .focused($focusedField, equals: .text)
                    .accessibilityLabel("Source text")
                    .accessibilityIdentifier("create.text.editor")
                HStack {
                    Button("Paste", systemImage: "doc.on.clipboard", action: model.pasteImportTextFromClipboard)
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Add to Library", systemImage: "plus") {
                        model.importTextItem(startListening: false)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppColors.evergreen)
                    .disabled(model.importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("create.start.button")
                }
            }
        }
    }

    private var documentSource: some View {
        ExperienceSurface {
            VStack(alignment: .leading, spacing: 12) {
                Text("Documents and books stay local and retain authored structure when the format provides it.")
                    .foregroundStyle(AppColors.secondaryText)
                Button("Choose Text, Markdown, or PDF", systemImage: "doc.badge.plus") {
                    presentFileImporter(.textOrPDF)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.evergreen)
                .frame(minHeight: 44)
                .accessibilityIdentifier("obsidian.import.button")
                Button("Choose DRM-free EPUB", systemImage: "book.closed") {
                    presentFileImporter(.epub)
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .accessibilityIdentifier("epub.import.button")
            }
        }
    }

    private var audiobookSource: some View {
        ExperienceSurface {
            VStack(alignment: .leading, spacing: 12) {
                Text("Audiobooks are copied into app-owned storage and protected from automatic eviction.")
                    .foregroundStyle(AppColors.secondaryText)
                Button("Choose Audiobook", systemImage: "headphones") {
                    presentFileImporter(.audiobook)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.evergreen)
                .frame(minHeight: 44)
                .accessibilityIdentifier("audiobook.import.button")
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
                .buttonStyle(.borderedProminent)
                .tint(AppColors.evergreen)
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
                                VStack(alignment: .leading) {
                                    Text(file.name).font(.headline)
                                    Text(file.modifiedAtDescription)
                                        .font(.caption)
                                        .foregroundStyle(AppColors.secondaryText)
                                }
                                Spacer()
                                Image(systemName: "plus")
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
            ExperienceEditorialHeader(
                eyebrow: "MATCH NEEDS REVIEW",
                title: "Choose the episode",
                detail: "Spoken Margins will not guess when more than one public episode is plausible."
            )
            .accessibilityIdentifier("sourceLink.candidateReview.sheet")
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
        case .textOrPDF, .none:
            [UTType(filenameExtension: "md") ?? .plainText, .plainText, .pdf]
        case .epub:
            [UTType(filenameExtension: "epub") ?? .data]
        case .audiobook:
            [.mp3, .mpeg4Audio, .mpeg4Movie, UTType(filenameExtension: "m4b") ?? .audio]
        case .quickFolder:
            [.folder]
        }
    }

    private func presentFileImporter(_ request: FileRequest) {
        focusedField = nil
        fileRequest = request
        showsFileImporter = true
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        let request = fileRequest
        fileRequest = nil
        switch result {
        case .success(let urls):
            switch request {
            case .textOrPDF:
                model.importObsidianMarkdownFiles(urls: urls)
                dismiss()
            case .epub:
                if let url = urls.first { model.importEPUBFile(url: url, openWhenFinished: false); dismiss() }
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
    var errorDescription: String? { "File import completed without an active request." }
}
