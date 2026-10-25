#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// The saved name of a Skim summary voice (#1120).
///
/// A packet's scene, proposal and voice ids can hold any Unicode letter and any length, but a name on disk is cut to
/// ASCII `[A-Za-z0-9._-]` and 96 characters (`PodcastAnchorEvidencePaths.safeComponent`). Two ids that differ only in
/// what that drops used to share one file, so the second import replaced the first and both scenes played the second
/// voice. An id the cut would change now carries a short hash of the whole id; an id it leaves alone keeps its name,
/// so every voice the app or a normal packet has saved stays where it is.
///
/// A voice imported before this change sits under the old cut name. `legacyAssetID` is that name, and the Skim lookup
/// tries it after the new one, so no stored voice is detached and nothing on disk is renamed or migrated.
public enum SummaryBridgeAssetNaming {
    /// Characters kept from the cut id before the hash, so the whole component stays within `safeComponent`'s 96.
    static let keptPrefixLength = 78
    static let hashLength = 16

    /// `value` as one name component: itself when the cut leaves it alone, else its cut prefix plus a hash of the original.
    public static func component(_ value: String) -> String {
        let safe = PodcastAnchorEvidencePaths.safeComponent(value)
        if safe == value { return safe }
        let digest = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(safe.prefix(keptPrefixLength))-x\(digest.prefix(hashLength))"
    }

    /// `generatedVoiceKey` names the voice that rendered a summary the app made itself, already made safe by the caller.
    /// A supplied voice is keyed by the packet's own asset id instead.
    public static func assetID(
        itemId: String, proposalId: String, sceneId: String,
        suppliedAssetId: String?, generatedVoiceKey: String
    ) -> String {
        let voiceKey = suppliedAssetId.map { "supplied-\(component($0))" } ?? generatedVoiceKey
        return "summary-bridge-\(PodcastAnchorEvidencePaths.safeComponent(itemId))-\(component(proposalId))-\(component(sceneId))-\(voiceKey)"
    }

    /// The name a supplied voice was saved under before the hash, or nil when it is the same as `assetID`.
    public static func legacyAssetID(
        itemId: String, proposalId: String, sceneId: String, suppliedAssetId: String
    ) -> String? {
        let safe = PodcastAnchorEvidencePaths.safeComponent
        let legacy = "summary-bridge-\(safe(itemId))-\(safe(proposalId))-\(safe(sceneId))-supplied-\(safe(suppliedAssetId))"
        let current = assetID(itemId: itemId, proposalId: proposalId, sceneId: sceneId,
                              suppliedAssetId: suppliedAssetId, generatedVoiceKey: "")
        return legacy == current ? nil : legacy
    }
}
