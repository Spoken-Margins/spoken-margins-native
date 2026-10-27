import Foundation

/// Which reading voices Settings' App Voice picker lists (#2700). James, Lily, Kitten and the iOS voice are always
/// there. A downloaded voice (Phonon, Kokoro) is listed only when all of these hold:
/// - this build has a player for it (`playableVoiceIds`, which only a registered renderer puts it in);
/// - it is installed;
/// - this device may run it: at or above its chip floor and its memory need (`VoiceCatalogRow.unusableHere`).
///
/// The current choice is always listed, so the picker never shows a blank selection; the player decides what reads.
public enum ReadingVoiceOffer {
    public static func choices(
        current: ReadingVoiceChoice,
        rows: [VoiceCatalogRow],
        playableVoiceIds: Set<String>
    ) -> [ReadingVoiceChoice] {
        ReadingVoiceChoice.allCases.filter { choice in
            guard let voiceId = choice.downloadedVoiceId else { return true }
            if choice == current { return true }
            return isUsable(voiceId: voiceId, rows: rows, playableVoiceIds: playableVoiceIds)
        }
    }

    /// Whether the downloaded voice can read on this device now.
    public static func isUsable(voiceId: String, rows: [VoiceCatalogRow], playableVoiceIds: Set<String>) -> Bool {
        guard playableVoiceIds.contains(voiceId), let row = rows.first(where: { $0.id == voiceId }),
              case .installed = row.state else { return false }
        return row.unusableHere == nil
    }
}
