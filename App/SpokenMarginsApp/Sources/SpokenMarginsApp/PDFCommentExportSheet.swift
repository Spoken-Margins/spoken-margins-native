import SwiftUI
import SessionKit
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

/// "PDF with your Margins" (#4338, PR 5), and "Word document with your Margins" (#4595): the listener's own Margins in
/// page order (text order for Word), each with where its comment will land, and one button that makes a copy of the kept
/// file with them as comments and offers it to the share sheet. The original is never changed. What the sheet shows is `PDFCommentExportState`; this is only the drawing.
struct PDFCommentExportSheet: View {
    @StateObject private var export: PDFCommentExportModel
    @Environment(\.dismiss) private var dismiss
    /// The Files picker for "Choose the PDF" (#4338, PR 6).
    @State private var choosesFile = false
    /// The Margin whose "Tidy version to review" was tapped (#4339).
    @State private var reviewing: PDFCommentTidyReview?
    /// Called with the number of comments once the share sheet reports the file was sent.
    let onExported: (Int) -> Void

    init(export: PDFCommentExportModel, onExported: @escaping (Int) -> Void) {
        _export = StateObject(wrappedValue: export)
        self.onExported = onExported
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(export.document.sheetTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { dismiss() }
                            .disabled(export.state.phase == .exporting && export.shareFile == nil)
                            .accessibilityIdentifier("pdfExport.cancel.button")
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { exportButton }
                .miniPlayerKeepOut()
        }
        .task { await export.load() }
        .trackedSheet(item: $export.shareFile, onDismiss: {
            // Every way the share sheet can close ends here, after it is gone.
            if let count = export.shareSheetClosed() {
                onExported(count)
                dismiss()
            }
        }) { file in
            #if canImport(UIKit)
            PDFCommentShareView(file: file.url) { completed in export.shareSheetReported(completed: completed) }
            #else
            EmptyView()
            #endif
        }
        .fileImporter(isPresented: $choosesFile, allowedContentTypes: [.pdf]) { result in
            // A cancelled picker reports nothing to do; a failure to hand over the file leaves the card as it was.
            if case .success(let url) = result { export.chooseFile(at: url) }
        }
        .interactiveDismissDisabled(export.state.phase == .exporting && export.shareFile == nil)
        .accessibilityIdentifier("pdfExport.sheet")
    }

    @ViewBuilder
    private var content: some View {
        switch export.state.phase {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Finding where each Margin goes…")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("pdfExport.loading")
        case .locked:
            refusal(PDFCommentExportState.lockedMessage, identifier: "pdfExport.locked")
        case .unreadable:
            refusal(PDFCommentExportState.unreadableMessage(document: export.document), identifier: "pdfExport.unreadable")
        case .ready, .exporting, .writeFailed, .originalMissing, .wrongFile:
            list
        }
    }

