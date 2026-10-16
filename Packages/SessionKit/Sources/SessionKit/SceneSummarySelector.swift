import Foundation

/// One Listening Map scene on the recipient's clock, with the summary the podcast Now view may show (#1629).
public struct SceneSummarySpan: Equatable, Sendable {
    public let sceneId: String
    public let startMs: Int
    /// Where the scene ends; nil means it runs until the next scene starts, or to the end of the episode.
    public let endMs: Int?
    /// The trimmed summary, or nil when the scene has none worth showing.
    public let summary: String?

    public init(sceneId: String, startMs: Int, endMs: Int?, summary: String?) {
        self.sceneId = sceneId
        self.startMs = startMs
        self.endMs = endMs
        self.summary = summary
    }
}

/// Which scene summary belongs to a playhead position on the podcast Now view (#1629).
///
/// The scene is chosen by position on the listener's clock, never by matching the publisher chapter title. A
/// scene covers its start up to the next scene's start (or its own end, if that comes first). A position before
/// the first scene, in a gap after a scene's end, or inside a scene with no summary yields nil, so Now never
/// keeps showing the summary of a scene that has already passed.
public enum SceneSummarySelector {
    public static func summary(at positionMs: Int, in spans: [SceneSummarySpan]) -> String? {
        let ordered = spans.sorted { $0.startMs < $1.startMs }
        guard let index = ordered.lastIndex(where: { $0.startMs <= positionMs }) else { return nil }
        let span = ordered[index]
        if let endMs = span.endMs, positionMs >= endMs { return nil }
        return span.summary
    }
}
