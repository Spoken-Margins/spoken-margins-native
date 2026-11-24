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
    /// The kept file the copy is made from; nil for a PDF this iPhone has no copy of until the listener chooses one.
    private var original: URL?
    /// Where an accepted chosen PDF is kept (#4338, PR 6).
    private let originals: ItemOriginalStore?
    /// The page count the item's text recorded, which a chosen PDF must match.
    private var expectedPageCount = 0
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
        itemId: String, itemTitle: String, original: URL?, margins: [Interjection],
        store: SQLiteSessionStore?, originals: ItemOriginalStore? = nil,
        document: PDFCommentExportState.Document = .pdf, defaults: UserDefaults = .standard
    ) {
        self.document = document
        self.state = PDFCommentExportState(plan: MarginCommentPlan(entries: []), spots: nil, document: document)
        self.itemId = itemId
        self.itemTitle = itemTitle
        self.original = original
        self.originals = originals
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

    /// Reads the item's text, plans the comments and places them on the kept file, off the main thread. Runs once. A PDF
    /// this iPhone has no copy of stops at the plan and asks for the file (`chooseFile`).
    func load() async {
        guard !loaded else { return }
        loaded = true
        let author = defaults.string(forKey: Self.authorDefaultsKey) ?? ""
        let (itemId, margins, store, document, originals) = (itemId, margins, store, document, originals)
        // The screen looked for a kept copy when the item opened; a file chosen in this sheet before (PR 6) may have been
        // kept since, so look again rather than ask twice.
        let known = original
        let outcome: Result<(MarginCommentPlan, Int, PDFCommentExporter.Preview?, URL?), Error> =
            await Task.detached(priority: .userInitiated) {
                Result {
                    switch document {
                    case .pdf:
                        guard let store, let structured = try store.loadStructuredDocument(itemId: itemId) else {
                            throw PDFCommentWriter.Failure.unreadable
                        }
                        let plan = MarginCommentPlan.make(itemId: itemId, document: structured, margins: margins)
                        let pageCount = structured.extraction.pageCount
                        let kept = known ?? (originals?.kind(itemId: itemId) == .pdf ? originals?.url(itemId: itemId) : nil)
                        guard let kept else { return (plan, pageCount, nil, nil) }
                        return (plan, pageCount, try PDFCommentExporter.preview(source: kept, plan: plan), kept)
                    case .word:
                        // A Word item is its plain text: the Margins' anchors are offsets into it.
                        guard let store, let text = try store.loadItem(id: itemId).text, let original = known else {
                            throw DocxCommentWriter.Failure.notADocx
                        }
                        let plan = MarginCommentPlan.make(itemId: itemId, text: text, margins: margins)
                        let preview = try WordCommentExporter.preview(source: original, plan: plan)
                        return (plan, 0, PDFCommentExporter.Preview(placements: [], spots: preview.spots), original)
                    }
                }
            }.value
        switch outcome {
        case .success(let (plan, pageCount, preview, kept)):
            self.plan = plan
            self.expectedPageCount = pageCount
            self.original = kept
            if let preview {
                placements = preview.placements
                state = PDFCommentExportState(plan: plan, spots: preview.spots, authorName: author, document: document)
            } else {
                state = .waitingForOriginal(plan: plan, authorName: author)
            }
        case .failure(let error):
            state = PDFCommentExportState(plan: MarginCommentPlan(entries: []), spots: [:], authorName: author, document: document)
            switch error {
            case PDFCommentWriter.Failure.refused(.locked): state.markLocked()
            default: state.markUnreadable() // unreadable, or a file with no pages, or a package this writer can't edit
            }
        }
    }

    /// The listener chose a file for a PDF this iPhone has no copy of (#4338, PR 6). It is copied beside the item, off the
    /// main thread, and checked (`PDFCommentExporter.check`): the same page count, and at least half the Margins on their
    /// sentence. An accepted file becomes the item's kept original, so the question is not asked again, and the sheet
    /// fills in; a refused one is removed and the card says why. A second pick while one is checked does nothing.
    func chooseFile(at url: URL) {
        guard document == .pdf, state.beginCheckingChosenFile() else { return }
        let (plan, itemId, originals, expectedPageCount) = (plan, itemId, originals, expectedPageCount)
        Task {
            let decided: Result<(URL, PDFCommentExporter.Preview), PDFOriginalCheck.Refusal> =
                await Task.detached(priority: .userInitiated) {
                    guard let originals else { return .failure(.unreadable) }
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    // A copy in the item's folder first, so the check reads a file this app owns and an accepted file
                    // is kept by a rename. Never the picked file itself, and never a half file under the final name.
                    guard let staged = try? originals.stage(copying: url, itemId: itemId, kind: .pdf) else {
                        return .failure(.unreadable)
                    }
                    switch PDFCommentExporter.check(chosen: staged.url, plan: plan, expectedPageCount: expectedPageCount) {
                    case .refused(let refusal):
                        originals.discard(staged)
                        return .failure(refusal)
                    case .accepted(let preview):
                        guard let kept = try? originals.commit(staged) else {
                            originals.discard(staged)
                            return .failure(.unreadable)
                        }
                        return .success((kept, preview))
                    }
                }.value
            switch decided {
            case .success(let (kept, preview)):
                original = kept
                placements = preview.placements
                state = PDFCommentExportState(plan: plan, spots: preview.spots, authorName: state.authorName, document: document)
            case .failure(let refusal):
                state.refuseChosenFile(refusal)
            }
        }
    }

    /// Builds the copy in a fresh temporary folder and offers it to the share sheet. A second tap while one runs does
    /// nothing (`beginExport` refuses it).
    func export() {
        guard let original, state.beginExport() else { return }
        let (plan, placements, document) = (plan, placements, document)
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
