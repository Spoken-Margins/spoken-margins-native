import Foundation
import SessionKit
import SessionKitEPUB
import SessionKitPDF
import SessionKitPersistence

/// A file ready for the share sheet.
struct PDFCommentShareFile: Identifiable {
    let id = UUID()
    let url: URL
    /// The folder the file was built in, removed when the share sheet closes.
    let folder: URL
    let commentCount: Int
}

/// Drives the "PDF with your Margins" sheet (#4338, PR 5), and the same sheet for a Word document (#4595). What the
/// sheet lists and offers is `PDFCommentExportState` (SessionKit, host-tested); the PDF work is `PDFCommentExporter`
/// (SessionKitPDF) and the Word work is `WordCommentExporter` (SessionKitEPUB). This holds them together, runs both off
/// the main thread, and hands the finished file to the share sheet. It is not part of `Gate1AppModel`.
@MainActor
final class PDFCommentExportModel: ObservableObject, Identifiable {
    /// The last name used on comments, remembered by this phone only.
    static let authorDefaultsKey = "pdfCommentAuthorName"

    @Published private(set) var state: PDFCommentExportState
    @Published var shareFile: PDFCommentShareFile?

    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }

    let itemTitle: String
    let document: PDFCommentExportState.Document
    private let itemId: String
    private let original: URL
    private let margins: [Interjection]
    private let store: SQLiteSessionStore?
    private let defaults: UserDefaults
    private var plan = MarginCommentPlan(entries: [])
    private var placements: [PDFMarginPlacement] = []
    private var loaded = false
    /// The file the share sheet is showing. Kept apart from `shareFile` (which the sheet's binding clears on any dismissal)
    /// so the temporary folder is removed and the state restored however the sheet closes.
    private var offered: PDFCommentShareFile?
    /// Whether the share sheet reported the file as sent. Only recorded here; `shareSheetClosed` acts on it, once the sheet
    /// is gone, so the order of the sheet's two callbacks never matters.
    private var reportedSent = false

    init(
        itemId: String, itemTitle: String, original: URL, margins: [Interjection],
        store: SQLiteSessionStore?, document: PDFCommentExportState.Document = .pdf, defaults: UserDefaults = .standard
    ) {
        self.document = document
        self.state = PDFCommentExportState(plan: MarginCommentPlan(entries: []), spots: nil, document: document)
        self.itemId = itemId
        self.itemTitle = itemTitle
        self.original = original
        self.margins = margins
        self.store = store
        self.defaults = defaults
    }

    var authorName: String {
        get { state.authorName }
        set { state.authorName = newValue }
    }

    func toggle(_ id: String) { state.toggle(id) }
    func dismissFailure() { state.dismissFailure() }

    /// Reads the item's text, plans the comments and places them on the kept file, off the main thread. Runs once.
    func load() async {
        guard !loaded else { return }
        loaded = true
        let author = defaults.string(forKey: Self.authorDefaultsKey) ?? ""
        let (itemId, original, margins, store, document) = (itemId, original, margins, store, document)
        let outcome: Result<(MarginCommentPlan, [PDFMarginPlacement], [String: PDFCommentExportState.Spot]), Error> =
            await Task.detached(priority: .userInitiated) {
                Result {
                    switch document {
                    case .pdf:
                        guard let store, let structured = try store.loadStructuredDocument(itemId: itemId) else {
                            throw PDFCommentWriter.Failure.unreadable
                        }
                        let plan = MarginCommentPlan.make(itemId: itemId, document: structured, margins: margins)
                        let preview = try PDFCommentExporter.preview(source: original, plan: plan)
                        return (plan, preview.placements, preview.spots)
                    case .word:
                        // A Word item is its plain text: the Margins' anchors are offsets into it.
                        guard let store, let text = try store.loadItem(id: itemId).text else {
                            throw DocxCommentWriter.Failure.notADocx
                        }
                        let plan = MarginCommentPlan.make(itemId: itemId, text: text, margins: margins)
                        let preview = try WordCommentExporter.preview(source: original, plan: plan)
                        return (plan, [], preview.spots)
                    }
                }
            }.value
        switch outcome {
        case .success(let (plan, placements, spots)):
            self.plan = plan
            self.placements = placements
            state = PDFCommentExportState(plan: plan, spots: spots, authorName: author, document: document)
        case .failure(let error):
            state = PDFCommentExportState(plan: MarginCommentPlan(entries: []), spots: [:], authorName: author, document: document)
            switch error {
            case PDFCommentWriter.Failure.refused(.locked): state.markLocked()
            default: state.markUnreadable() // unreadable, or a file with no pages, or a package this writer can't edit
            }
        }
    }

    /// Builds the copy in a fresh temporary folder and offers it to the share sheet. A second tap while one runs does
    /// nothing (`beginExport` refuses it).
    func export() {
        guard state.beginExport() else { return }
        let (plan, placements, original, document) = (plan, placements, original, document)
        let ids = state.includedIds
        let author = state.authorForComments
        let fileName = PDFCommentExportFileName.make(title: itemTitle, document: document)
        Task {
            let built: Result<PDFCommentShareFile, Error> = await Task.detached(priority: .userInitiated) {
                Result {
                    let folder = SessionShareFiles.shareRoot().appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let file = folder.appendingPathComponent(fileName)
                    do {
                        switch document {
                        case .pdf:
                            try PDFCommentExporter.export(
                                source: original, plan: plan, placements: placements, includedIds: ids, author: author, to: file)
                        case .word:
                            try WordCommentExporter.export(source: original, plan: plan, includedIds: ids, author: author, to: file)
                        }
                    } catch {
                        try? FileManager.default.removeItem(at: folder)
                        throw error
                    }
                    return PDFCommentShareFile(url: file, folder: folder, commentCount: ids.count)
                }
            }.value
            switch built {
            case .success(let file):
                offered = file
                reportedSent = false
                shareFile = file
            case .failure: state.endExport(failed: true)
            }
        }
    }

    /// The share sheet's own report: the listener sent the file somewhere (`completed`) or did not. It only records it.
    func shareSheetReported(completed: Bool) {
        if completed { reportedSent = true }
    }

    /// The share sheet is gone, however it closed (sending, Cancel, a swipe). Safe to call more than once. The temporary
    /// copy is removed; a cancelled sheet returns to the full list with nothing changed. Returns the number of comments
    /// sent, once, when the listener sent the file.
    func shareSheetClosed() -> Int? {
        guard let file = offered else { return nil }
        offered = nil
        shareFile = nil
        let folder = file.folder
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: folder) }
        state.endExport(failed: false)
        let sent = reportedSent
        reportedSent = false
        guard sent else { return nil }
        defaults.set(state.authorForComments, forKey: Self.authorDefaultsKey)
        return file.commentCount
    }
}
