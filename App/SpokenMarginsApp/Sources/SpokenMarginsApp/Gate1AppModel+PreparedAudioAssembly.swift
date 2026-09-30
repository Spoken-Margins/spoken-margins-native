import Foundation
import SessionKit
import SessionKitPersistence
import SessionKitSupertonic

/// Background preparation's last step: assemble the committed chunks into one file and attach it.
/// Kept out of Gate1AppModel.swift, which may not grow (#344, `scripts/hot_file_ratchet.py`).
extension Gate1AppModel {
    func finishBackgroundPreparedAudio(
        item: Item,
        sourceText: String,
        voice: SupertonicVoiceID,
        signature: TTSRenderSignature,
        manifest: PreparedAudioManifest,
        plan: [PreparedChunkPlan],
        store: SQLiteSessionStore,
        ledger: OfflineStorageLedger,
        coordinator: PreparedAudioCoordinator,
        support: URL
    ) async throws {
        // A re-import can upgrade the item and retire this manifest while chunks render
        // or assemble; its narration then speaks the old text, so it's dropped (#344).
        func stillCurrent() -> Bool {
            (try? store.loadPreparedAudioManifest(id: manifest.id)) != nil
                && (try? store.loadItem(id: item.id))?.text == sourceText
        }
        guard stillCurrent() else { return }
        // A stand-in (iOS voice) chunk waits for a play to retry Supertonic; don't bake it in (#363).
        guard !PreparedAudioCoordinator.hasStandIns(manifest) else { return }
        let chunks = try PreparedAudioCoordinator.assemblyChunks(
            plan: plan, manifest: manifest, sourceText: sourceText,
            preparedRoot: support.appending(path: "PreparedAudio", directoryHint: .isDirectory)
        )
        let assemblyReservation = try await ledger.reserve(
            ownerId: "prepared-artifact-\(manifest.id)",
            byteCount: max(1, manifest.chunks.reduce(0) { $0 + $1.byteCount })
        )
        do {
            let prepared = try await SupertonicPreparedAudioAssembler.assemble(
                itemId: item.id,
                sourceText: sourceText,
                projection: SpeechTextNormalizer.normalizeWithSourceOffsets(sourceText),
                voice: voice,
                chunks: chunks,
                outputDirectory: support.appending(path: "PreparedSupertonicAudio", directoryHint: .isDirectory)
            )
            let assembledURL = prepared.media.url.flatMap(URL.init(string:))
            guard stillCurrent() else {
                await ledger.discardStaleAssembly(assembledURL, reservationId: assemblyReservation.id)
                return
            }
            guard attachPreparedTextAudio(prepared, itemId: item.id, replaceActivePlayback: false),
                  let url = assembledURL else {
                throw SessionKitError.persistenceFailed("prepared_audio_attach_failed")
            }
            try await coordinator.complete(itemId: item.id, signature: signature, prepared: prepared)
            try refreshLibraryRows(store: store)
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            let relative = String(url.standardizedFileURL.path.dropFirst(support.standardizedFileURL.path.count + 1))
            try await ledger.commit(
                reservationId: assemblyReservation.id,
                asset: OwnedOfflineAsset(
                    id: "prepared-artifact-\(manifest.id)",
                    itemId: item.id,
                    category: .preparedAudio,
                    relativePath: relative,
                    byteCount: Int64(values.fileSize ?? 0),
                    isReproducible: true
                )
            )
            for var asset in try store.loadOwnedOfflineAssets() where asset.itemId == item.id && asset.category == .preparedChunk {
                asset.isRedundant = true
                try store.saveOwnedOfflineAsset(asset)
            }
        } catch {
            try? await ledger.release(reservationId: assemblyReservation.id)
            throw error
        }
    }
}
