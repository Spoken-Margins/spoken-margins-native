import Foundation

/// The saved listening position shown while a spoken Margin is being captured.
/// All labels come from the session snapshot: browsing another item's detail must never
/// relabel the session that owns the capture (#1527).
public struct RecordingPresentationContext: Equatable, Sendable {
    public let itemTitle: String
    public let locationTitle: String
    public let progressPercent: Int
    public let startedAt: Date

    public init(snapshot: SessionSnapshot, startedAt: Date) {
        let title = snapshot.title ?? ""
        itemTitle = title.isEmpty ? "Current item" : title
        locationTitle = snapshot.chapterTitle ?? "Current listening position"
        progressPercent = snapshot.currentPlaybackProgressPercent
        self.startedAt = startedAt
    }
}
