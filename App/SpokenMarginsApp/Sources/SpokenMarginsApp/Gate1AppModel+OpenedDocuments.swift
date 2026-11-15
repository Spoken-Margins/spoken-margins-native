import Foundation
import SessionKit
import UniformTypeIdentifiers

/// Files another app opens in Spoken Margins: a `.vtt`, `.srt`, `.docx` or `.txt` from Files, Mail or an AirDrop, and a
/// Listening Edition `.json` (#2997). Which files are taken, and every sentence, are SessionKit's
/// (`OpenedDocumentRoute`, `TranscriptImportMessage`); this is the model's thin call, and it goes through the same one
/// import as a pick from Files (`importFilesWithTranscriptRule`), so a file is never judged two ways.
extension Gate1AppModel {
    /// True when `url` was a file this took (and so is not for the other routes in `handleIncomingURL`).
    ///
    /// Opening a file never navigates: the app comes forward on the screen it was on, so a live session or a recording in
    /// progress is not disturbed. The import's own banner says what was added.
    func handleOpenedFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        if url.pathExtension.lowercased() == "json" { importListeningEditionFile(url); return true }
        let isPlainText = UTType(filenameExtension: url.pathExtension)?.conforms(to: .plainText) == true
        guard let route = OpenedDocumentRoute.route(forFileNamed: url.lastPathComponent, isPlainText: isPlainText) else {
            return false
        }
        switch route {
        case .unsupported(let message):
            reportFailure(message)
        case .transcriptRule, .text:
            importOpenedDocument(url)
        }
        return true
    }

    /// The opened files waiting their turn, newest last. The system calls `handleIncomingURL` once per file, so several
    /// files opened at once (a multi-file AirDrop or Share) must not race for the one import slot: each waits for the
    /// one before it, and for any other import already running, instead of being refused.
    private static var openedDocumentChain: Task<Void, Never>?

    /// Copies the file into the app's temporary folder with a coordinated read, which downloads a file that is in iCloud
    /// Drive, then hands the copy to the pick-from-Files import. The copy keeps the file's name, so the item's title and
    /// the transcript rule's file name are the listener's. The copy is deleted when the import ends.
    private func importOpenedDocument(_ url: URL) {
        let fileName = url.lastPathComponent
        let previous = Self.openedDocumentChain
        Self.openedDocumentChain = Task { @MainActor [weak self] in
            await previous?.value
            while let busy = self?.sourceImportTask { await busy.value }
            let staged = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                Result { try Self.stageOpenedDocument(url) }
            }.value
            guard let self else { return }
            switch staged {
            case .failure:
                // An iCloud file that has not downloaded, or one that was moved away, reads the same way to the listener.
                self.diagnostics["lastOpenedDocument"] = "could_not_read"
                self.reportFailure(TranscriptImportMessage(.couldNotRead, fileName: fileName))
            case .success(let copy):
                self.diagnostics["lastOpenedDocument"] = "staged:\(copy.pathExtension.lowercased())"
                let ended = OnceSignal()
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    ended.onSignal = { continuation.resume() }
                    self.hangTelemetry.labels.scoped("openedDocument.import") { self.beginStagedImport(copy, ended: ended) }
                }
            }
        }
    }

    /// Starts the import; `ended` fires when it ends, so the next opened file starts after it. Nothing navigates. The copy's
    /// folder goes when the import ends, whatever the import did; a pause of two minutes frees the queue if an import
    /// never reports an end.
    private func beginStagedImport(_ copy: URL, ended: OnceSignal) {
        let folder = copy.deletingLastPathComponent()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            ended.signal()
        }
        importFilesWithTranscriptRule(
            urls: [copy],
            route: TranscriptPickRoute(
                securityScopedURLs: [],
                navigatesWhenFinished: false,
                onFinished: { _ in
                    // Off the main actor, as every file removal is (#2256).
                    Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: folder) }
                    ended.signal()
                }))
    }

    /// Resumes a continuation once, whichever of the import's end and the timeout comes first.
    @MainActor private final class OnceSignal {
        var onSignal: (() -> Void)?
        private var signalled = false
        func signal() {
            guard !signalled else { return }
            signalled = true
            onSignal?()
        }
    }

    nonisolated static func stageOpenedDocument(_ url: URL) throws -> URL {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenedDocuments-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(url.lastPathComponent)
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            do { try FileManager.default.copyItem(at: readable, to: destination) } catch { copyError = error }
        }
        if let failure = coordinationError ?? copyError {
            try? FileManager.default.removeItem(at: folder)
            throw failure
        }
        return destination
    }
}