    private func refusal(_ message: String, identifier: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.doc").font(.largeTitle).foregroundStyle(AppColors.secondaryText).accessibilityHidden(true)
            Text(message).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private var list: some View {
        List {
            Section {
                Text(PDFCommentExportState.leadLine(title: export.itemTitle, document: export.document))
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
                    .listRowBackground(Color.clear)
                if let message = export.state.fileCardMessage, let title = export.state.chooseFileTitle {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(message, systemImage: "doc.badge.plus")
                        Button(title) { choosesFile = true }
                            .filledActionButton()
                            .accessibilityIdentifier("pdfExport.chooseFile.button")
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(export.state.phase == .originalMissing ? "pdfExport.originalMissing" : "pdfExport.wrongFile")
                }
                if export.state.phase == .writeFailed {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(PDFCommentExportState.writeFailedMessage(document: export.document), systemImage: "exclamationmark.triangle")
                        Button("Try again") { export.dismissFailure() }
                            .accessibilityIdentifier("pdfExport.tryAgain.button")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("pdfExport.writeFailed")
                }
            }
            Section {
                AppTextField("Your name", text: Binding(get: { export.authorName }, set: { export.authorName = $0 }))
                    .textInputAutocapitalization(.words)
                    .disabled(!export.state.isEditable)
                    .accessibilityLabel("Name on comments")
                    .accessibilityIdentifier("pdfExport.author.field")
            } header: {
                Text("Name on comments")
            }
            Section {
                ForEach(export.state.rows) { row in
                    rowView(row)
                }
            } header: {
                Text("Margins")
            } footer: {
                Text(PDFCommentExportState.footnote)
            }
        }
        .disabled(export.state.phase == .exporting)
        .accessibilityIdentifier("pdfExport.list")
        .trackedSheet(item: $reviewing, onDismiss: {
            // However the review closed, read the Margins' words again: an approved tidy version is what the comment says.
            Task { await export.reloadWords() }
        }) { review in
            PDFCommentTidyReviewSheet(margin: review.margin)
        }
    }

    /// "Tidy version to review": opens the Tidy version card for that Margin. The rest of the row still includes or
    /// leaves out the comment.
    private func tidyReviewButton(_ row: PDFCommentExportState.Row) -> some View {
        Button {
            if let margin = export.margin(id: row.id) { reviewing = PDFCommentTidyReview(margin: margin) }
        } label: {
            Label(PDFCommentExportState.tidyToReviewWords, systemImage: PDFCommentExportState.tidyToReviewSystemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppColors.accent)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!export.state.canReviewTidy)
        .accessibilityHint("Shows the tidy version to use or keep your own words")
        .accessibilityIdentifier("pdfExport.row.\(row.id).tidy")
    }

    private func rowView(_ row: PDFCommentExportState.Row) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            includeButton(row)
            if row.tidyToReview { tidyReviewButton(row) }
        }
    }

    private func includeButton(_ row: PDFCommentExportState.Row) -> some View {
        Button {
            export.toggle(row.id)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let page = row.pageLabel {
                            Text(page).font(.footnote.monospacedDigit()).foregroundStyle(AppColors.secondaryText)
                        }
                        Text(row.text).lineLimit(2).multilineTextAlignment(.leading)
                    }
                    Label(row.status.words, systemImage: row.status.systemImage)
                        .font(.footnote)
                        .foregroundStyle(AppColors.secondaryText)
                }
                Spacer(minLength: 8)
                if row.status.canBeIncluded {
                    Image(systemName: row.isIncluded ? "checkmark.circle.fill" : "circle")
                        .imageScale(.large)
                        .foregroundStyle(row.isIncluded ? AppColors.accent : AppColors.secondaryText)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!row.status.canBeIncluded || !export.state.isEditable)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.pageLabel.map { "\($0). " } ?? "")\(row.text). \(row.status.words)")
        .accessibilityValue(row.status.canBeIncluded ? (row.isIncluded ? "Included" : "Not included") : "")
        .accessibilityHint(row.status.canBeIncluded ? (row.isIncluded ? "Double-tap to leave out" : "Double-tap to include") : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("pdfExport.row.\(row.id)")
    }

    @ViewBuilder
    private var exportButton: some View {
        switch export.state.phase {
        case .ready, .exporting, .writeFailed, .originalMissing, .wrongFile:
            Button {
                export.export()
            } label: {
                HStack(spacing: 8) {
                    if export.state.phase == .exporting { ProgressView() }
                    Text(export.state.buttonTitle).fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .filledActionButton()
            .disabled(!export.state.canExport)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(AppColors.bone)
            .accessibilityIdentifier("pdfExport.export.button")
        case .loading, .locked, .unreadable:
            EmptyView()
        }
    }
}

/// The Margin a "Tidy version to review" row opens (#4339).
struct PDFCommentTidyReview: Identifiable {
    let margin: Interjection
    var id: String { margin.id }
}

/// The Tidy version card for one Margin, opened from the export sheet's "Tidy version to review" (#4338's Design,
/// #4339). It is the details screen's card, with the author's words above it; an answer closes it, and the export sheet
/// then reads the words again. Only this Margin may go to the on-device model; the list itself never asks it.
struct PDFCommentTidyReviewSheet: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var tidy = MarginTidyCardModel()
    let margin: Interjection

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(margin.transcript ?? "")
                        .font(.system(.body, design: .serif))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("pdfExport.tidy.words")
                } header: {
                    Text("Your words")
                }
                Section {
                    if tidy.showsCard(for: margin) {
                        MarginTidyCard(margin: margin, card: tidy) { dismiss() }
                    } else {
                        Text("Nothing to tidy in this Margin.")
                            .foregroundStyle(AppColors.secondaryText)
                    }
                } footer: {
                    Text("Until you use the tidy version, the comment carries your own words.")
                }
            }
            .navigationTitle("Tidy version")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("pdfExport.tidy.done.button")
                }
            }
            .task(id: MarginTidyCardModel.key(for: margin)) {
                await tidy.refresh(for: margin, using: model)
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("pdfExport.tidy.sheet")
    }
}

#if canImport(UIKit)
/// The system share sheet for the finished copy. `onClosed` says whether the listener sent the file somewhere; the sheet
/// then closes itself, and the presenting sheet's `onDismiss` does the rest.
private struct PDFCommentShareView: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let file: URL
    let onClosed: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            onClosed(completed)
            dismiss()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
