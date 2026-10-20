import Foundation
import SessionKit
import SessionKitSupertonic

/// Where Supertonic's model files are: the copy downloaded from Settings › Voices (#1819), or nil. The app no
/// longer bundles the model (#1820), so nil means "not downloaded": Kitten reads until the listener downloads it,
/// and nothing downloads without their tap. The downloaded files are byte-identical to the ones the app used to
/// bundle (the catalog's hashes are those files' hashes), so audio already rendered keeps its render identity:
/// `SupertonicRenderIdentity` hashes the files, not their path.
enum SupertonicAssetResolver {
    /// Supertonic's id in the voice catalog.
    static let catalogVoiceId = "supertonic-3-int8"

    static func location(
        supportDirectory: URL? = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    ) -> SupertonicAssetLocation? {
        guard let supportDirectory,
              let folder = VoiceCatalogCoordinator.installedFolder(voiceId: catalogVoiceId, supportDirectory: supportDirectory)
        else { return nil }
        let downloaded = SupertonicAssetLocation(rootURL: folder)
        return (try? downloaded.validate()) != nil ? downloaded : nil
    }

    static var isAvailable: Bool { location() != nil }
}
