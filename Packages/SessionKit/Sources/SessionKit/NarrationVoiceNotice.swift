import Foundation

/// The guard's temporary voice notice (#306). Presentation only: no playback decisions or storage.
public struct NarrationVoiceNotice: Equatable, Sendable {
    public static let chapterLine = "iOS voice for this part"
    public static let bannerMessage = "Using the iOS voice for this part to keep narration clear. Your chosen voice returns after it."

    public private(set) var chapterLine: String?
    private var announcedItemIds: Set<String> = []

    public init() {}

    /// Returns a banner at most once per item during this app run. The target comes from the
    /// chunk actually playing, never from a guard render that can be several chunks ahead.
    public mutating func update(snapshot: SessionSnapshot, replacementTargetId: String?) -> String? {
        chapterLine = nil
        guard snapshot.status == .playing, snapshot.phase == .itemPlayback,
              snapshot.targetType == TargetType.itemTextTTS.rawValue,
              let itemId = snapshot.itemId, !itemId.isEmpty,
              replacementTargetId == itemId, snapshot.targetId == replacementTargetId else { return nil }
        chapterLine = Self.chapterLine
        return announcedItemIds.insert(itemId).inserted ? Self.bannerMessage : nil
    }
}
