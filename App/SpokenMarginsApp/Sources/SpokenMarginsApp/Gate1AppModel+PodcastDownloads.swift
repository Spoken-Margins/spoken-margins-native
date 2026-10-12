import Foundation
import Security
import SessionKit
import SessionKitAI
import SessionKitAudio
import SessionKitSharing
import SessionKitSupertonic
import SessionKitPersistence
import SessionKitFeeds
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(PDFKit)
import PDFKit
#endif

/// Podcast download wiring (#986), moved unchanged out of the central model.
extension Gate1AppModel {
    func configurePodcastDownloads(store: SQLiteSessionStore) throws {
        try configureOfflineServices(store: store)
        podcastDownloadCoordinator?.shutdown()
        let limit = PodcastCacheLimitGB(rawValue: podcastCacheLimitGB) ?? .defaultValue
        let coordinator = try PodcastDownloadCoordinator(
            store: store,
            ledger: try requireOfflineLedger(
                store: store,
                rootDirectory: try applicationSupportDirectory()
            ),
            applicationSupportDirectory: try applicationSupportDirectory(),
            cacheLimit: limit,
            monitorsNetwork: !Self.isRunningUnitTests,
            connectivity: connectivity,
            usesBackgroundSession: !Self.isRunningUnitTests
        )
        coordinator.onRecordChanged = { [weak self] record in
            guard let self else { return }
            podcastDownloadRecords[record.itemId] = record
            if let index = libraryItems.firstIndex(where: { $0.id == record.itemId }) {
                let state = LibraryOfflineStateFilter.forItem(
                    preparedState: nil,
                    mediaSourceType: nil,
                    podcastDownloadState: record.state
                )
                if libraryItems[index].offlineState != state {
                    libraryItems[index].offlineState = state
                }
            }
            if diagnostics["podcastDownload:\(record.itemId)"] != record.state.rawValue {
                recordDeveloperDiagnostic("download.state", ["item": DeveloperDiagnosticRecording.token(record.itemId),
                    "state": record.state.rawValue, "bytes": String(record.bytesWritten),
                    "failure": DeveloperDiagnosticRecording.token(record.failureReason)])
            }
            diagnostics["podcastDownload:\(record.itemId)"] = record.state.rawValue
        }
        coordinator.onLocalAssetReady = { [weak self] itemId, url in
            self?.podcastLocalAssetDidBecomeReady(itemId: itemId, url: url)
        }
        podcastDownloadCoordinator = coordinator
        podcastDownloadRecords = coordinator.recordsByItemId
        diagnostics["podcastCacheLimitGB"] = "\(limit.rawValue)"
    }
}
