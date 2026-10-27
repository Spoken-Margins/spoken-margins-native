import Foundation
import SessionKit
import SessionKitPersistence

/// Batch export selection. Moved out of `Gate1AppModel.swift` unchanged (#1007).
extension Gate1AppModel {
    /// Opens Export Sessions; see `openBatchExport(scopedTo:)`.
    @discardableResult
    func openBatchExport() -> Task<Void, Never> {
        openBatchExport(scopedTo: nil)
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
