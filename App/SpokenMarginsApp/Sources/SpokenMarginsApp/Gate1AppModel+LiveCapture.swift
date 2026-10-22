import Foundation
import SessionKit
import SessionKitAudio

/// Live capture's call site on the model (#2481). The capture becomes an ordinary imported audio item, through
/// the same importer as an audiobook from Files, so storage doesn't change; its Margins are written by
/// `LiveCaptureMarginPlacer`; an optional transcript goes through the same path as any source audio's.
extension Gate1AppModel {
    func importLiveCapture(pcmURL: URL, margins: [LiveCaptureMargin], startedAt: Date, transcribe: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "live-capture-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        // The importer titles an item without metadata by its file name.
        let m4a = directory.appending(path: "Live capture \(formatter.string(from: startedAt)).m4a")
        try await Task.detached(priority: .userInitiated) {
            try LiveCaptureAudioExport.exportM4A(pcmURL: pcmURL, to: m4a)
        }.value

        let importer = try requireLocalSourceImporter()
        let item = try await importer.importAudiobook(from: m4a)
        guard let store else { throw SessionKitError.persistenceFailed("store_unavailable") }
        try LiveCaptureMarginPlacer.place(margins, itemId: item.id, repository: store)
        libraryItems = try loadLibraryRows(store: store)
        refreshMarginRows()
        selectedItem = try loadItemDetail(id: item.id, store: store)
        activeItemId = item.id
        screen = .item
        reportConfirmation("Saved \(item.title) with \(margins.count) Margin\(margins.count == 1 ? "" : "s").")

        guard transcribe, let audio = item.media?.url.flatMap(URL.init(string:)) else { return }
        let itemId = item.id
        let durationMs = item.media?.durationMs
        Task { [weak self] in
            do {
                let timeline = try await SystemSourceTranscriptionClient().transcribeSourceAudio(url: audio, itemId: itemId, durationMs: durationMs)
                self?.attachSourceTranscriptTimeline(timeline, itemId: itemId)
            } catch {
                self?.reportFailure(error, context: "Live capture transcript failed", itemId: itemId)
            }
        }
    }
}
