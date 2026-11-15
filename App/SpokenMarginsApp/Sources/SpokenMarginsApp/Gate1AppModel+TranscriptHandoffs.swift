import Foundation
import SessionKit
import SessionKitEPUB
import SessionKitPersistence

/// Meeting transcripts the share extension left for the app (#2997, PR 5b). A `.vtt`, `.srt` or `.docx` waits in the
/// App Group's `TranscriptHandoffs` folder; a shared `.txt` arrives as a text payload and is asked whether it is a
/// transcript. Both go through `TranscriptLibraryImport`, the one import every entry point shares. What is read, in what
/// order and what is kept is SessionKit's (`TranscriptHandoffDrain`, `SharedTextFileTranscript`); this is the model's
/// thin call. Nothing here navigates: the drain runs at launch and at foreground, and a live session or a recording in
/// progress is not disturbed.
extension Gate1AppModel {
    /// The folder the share extension writes, beside the other handoffs in the same App Group (tests inject theirs through
    /// the source link handoff store).
    func resolvedTranscriptHandoffFolder() throws -> TranscriptHandoffFolder {
        TranscriptHandoffFolder(baseDirectory: try resolvedSourceLinkHandoffStore().rootDirectory)
    }

    /// What one drain of the transcript handoffs added and refused, for the drain's own banner.
    struct TranscriptHandoffResult {
        var addedItemIds: [String] = []
        var refusals: [TranscriptImportMessage] = []
    }

    /// Imports every transcript file waiting in the folder. A file the store could not save stays for the next drain.
    func drainTranscriptHandoffs() async -> TranscriptHandoffResult {
        var result = TranscriptHandoffResult()
        do {
            let folder = try resolvedTranscriptHandoffFolder()
            // Also clears what a killed share left behind, so it goes even when nothing is waiting.
            let waiting = try await Self.offMain { folder.sweepOrphans(); return try folder.pending().count }
            diagnostics["pendingTranscriptHandoffs"] = "\(waiting)"
            guard waiting > 0 else { return result }
            let store = try requireStore()
            let stillListening = engine?.itemIdsStillListening ?? []
            let report = await Task.detached(priority: .userInitiated) {
                await TranscriptHandoffDrain.run(
                    folder: folder, store: store, docxText: { try DocxPlainText.text(from: $0) },
                    stillListeningItemIds: stillListening)
            }.value
            if let storeError = report.storeError {
                diagnostics["pendingTranscriptHandoffsKept"] = "\(report.keptForRetry):\(SafeErrorText.describe(storeError))"
            }
            result.refusals = report.refusals
            result.addedItemIds = report.added.map(\.itemId)
            if !report.added.isEmpty { await finishSharedTranscripts(itemIds: result.addedItemIds, store: store) }
        } catch {
            diagnostics["pendingTranscriptHandoffsKept"] = "unavailable:\(SafeErrorText.describe(error))"
        }
        return result
    }

    /// What a shared `.txt` payload turned out to be.
    enum SharedTextFileRoute {
        /// Not a transcript, or not a text file from the share sheet: today's import.
        case ordinary
        case transcript(itemId: String)
        /// Read as a transcript but nothing could be added (every line was empty). Its payload is done.
        case refused(TranscriptImportMessage)
    }

    /// Asks whether a shared `.txt` is a transcript, and imports it as one when it is. Throws only what the store throws.
    func routeSharedTextFile(_ handoff: BrowserTextHandoff) async throws -> SharedTextFileRoute {
        guard let fileName = SharedTextFileTranscript.fileName(for: handoff) else { return .ordinary }
        let store = try requireStore()
        let stillListening = engine?.itemIdsStillListening ?? []
        let text = handoff.text
        let outcome = try await Task.detached(priority: .userInitiated) {
            try await TranscriptLibraryImport.importText(
                name: fileName, text: text, store: store, stillListeningItemIds: stillListening)
        }.value
        switch outcome {
        case .notTranscript:
            return .ordinary
        case .failed(let message):
            return .refused(message)
        case .added(let itemId, _, _):
            await finishSharedTranscripts(itemIds: [itemId], store: store)
            return .transcript(itemId: itemId)
        }
    }

    /// After transcripts were saved in the background: the Library rows are read so the banner can name the item, the
    /// engine exists for the first listen, the first sentences are prepared, and the same onboarding steps as any file added
    /// from Files are marked (as `finishTranscriptImport` does for a pick).
    private func finishSharedTranscripts(itemIds: [String], store: SQLiteSessionStore) async {
        do { try await reloadLibraryRowsOffMain(store: store) } catch {
            diagnostics["sharedTranscriptReload"] = "failed:\(SafeErrorText.describe(error))"
        }
        if engine == nil {
            do { installEngine(try makeEngine(store: store)) } catch {
                diagnostics["sharedTranscriptEngine"] = "failed:\(SafeErrorText.describe(error))"
            }
        }
        markOnboardingSteps([.addedOwnSource, .addedFromFiles])
        itemIds.forEach { scheduleTextAudioPrewarmIfNeeded(itemId: $0) }
        diagnostics["lastSharedTranscriptCount"] = "\(itemIds.count)"
    }

    /// The banner for transcript files that could not be added: the file's own sentence for one, one line naming up to
    /// three for several. It goes after the other banners of a drain, so a success for another share can't cover it.
    func reportTranscriptHandoffRefusals(_ refusals: [TranscriptImportMessage]) {
        guard !refusals.isEmpty else { return }
        switch TranscriptPickBanner.make(
            added: [], refusals: refusals, documentsImported: 0, documentFailureNames: [], pickedCount: refusals.count
        ) {
        case .failure(let words), .confirmation(let words): reportFailure(words)
        case .addedOne: break
        }
    }
}
