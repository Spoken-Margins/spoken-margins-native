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
    /// Why the toolbar's Share has nothing to send here (#5306), as the item screen's Share says it (#4229).
    @State private var shareExplanation: ItemShareStart.Explanation?
    @State private var checksShare = false
    /// The session this screen showed when its Share opened the sheet. Opening the sheet moves `exportSessionId` to the
    /// newest pass with a sendable Margin, so it is put back when the sheet closes, with a fresh preview (#5306).
    @State private var sessionBeforeShare: String?

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
                    Text(ShareExportSwitch.exportScreenIntro)
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

                            VStack(alignment: .leading, spacing: 6) {
                                Text(ExportFormatChoice.heading)
                                    .font(.subheadline.weight(.semibold))
                                Picker(
                                    ExportFormatChoice.heading,
                                    selection: Binding(
                                        get: { ExportFormatChoice(storedFormat: model.exportFormat).rawValue },
                                        set: { model.exportFormat = $0 }
                                    )
                                ) {
                                    ForEach(ExportFormatChoice.allCases, id: \.self) { choice in
                                        Text(choice.label).tag(choice.rawValue)
                                    }
                                }
                                .segmentedUnlessLargeText()
                                .accessibilityHint(ExportFormatChoice(storedFormat: model.exportFormat).caption)
                                .accessibilityIdentifier("export.format.picker")
                                .onCompatibleChange(of: model.exportFormat) { _ in model.exportOptionsChanged() }
                                ExportOptionCaption(text: ExportFormatChoice(storedFormat: model.exportFormat).caption)
                                    .accessibilityIdentifier("export.format.caption")
                            }

                            ExportContentsOptions(
                                idPrefix: "export",
                                singleItemIsSpokenNote: model.selectedItem.isSpokenNote,
                                sourceTextAvailable: model.exportSourceTextAvailable,
                                showsSeparateSpokenNoteToggle: false,
                                spokenNoteFootnote: model.selectedItem.isSpokenNote ? model.exportSpokenNoteFootnote : nil
                            )
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
                            .trackedSheet(isPresented: $isSharePresented) {
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
                // One tap to the Share Margins sheet for the same item (#5306): the friend sheet the item screen's Share opens.
                ToolbarItem(placement: .topBarTrailing) {
                    Button(ShareExportSwitch.shareButtonTitle, systemImage: "square.and.arrow.up", action: switchToShare)
                        .labelStyle(.titleAndIcon)
                        .disabled(model.selectedItem.id.isEmpty || checksShare)
                        .accessibilityHint(ShareExportSwitch.shareButtonHint)
                        .accessibilityIdentifier("export.friendShare.button")
                }
            }
            .onChange(of: model.isSharingInterjectionsPresented) { _, isPresented in
                guard !isPresented, let sessionId = sessionBeforeShare else { return }
                sessionBeforeShare = nil
                model.openExport(sessionId: sessionId)
            }
            .alert(
                shareExplanation?.title ?? "",
                isPresented: Binding(get: { shareExplanation != nil }, set: { if !$0 { shareExplanation = nil } }),
                presenting: shareExplanation
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { explanation in
                Text(explanation.message)
            }
            .miniPlayerKeepOut()
        }
    }

    /// The toolbar's Share (#5306): the Share Margins sheet when this item has Margins to send, otherwise an alert that
    /// says why, by the item screen's own rule (`ItemShareStart`). It starts where the item screen's Share starts (the
    /// review with the listener's Margins picked, or the reply sheet when a friend's answers are waiting), so the two doors
    /// can't disagree (Default taken on #5306). A second tap while the check runs does nothing.
    private func switchToShare() {
        guard !checksShare, !model.isSharingInterjectionsPresented else { return }
        checksShare = true
        let itemId = model.selectedItem.id
        Task {
            defer { checksShare = false }
            let start = await model.itemShareStart()
            guard model.selectedItem.id == itemId else { return }
            switch start {
            case .share:
                let sessionId = model.exportSessionId
                model.hangTelemetry.labels.scoped("exportShare") { model.openItemShareSheet() }
                if model.isSharingInterjectionsPresented { sessionBeforeShare = sessionId }
            case .nothingYet(let explanation): shareExplanation = explanation
            }
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

/// A caption under an export choice: footnote size, secondary colour, wrapping (#4956).
struct ExportOptionCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(AppColors.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The Contents picker and the toggles under it, shared by the Export and Export Sessions screens so the two can't
/// drift apart (#4956). Every word comes from `ExportOptionWords.swift` in SessionKit, where a host test pins it.
/// A toggle the Contents choice leaves out shows dimmed and off with a caption saying why; its saved value is kept.
struct ExportContentsOptions: View {
    @EnvironmentObject private var model: Gate1AppModel

    /// `"export"` or `"batchExport"`: the accessibility ids keep each screen's existing prefix.
    let idPrefix: String
    /// The Export screen's item is a spoken note: Source Text follows the note's own switch and is never disabled.
    let singleItemIsSpokenNote: Bool
    /// False for a podcast or audio file on the Export screen: Source Text is disabled with its own caption.
    let sourceTextAvailable: Bool
    /// Export Sessions shows a separate Spoken Note Text toggle when a picked session is a spoken note.
    let showsSeparateSpokenNoteToggle: Bool
    /// The spoken note's own footnote on the Export screen, shown right after Source Text.
    let spokenNoteFootnote: String?

    private var contents: ExportContents { ExportContents(storedScope: model.exportScope) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ExportContents.heading)
                .font(.subheadline.weight(.semibold))
            Picker(
                ExportContents.heading,
                selection: Binding(
                    get: { ExportContents(storedScope: model.exportScope).tag },
                    set: { model.exportScope = $0 }
                )
            ) {
                ForEach(ExportContents.allCases, id: \.self) { choice in
                    Text(choice.label).tag(choice.tag)
                }
            }
            .segmentedUnlessLargeText()
            .accessibilityHint(contents.caption)
            .accessibilityIdentifier("\(idPrefix).scope.picker")
            .onCompatibleChange(of: model.exportScope) { _ in model.exportOptionsChanged() }
            ExportOptionCaption(text: contents.caption)
                .accessibilityIdentifier("\(idPrefix).scope.caption")
        }

        if singleItemIsSpokenNote {
            // A spoken note is the listener's own words: its Source Text has its own remembered value,
            // on by default, and is never disabled (#4782).
            toggleRow(
                title: ExportToggle.spokenNoteText.title,
                caption: ExportToggle.spokenNoteText.caption,
                isOn: $model.exportIncludesSpokenNoteText
            )
            .accessibilityIdentifier("\(idPrefix).includeSourceText.toggle")
            .onCompatibleChange(of: model.exportIncludesSourceText) { _ in model.exportOptionsChanged() }
            .onCompatibleChange(of: model.exportIncludesSpokenNoteText) { _ in model.exportOptionsChanged() }
        } else {
            toggleRow(
                title: ExportToggle.sourceText.title,
                caption: sourceTextAvailable ? ExportToggle.sourceText.caption : ExportToggle.sourceTextUnavailableCaption,
                isOn: $model.exportIncludesSourceText
            )
            .accessibilityIdentifier("\(idPrefix).includeSourceText.toggle")
            .onCompatibleChange(of: model.exportIncludesSourceText) { _ in model.exportOptionsChanged() }
            .disabled(!sourceTextAvailable)
        }
        if let spokenNoteFootnote {
            Text(spokenNoteFootnote)
                .font(.footnote)
                .foregroundStyle(AppColors.secondaryText)
                .accessibilityIdentifier("export.spokenNoteFootnote")
        }
        if showsSeparateSpokenNoteToggle {
            // A picked session on a spoken note follows the note's own text switch, shared with the single
            // Export screen (#4782); "Source Text" keeps applying to articles and PDFs.
            toggleRow(
                title: ExportToggle.spokenNoteText.title,
                caption: ExportToggle.spokenNoteText.caption,
                isOn: $model.exportIncludesSpokenNoteText
            )
            .accessibilityIdentifier("\(idPrefix).includeSpokenNoteText.toggle")
            .onCompatibleChange(of: model.exportIncludesSpokenNoteText) { _ in model.exportOptionsChanged() }
        }
        overridableToggle(.sourceLink, stored: $model.exportIncludesReference)
            .accessibilityIdentifier("\(idPrefix).includeReference.toggle")
            .onCompatibleChange(of: model.exportIncludesReference) { _ in model.exportOptionsChanged() }
        overridableToggle(.listeningMap, stored: $model.exportIncludesListeningMap)
            .accessibilityIdentifier("\(idPrefix).includeListeningMap.toggle")
            .onCompatibleChange(of: model.exportIncludesListeningMap) { _ in model.exportOptionsChanged() }
        overridableToggle(.margins, stored: $model.exportIncludesInterjections)
            .accessibilityIdentifier("\(idPrefix).includeInterjections.toggle")
            .onCompatibleChange(of: model.exportIncludesInterjections) { _ in model.exportOptionsChanged() }
        overridableToggle(.reflections, stored: $model.exportIncludesTurns)
            .accessibilityIdentifier("\(idPrefix).includeTurns.toggle")
            .onCompatibleChange(of: model.exportIncludesTurns) { _ in model.exportOptionsChanged() }
    }

    /// A toggle whose material the Contents choice may leave out: then it is disabled, shows off, and says why.
    /// "Shows off" is display only; the stored value is written only while the toggle isn't overridden.
    private func overridableToggle(_ toggle: ExportToggle, stored: Binding<Bool>) -> some View {
        let overridden = toggle.overriddenCaption(by: contents)
        let current = contents
        return toggleRow(
            title: toggle.title,
            caption: overridden ?? toggle.caption,
            isOn: Binding(
                get: { toggle.shownOn(stored: stored.wrappedValue, contents: current) },
                set: { if toggle.overriddenCaption(by: current) == nil { stored.wrappedValue = $0 } }
            )
        )
        .disabled(overridden != nil)
    }

    /// The label pattern of `SettingsScreen`: a title with a caption under it, inside the label so it dims with it.
    private func toggleRow(title: String, caption: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(AppColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#if canImport(UIKit)
extension View {
    /// The share sheet for a file while `url` is set; closing it clears `url` (#493).
    func fileShareSheet(_ url: Binding<URL?>) -> some View {
        trackedSheet(isPresented: Binding(get: { url.wrappedValue != nil }, set: {
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
    /// `onFinished` hears how the sheet ended: completed or not, which activity took the file, and any error (#5051).
    func marginExportShareSheet(_ share: Binding<MarginExportShare?>, onFinished: @escaping (_ completed: Bool, _ activityType: String?, _ failed: Bool) -> Void = { _, _, _ in }) -> some View {
        trackedSheet(isPresented: Binding(get: { share.wrappedValue != nil }, set: {
            guard !$0 else { return }
            share.wrappedValue?.discard()
            share.wrappedValue = nil
        })) {
            if let current = share.wrappedValue {
                SessionActivityView(activityItems: current.urls, onSuccessfulCompletion: {}, onFinished: onFinished)
            }
        }
    }
}

extension View {
    /// The share sheet for a spoken note's export while `files` or `text` is set (#3660). Both go through this one sheet,
    /// since two sheets on one view can drop each other. Clearing them, which the sheet does when it closes, removes the
    /// folder the export was made in (`SpokenNoteExportModel`).
    func spokenNoteExportSheet(_ export: SpokenNoteExportModel) -> some View {
        trackedSheet(isPresented: Binding(get: { export.files != nil || export.text != nil }, set: {
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
    var onFinished: ((_ completed: Bool, _ activityType: String?, _ failed: Bool) -> Void)?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        controller.completionWithItemsHandler = { activityType, completed, _, error in
            onFinished?(completed, activityType?.rawValue, error != nil)
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
