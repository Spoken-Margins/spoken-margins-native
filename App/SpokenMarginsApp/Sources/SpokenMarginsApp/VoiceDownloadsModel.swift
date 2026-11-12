import Foundation
import SessionKit
import SessionKitSpeechFrontEnd

/// The app's wiring for SessionKit's `VoiceDownloadsModel` (#1819): which voices this build can play, where the catalog
/// comes from, and the model made with the bundled snapshot and the background transport. The screen's state and rules
/// are the model in SessionKit, where they are host-tested (#318).
extension VoiceDownloadsModel {
    /// Voices this build can play once downloaded: Supertonic, plus each downloaded voice whose slice registered a
    /// renderer (`DownloadedVoiceRegistry`, #2700). Pocket TTS is in the catalog but has no player here yet.
    static let playableVoiceIds: Set<String> = Set([SupertonicAssetResolver.catalogVoiceId])
        .union(DownloadedVoiceRegistry.playableVoiceIds)
    /// No signed catalog is fetched yet: downloads come straight from the publishers on Hugging Face, and the
    /// owner's server is never asked (owner, 2026-10-19; #2055 audit 2). The snapshot bundled with the app is the
    /// catalog until the signed one has a home off that server.
    static let catalogURL: URL? = nil
    /// The one-time preparation each runtime needs after download (#2700). ONNX Runtime needs none; the
    /// Kokoro (#2705) and Phonon (#2704) slices register theirs in their own `…VoiceEngine.swift`.
    static let preparers: VoiceModelPreparers = DownloadedVoiceRegistry.preparers(adding: .standard)

    @MainActor static func make(supportDirectory: URL, repository: (any OfflineStorageRepository & Sendable)?) -> VoiceDownloadsModel {
        let snapshot = Bundle.main.url(forResource: "catalog-snapshot", withExtension: "json", subdirectory: "VoiceCatalog")
            .flatMap { try? Data(contentsOf: $0) }
        let coordinator = VoiceCatalogCoordinator(
            supportDirectory: supportDirectory,
            configuration: .init(
                catalogURL: catalogURL,
                playableVoiceIds: playableVoiceIds,
                deviceChipGeneration: VoiceDeviceProbe.chipGeneration(),
                preparers: preparers,
                bundledSnapshot: snapshot
            ),
            transport: BackgroundVoiceModelTransport.shared,
            repository: repository
        )
        let model = VoiceDownloadsModel(coordinator: coordinator)
        BackgroundVoiceModelTransport.shared.onBytesWritten = { [weak model] url, written in
            Task { @MainActor in model?.fileProgress(url: url, written: written) }
        }
        return model
    }
}
