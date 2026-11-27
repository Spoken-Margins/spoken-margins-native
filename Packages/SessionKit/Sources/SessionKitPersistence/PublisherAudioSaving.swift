import Foundation
import SessionKit

/// What `savePublisherAudioIfItemExists` did with a found recording.
public enum PublisherAudioSaveResult: Equatable, Sendable {
    case saved(PublisherAudio)
    /// The listener removed the article while the page loaded (#810).
    case itemGone
    /// `PublisherAudioAdmission` refused the recording; nothing was saved (#4640).
    case refused(PublisherAudioRefusal)

    /// The saved record, or nil when nothing was saved.
    public var saved: PublisherAudio? {
        if case .saved(let audio) = self { return audio }
        return nil
    }

    /// The Diagnostics value for a refusal, `refused:<token>`, or nil.
    public var refusalDiagnostic: String? {
        if case .refused(let refusal) = self { return "refused:\(refusal.rawValue)" }
        return nil
    }
}

extension SQLiteSessionStore {
    /// Saves a publisher recording that a lookup found, once `PublisherAudioAdmission` admits it (#4640), unless the
    /// listener removed the article while the page loaded (#810). A record already kept for the same recording keeps
    /// its text map and status. The item check, the read of the earlier record and the save run in the caller's order,
    /// so the app runs the whole step through `StoreReader`, off the main actor (#2507). The check reads the item's
    /// summary, not its text, which can be a whole book.
    public func savePublisherAudioIfItemExists(_ found: PublisherAudio) throws -> PublisherAudioSaveResult {
        let admitted: PublisherAudio
        switch PublisherAudioAdmission.admit(found) {
        case .success(let audio): admitted = audio
        case .failure(let refusal): return .refused(refusal)
        }
        // One transaction, so a text map the mapper saves meanwhile isn't overwritten by an older read, and a
        // deletion can't leave an orphan record between the check and the save.
        return try withSessionTransaction {
            guard try loadItemSummary(id: admitted.itemId) != nil else { return .itemGone }
            let audio = admitted.keepingTextMap(of: try loadPublisherAudio(itemId: admitted.itemId))
            try savePublisherAudio(audio)
            return .saved(audio)
        }
    }
}
