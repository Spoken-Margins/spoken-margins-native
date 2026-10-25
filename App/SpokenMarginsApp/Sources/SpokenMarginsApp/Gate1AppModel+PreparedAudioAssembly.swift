import Foundation
import SessionKit
import SessionKitPersistence
import SessionKitSupertonic

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
        func stillCurrent() -> Bool {
            (try? PreparedAudioEnqueue.withCurrentManifest(manifest, repository: store) { _, current in
                guard current.text == item.text else { return false }
                return try PreparedAudioEnqueue.preparedText(item: current, repository: store) == sourceText
            }) == true
        }
        guard stillCurrent() else { return }
        // A stand-in (iOS voice) chunk waits for a play to retry Supertonic; don't bake it in (#363).
        guard !PreparedAudioCoordinator.hasStandIns(manifest) else { return }
        // Narration replaces Item.text with its own, so it keeps Item.text and maps into it (#336).
        guard let speech = PreparedSpeechHooks.texts.resolve(item: item, documents: store), speech.text == sourceText else { return }
        let chunks = try PreparedAudioCoordinator.assemblyChunks(
            plan: plan, manifest: manifest, sourceText: sourceText,
            preparedRoot: support.appending(path: "PreparedAudio", directoryHint: .isDirectory)
        )
        let assemblyReservation = try await ledger.reserve(
            ownerId: "prepared-artifact-\(manifest.id)",
            byteCount: max(1, manifest.chunks.reduce(0) { $0 + $1.byteCount }),
            pinning: PreparedAudioCoordinator.ledgerPaths(ofChunksIn: manifest) // its inputs stay until assembled (#645)
        )
        do {
            let prepared = try await SupertonicPreparedAudioAssembler.assemble(
                itemId: item.id,
                sourceText: speech.itemText,
                projection: speech.assemblyProjection(),
                voice: voice,
                chunks: chunks,
                outputDirectory: support.appending(path: "PreparedSupertonicAudio", directoryHint: .isDirectory)
            )
            let assembledURL = prepared.media.url.flatMap(URL.init(string:))
            var refused = false // Stop or a new voice landed while assembling: drop the audio, no failure (#2134)
            let attached = try PreparedAudioEnqueue.withCurrentManifest(manifest, repository: store) { saved, current in
                guard PreparedAudioEnqueue.mayComplete(saved.state) else { refused = true; return false }
                guard current.text == item.text, try PreparedAudioEnqueue.preparedText(item: current, repository: store) == sourceText else { return false }
                return attachPreparedTextAudio(prepared, itemId: item.id, replaceActivePlayback: false)
            }
            guard attached != nil, !refused, stillCurrent() else {
                await ledger.discardStaleAssembly(assembledURL, reservationId: assemblyReservation.id)
                return
            }
            guard attached == true, let url = assembledURL else {
                throw SessionKitError.persistenceFailed("prepared_audio_attach_failed")
            }
            guard try await coordinator.complete(itemId: item.id, signature: signature, prepared: prepared) else {
                await ledger.discardStaleAssembly(url, reservationId: assemblyReservation.id)
                return
            }
            refreshLibraryRowsInBackground()
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            let relative = String(url.standardizedFileURL.path.dropFirst(support.standardizedFileURL.path.count + 1))
            guard try await ledger.commitPrepared(
                reservationId: assemblyReservation.id,
                asset: OwnedOfflineAsset(
                    id: "prepared-artifact-\(manifest.id)",
                    itemId: item.id,
                    category: .preparedAudio,
                    relativePath: relative,
                    byteCount: Int64(values.fileSize ?? 0),
                    isReproducible: true
                ), manifest: manifest
            ) else { return }
            for asset in try store.loadOwnedOfflineAssets() where asset.itemId == item.id && asset.category == .preparedChunk {
                try store.updateOwnedOfflineAsset(id: asset.id) { $0.isRedundant = true }
            }
        } catch {
            try? await ledger.release(reservationId: assemblyReservation.id)
            throw error
        }
    }
}
