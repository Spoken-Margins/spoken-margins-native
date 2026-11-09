import Foundation
import SessionKit
import SessionKitPersistence
import SessionKitSupertonic

extension Gate1AppModel {
    func finishBackgroundPreparedAudio(
        item: Item,
        sourceText: String,
        voice: SupertonicVoiceID,
        assemblyVoiceKey: String? = nil,
        signature: TTSRenderSignature,
        manifest: PreparedAudioManifest,
        plan: [PreparedChunkPlan],
        store: SQLiteSessionStore,
        ledger: OfflineStorageLedger,
        coordinator: PreparedAudioCoordinator,
        support: URL
    ) async throws {
        let itemText = item.text
        // A small transaction of reads, off the main actor (#2506). A cancelled task throws, so the pass keeps its job to
        // retry (`waitingForSystem`) instead of reading the cancel as "no longer current" and dropping it.
        let isCurrent = try await StoreReader(store).read { [manifest, itemText, sourceText] in
            PreparedAudioEnqueue.isStillCurrent(manifest, itemText: itemText, sourceText: sourceText, repository: $0)
        }
        guard isCurrent else { return }
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
                voiceKey: assemblyVoiceKey,
                chunks: chunks,
                outputDirectory: support.appending(path: "PreparedSupertonicAudio", directoryHint: .isDirectory)
            )
            let assembledURL = prepared.media.url.flatMap(URL.init(string:))
            // The re-check and the save are one transaction off the main actor; a Stop, a new voice or an edit that landed
            // while assembling drops the audio, with no failure (#2134, #2256).
            switch await attachAssembledPreparedAudioOffMain(prepared, itemId: item.id, manifest: manifest, itemText: item.text, sourceText: sourceText) {
            case .dropped:
                await ledger.discardStaleAssembly(assembledURL, reservationId: assemblyReservation.id)
                return
            case .failed:
                throw SessionKitError.persistenceFailed("prepared_audio_attach_failed")
            case .attached:
                break
            }
            guard let url = assembledURL else { throw SessionKitError.persistenceFailed("prepared_audio_attach_failed") }
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
            // The whole audio now stands in for the chunks; marking them is a few small writes, off the main actor (#2509).
            let itemId = item.id
            _ = try await StoreReader(store).read { try OnboardingAndOfflineAssetWrites.markRedundant(category: .preparedChunk, itemId: itemId, in: $0) }
        } catch {
            try? await ledger.release(reservationId: assemblyReservation.id)
            throw error
        }
    }
}
