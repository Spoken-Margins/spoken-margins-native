import Foundation

/// One chunk of an article's narration plan, as background preparation and the on-device player name it (#312).
/// Moved from the app with `SupertonicSpeechPlaybackClient` (#4691); no behaviour change.
public struct PreparedChunkPlan: Equatable, Sendable {
    public var index: Int
    public var startOffset: Int
    public var sourceLength: Int
    public var text: String
    /// Set on the chunks of a footnote (an aside, or a note's definition in the notes section); nil on every other
    /// chunk (#3777). Assembly leaves the definitions out of the whole audio, because the asides already read them.
    public var footnote: NarrationChunkPlanner.FootnoteTag? = nil

    public init(index: Int, startOffset: Int, sourceLength: Int, text: String, footnote: NarrationChunkPlanner.FootnoteTag? = nil) {
        self.index = index
        self.startOffset = startOffset
        self.sourceLength = sourceLength
        self.text = text
        self.footnote = footnote
    }

    /// Background preparation's plan for an article: the article plan the player's lookups use too
    /// (#312). Production and the tests both call this, so they can't drift apart. `asides` is the plan kind the
    /// preparation was created with (`FootnotePlanDecision`, or the manifest's own kind): the same text has a plain
    /// plan and, when a note can be read where it is cited, a plan with note chunks (#3777).
    public static func articlePlan(_ articleText: String, asides: Bool = false) -> [PreparedChunkPlan] {
        NarrationChunkPlanner.articlePlan(articleText, asides: asides).chunks.map {
            PreparedChunkPlan(index: $0.index, startOffset: $0.startOffset, sourceLength: $0.sourceLength, text: $0.text,
                              footnote: $0.footnote)
        }
    }
}

/// A saved chunk's audio, found by a prepared-chunk lookup.
public struct PreparedChunkLookupResult: Sendable {
    public var audioURL: URL
    public var duration: TimeInterval

    public init(audioURL: URL, duration: TimeInterval) {
        self.audioURL = audioURL
        self.duration = duration
    }
}
