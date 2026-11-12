import SwiftUI
import SessionKit
import SessionKitSharing
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

struct ExportScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @State private var isSharePresented = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Export")
                        .font(.largeTitle.bold())
                        .screenTitle()
                    Text(model.selectedItem.title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Take a session out for yourself or your tools, as Markdown or JSON. To send Margins to a friend, use Share.")
                        .foregroundStyle(AppColors.secondaryText)
                    Text("Export a session")
                        .font(.headline)
                    ProductPanel {
                        VStack(alignment: .leading, spacing: 14) {
                            Picker(
                                "Listening Session",
                                selection: Binding(
                                    get: { model.exportSessionId ?? "" },
                                    set: {
                                        model.exportSessionId = $0.isEmpty ? nil : $0
                                        model.exportOptionsChanged()
                                    }
                                )
                            ) {
                                ForEach(model.selectedItem.sessionRows) { row in
                                    Text("\(sessionDateDescription(row.session)) · \(sessionProgressDescription(row.session)) · \(row.interjectionCount) Margin\(row.interjectionCount == 1 ? "" : "s")")
                                        .tag(row.id)
                                }
                            }
                            .accessibilityIdentifier("export.session.picker")

                            Picker("Format", selection: $model.exportFormat) {
                                Text("AI Handoff Markdown").tag("markdown")
                                Text("Full JSON Archive").tag("json")
                            }
                            .segmentedUnlessLargeText()
                            .accessibilityIdentifier("export.format.picker")
                            .onCompatibleChange(of: model.exportFormat) { _ in model.exportOptionsChanged() }

                            Picker("Scope", selection: $model.exportScope) {
                                Text("Original").tag("original")
                                Text("Margins").tag("source_interjections")
                                Text("Full Session").tag("full_session")
                            }
                            .segmentedUnlessLargeText()
                            .accessibilityIdentifier("export.scope.picker")
                            .onCompatibleChange(of: model.exportScope) { _ in model.exportOptionsChanged() }

                            Toggle("Source Text", isOn: $model.exportIncludesSourceText)
                                .accessibilityIdentifier("export.includeSourceText.toggle")
                                .onCompatibleChange(of: model.exportIncludesSourceText) { _ in model.exportOptionsChanged() }
                                .disabled(!model.exportSourceTextAvailable)
                            if !model.exportSourceTextAvailable {
                                Text("Native audio exports include only bounded listening context, not full source text.")
                                    .font(.footnote)
                                    .foregroundStyle(AppColors.secondaryText)
                            }
                            Toggle("Reference", isOn: $model.exportIncludesReference)
                                .accessibilityIdentifier("export.includeReference.toggle")
                                .onCompatibleChange(of: model.exportIncludesReference) { _ in model.exportOptionsChanged() }
                            Toggle("Listening Map", isOn: $model.exportIncludesListeningMap)
                                .accessibilityIdentifier("export.includeListeningMap.toggle")
                                .onCompatibleChange(of: model.exportIncludesListeningMap) { _ in model.exportOptionsChanged() }
                            Toggle("Margins", isOn: $model.exportIncludesInterjections)
                                .accessibilityIdentifier("export.includeInterjections.toggle")
                                .onCompatibleChange(of: model.exportIncludesInterjections) { _ in model.exportOptionsChanged() }
                            Toggle("AI Turns", isOn: $model.exportIncludesTurns)
                                .accessibilityIdentifier("export.includeTurns.toggle")
                                .onCompatibleChange(of: model.exportIncludesTurns) { _ in model.exportOptionsChanged() }
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        if !model.exportPreview.isEmpty {
                            #if canImport(UIKit)
                            Button {
                                isSharePresented = true
                            } label: {
                                Label("Export Session", systemImage: "doc.text")
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            .accessibilityIdentifier("export.share.button")
                            .sheet(isPresented: $isSharePresented) {
                                SessionActivityView(
                                    activityItems: exportActivityItems,
                                    onSuccessfulCompletion: model.recordSessionExported
                                )
                            }
                            #else
                            ShareLink(item: model.exportPreview) {
                                Label("Export Session", systemImage: "doc.text")
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            .accessibilityIdentifier("export.share.button")
                            #endif
                        }
                        Button {
                            model.copyPlainTextExport()
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(model.exportPreview.isEmpty)
                            .accessibilityIdentifier("export.copyPlainText.button")
                        Button("Details", action: { model.openItemFromTap(id: model.selectedItem.id) })
                            .buttonStyle(SecondaryButtonStyle())
                            .accessibilityIdentifier("export.item.button")
                    }
                    ProductPanel {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Preview")
                                    .font(.headline)
                                Spacer()
                                if !model.exportPreview.isEmpty {
                                    Text(model.exportPreviewSizeDescription)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(AppColors.secondaryText)
                                }
                            }
                            if model.exportPreviewIsTruncated {
                                Label(
                                    "Preview truncated; Copy and Export use the complete export.",
                                    systemImage: "doc.text.magnifyingglass"
                                )
                                .font(.caption)
                                .foregroundStyle(AppColors.secondaryText)
                                .accessibilityIdentifier("export.preview.truncated")
                            }
                            Text(model.exportPreview.isEmpty ? "No export yet." : model.displayedExportPreview)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityLabel(
                                    model.exportPreviewIsTruncated
                                        ? "Truncated export preview, \(model.exportPreviewSizeDescription). Copy and Export use the complete export."
                                        : "Export preview, \(model.exportPreviewSizeDescription)."
                                )
                                .accessibilityIdentifier("export.preview")
                        }
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
            .miniPlayerKeepOut()
        }
    }

    #if canImport(UIKit)
    private var exportActivityItems: [Any] {
        if model.exportFormat == "markdown", let fileURL = model.exportFileURL {
            return [fileURL]
        }
        return [model.exportPreview]
    }
    #endif
}

#if canImport(UIKit)
extension View {
    /// The share sheet for a file while `url` is set; closing it clears `url` (#493).
    func fileShareSheet(_ url: Binding<URL?>) -> some View {
        sheet(isPresented: Binding(get: { url.wrappedValue != nil }, set: {
            guard !$0 else { return }
            // The share sheet has closed: its file is no longer needed.
            if let file = url.wrappedValue { MarginMarkdownShare.discardShare(file) }
            url.wrappedValue = nil
        })) {
            if let file = url.wrappedValue {
                SessionActivityView(activityItems: [file], onSuccessfulCompletion: {})
            }
        }
    }
}

/// What the choice at "Export this Margin" was (#3211): the Spoken Note export's question, for one Margin.
enum MarginExportChoice { case textOnly, audioAndText }

/// The files one Margin's Export hands to the share sheet, and how to remove them when it closes.
struct MarginExportShare {
    let urls: [URL]
    let discard: () -> Void
}

extension View {
    /// The share sheet for a Margin's export while `share` is set; closing it clears it and removes the files. One sheet
    /// carries both the note alone and the recording with the note, since two sheets on one view can drop each other.
    func marginExportShareSheet(_ share: Binding<MarginExportShare?>) -> some View {
        sheet(isPresented: Binding(get: { share.wrappedValue != nil }, set: {
            guard !$0 else { return }
            share.wrappedValue?.discard()
            share.wrappedValue = nil
        })) {
            if let current = share.wrappedValue {
                SessionActivityView(activityItems: current.urls, onSuccessfulCompletion: {})
            }
        }
    }
}

extension View {
    /// The share sheet for a spoken note's export while `files` or `text` is set (#3660). Both go through this one sheet,
    /// since two sheets on one view can drop each other. Clearing them, which the sheet does when it closes, removes the
    /// folder the export was made in (`SpokenNoteExportModel`).
    func spokenNoteExportSheet(_ export: SpokenNoteExportModel) -> some View {
        sheet(isPresented: Binding(get: { export.files != nil || export.text != nil }, set: {
            guard !$0 else { return }
            export.files = nil
            export.text = nil
        })) {
            if let exported = export.files {
                SessionActivityView(activityItems: exported.shareURLs, onSuccessfulCompletion: {})
            } else if let exported = export.text {
                SessionActivityView(activityItems: SpokenNoteTextShareItem.items(for: exported), onSuccessfulCompletion: {})
            }
        }
    }
}

extension View {
    /// Everything a spoken note's Export shows (#3660): what to export, the share sheet when it is ready, a question first
    /// when it holds less than the whole note or has no words yet, and a plain alert when it fails.
    func spokenNoteExportFlow(_ export: SpokenNoteExportModel) -> some View {
        spokenNoteExportSheet(export)
            .confirmationDialog(
                "What do you want to export?",
                isPresented: Binding(get: { export.choosing != nil }, set: { if !$0 { export.choosing = nil } }),
                titleVisibility: .visible,
                presenting: export.choosing
            ) { request in
                Button("Text only") { export.choose(.textOnly, for: request) }
                    .accessibilityIdentifier("spokenNote.export.textOnly")
                Button("Audio and text") { export.choose(.audioAndText, for: request) }
                    .accessibilityIdentifier("spokenNote.export.audioAndText")
                Button("Cancel", role: .cancel) {}
            }
            .alert(
                "Part of this note can't be exported",
                isPresented: Binding(get: { export.partialQuestion != nil }, set: { if !$0 { export.resolvePartial(share: false) } })
            ) {
                Button("Export what's there") { export.resolvePartial(share: true) }
                Button("Cancel", role: .cancel) { export.resolvePartial(share: false) }
            } message: {
                Text(export.partialQuestion ?? "")
            }
            .alert(
                "No words yet",
                isPresented: Binding(get: { export.noWords != nil }, set: { if !$0 { export.noWords = nil } }),
                presenting: export.noWords
            ) { request in
                Button("Export Audio") { export.choose(.audioAndText, for: request) }
                    .accessibilityIdentifier("spokenNote.export.audioInstead")
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This note has no words written down yet, so there is no text to export. You can export its audio instead.")
            }
            .alert("Couldn't export", isPresented: Binding(get: { export.message != nil }, set: { if !$0 { export.message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(export.message ?? "")
            }
    }
}

/// One form of a spoken note's text for the share sheet (#3660). The sheet is given two of these, a String and a `.txt`,
/// so it offers everything that takes either; once a destination is picked, each says whether that destination gets it
/// (`SpokenNoteTextDelivery`). Notes, Messages and Copy then get real text, and Files a file named after the note.
final class SpokenNoteTextShareItem: NSObject, UIActivityItemSource {
    private let export: SpokenNoteTextExport
    private let isFile: Bool

    private init(_ export: SpokenNoteTextExport, isFile: Bool) {
        self.export = export
        self.isFile = isFile
    }

    static func items(for export: SpokenNoteTextExport) -> [SpokenNoteTextShareItem] {
        [SpokenNoteTextShareItem(export, isFile: false), SpokenNoteTextShareItem(export, isFile: true)]
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        isFile ? export.fileURL : export.text
    }

    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        item(forActivity: activityType?.rawValue)
    }

    func activityViewController(_ activityViewController: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        export.title
    }

    /// The String or URL this destination gets from this item, or nil when it gets the other form.
    func item(forActivity activityType: String?) -> Any? {
        switch SpokenNoteTextDelivery.forActivity(activityType) {
        case .text: return isFile ? nil : export.text
        case .file: return isFile ? export.fileURL : nil
        case .textAndFile: return isFile ? export.fileURL : export.text
        }
    }
}

/// Shown over the Library while a note's files are being made (a long note takes a moment to join).
struct SpokenNoteExportProgress: View {
    var body: some View {
        ProgressView("Preparing export…")
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityIdentifier("spokenNote.exportProgress")
    }
}

private struct SessionActivityView: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let activityItems: [Any]
    let onSuccessfulCompletion: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            if completed {
                onSuccessfulCompletion()
            }
            dismiss()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
