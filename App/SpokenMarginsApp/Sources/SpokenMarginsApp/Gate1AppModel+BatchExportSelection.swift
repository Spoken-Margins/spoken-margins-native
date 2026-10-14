import Foundation
import SessionKit
import SessionKitPersistence

/// Batch export selection. Moved out of `Gate1AppModel.swift` unchanged (#1007).
extension Gate1AppModel {
    func openBatchExport() {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_batch_export") else { return }
        syncPlaybackProgressForLifecycle()
        exportSessionId = nil
        exportPreview = ""
        batchExportFilter = .withInterjections
        selectedBatchExportSessionIds = []
        batchExportResult = nil
        do {
            let store = try requireStore()
            try refreshBatchExportRows(store: store)
            screen = .batchExport
        } catch {
            reportFailure(error, context: "Session export setup failed")
        }
    }

    var visibleBatchExportRows: [BatchSessionExportRow] {
        switch batchExportFilter {
        case .withInterjections:
            batchExportRows.filter { $0.interjectionCount > 0 }
        case .all:
            batchExportRows
        }
    }

    var hasBatchExportFolder: Bool { SavedFolderSetting.sessionExport.hasFolder() }

    func toggleBatchExportSelection(sessionId: String) {
        if selectedBatchExportSessionIds.contains(sessionId) {
            selectedBatchExportSessionIds.remove(sessionId)
        } else {
            selectedBatchExportSessionIds.insert(sessionId)
        }
        batchExportResult = nil
    }

    func selectAllVisibleBatchExportSessions() {
        selectedBatchExportSessionIds.formUnion(visibleBatchExportRows.map(\.id))
        batchExportResult = nil
    }

    func clearBatchExportSelection() {
        selectedBatchExportSessionIds = []
        batchExportResult = nil
    }
}
