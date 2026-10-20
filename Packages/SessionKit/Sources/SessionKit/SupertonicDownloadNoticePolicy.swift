import Foundation

/// Supertonic's model left the app for a download (#1820). A listener whose saved voice is a Supertonic one (James or
/// Lily) and who hasn't downloaded it sees, once, a card saying Supertonic is now a free download, with a button to
/// Settings › Voices. Until they download it the bundled Kitten voice reads; their choice of voice stays.
public enum SupertonicDownloadNoticePolicy {
    /// The flag that the card has been shown (or is no longer needed) on this phone.
    public static let seenKey = "supertonicDownloadNoticeSeenV1"

    public enum Decision: Equatable, Sendable {
        /// Show the card now, and remember that it was shown.
        case show
        /// Not now; ask again at the next launch.
        case wait
        /// Never needed again on this phone: record it as seen without showing it.
        case settle
        /// Already seen.
        case done
    }

    /// - Parameters:
    ///   - savedVoiceIsSupertonic: the listener's current voice is James or Lily.
    ///   - modelInstalled: Supertonic's model is downloaded and complete.
    ///   - hasSeen: the card was shown (or settled) before.
    ///   - anotherSheetShowing: another sheet (Terms, the first-run drawer) is up; two can't show at once.
    public static func decide(savedVoiceIsSupertonic: Bool, modelInstalled: Bool, hasSeen: Bool, anotherSheetShowing: Bool) -> Decision {
        if hasSeen { return .done }
        // Downloaded already: the card has nothing to say, now or after a later Remove.
        if modelInstalled { return .settle }
        guard savedVoiceIsSupertonic, !anotherSheetShowing else { return .wait }
        return .show
    }

    /// What the card says the download costs (Done when 2), from the catalog snapshot the app ships: the same number
    /// Settings › Voices shows on its Download button. nil when the snapshot has no such voice.
    public static func downloadByteCount(catalogSnapshot: Data, voiceId: String) -> Int? {
        guard let catalog = try? JSONDecoder().decode(VoiceModelCatalog.self, from: catalogSnapshot),
              let entry = catalog.voices.first(where: { $0.id == voiceId }) else { return nil }
        return entry.downloadByteCount
    }
}
