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
                                Label("Export Session", systemImage: "square.and.arrow.up")
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
                                Label("Export Session", systemImage: "square.and.arrow.up")
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
                        Button("Item", action: { model.openItemFromTap(id: model.selectedItem.id) })
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

extension View {
    /// The share sheet for a spoken note's exported files while `files` is set (#3660). Setting `files` to nil, which the
    /// sheet does when it closes, removes the folder the files were made in (`SpokenNoteExportModel`).
    func spokenNoteExportSheet(_ files: Binding<SpokenNoteExportFiles?>) -> some View {
        sheet(isPresented: Binding(get: { files.wrappedValue != nil }, set: { if !$0 { files.wrappedValue = nil } })) {
            if let exported = files.wrappedValue {
                SessionActivityView(activityItems: exported.shareURLs, onSuccessfulCompletion: {})
            }
        }
    }
}

extension View {
    /// Everything a spoken note's Export shows (#3660): the share sheet when the files are ready, a question first when
    /// they hold less than the whole note, and a plain alert when it fails.
    func spokenNoteExportFlow(_ export: SpokenNoteExportModel) -> some View {
        spokenNoteExportSheet(Binding(get: { export.files }, set: { export.files = $0 }))
            .alert(
                "Part of this note can't be exported",
                isPresented: Binding(get: { export.partial != nil }, set: { if !$0 { export.resolvePartial(share: false) } })
            ) {
                Button("Export what's there") { export.resolvePartial(share: true) }
                Button("Cancel", role: .cancel) { export.resolvePartial(share: false) }
            } message: {
                Text(export.partial.map(SpokenNoteExportModel.partialMessage) ?? "")
            }
            .alert("Couldn't export", isPresented: Binding(get: { export.message != nil }, set: { if !$0 { export.message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(export.message ?? "")
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
