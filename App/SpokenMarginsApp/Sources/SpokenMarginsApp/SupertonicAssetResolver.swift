import Foundation
import SessionKit
import SessionKitSupertonic

/// Where Supertonic's model files are (#1819): the copy downloaded from Settings › Voices when there is one,
/// otherwise the copy bundled with the app. The downloaded files are byte-identical to the bundled ones
/// (the catalog's hashes are the bundled files' hashes), so audio already rendered keeps its render
/// identity whichever copy plays: `SupertonicRenderIdentity` hashes the files, not their path.
enum SupertonicAssetResolver {
    /// Supertonic's id in the voice catalog.
    static let catalogVoiceId = "supertonic-3-int8"

    static func location(
        supportDirectory: URL? = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false),
        bundleResources: URL? = Bundle.main.resourceURL
    ) -> SupertonicAssetLocation? {
        if let supportDirectory,
           let folder = VoiceCatalogCoordinator.installedFolder(voiceId: catalogVoiceId, supportDirectory: supportDirectory) {
            let downloaded = SupertonicAssetLocation(rootURL: folder)
            if (try? downloaded.validate()) != nil { return downloaded }
        }
        if let bundled = bundleResources?.appending(path: "Supertonic", directoryHint: .isDirectory) {
            let location = SupertonicAssetLocation(rootURL: bundled)
            if (try? location.validate()) != nil { return location }
        }
        return nil
    }

    static var isAvailable: Bool { location() != nil }

    /// The render signature for `voice` at `assets`, off the main actor. `existing` is reused while its
    /// voice style still hashes the same, so a playing item doesn't rehash the model files.
    static func renderSignature(assets: SupertonicAssetLocation, voice: SupertonicVoiceID,
                                reusing existing: TTSRenderSignature?) async throws -> TTSRenderSignature {
        try await Task.detached(priority: .utility) {
            if let existing,
               existing.voiceStyleHash == SupertonicRenderIdentity.sha256(try Data(contentsOf: assets.voiceStyleURL(for: voice))) { return existing }
            return try SupertonicRenderIdentity.make(assets: assets, voice: voice)
        }.value
    }
}
