import Foundation

/// How a Skim press chooses between the stop list (chapters and Margins, #458) and today's scene summary, and what a
/// press means while a Margin moment is already running (#460).
///
/// Pure: the app passes the playhead, the stop list and the summary plan's destination, and carries out the answer.
/// Nothing here holds playback state; the running Margin moment (`MarginMomentSequence`) is the only memory, so a
/// second press during a lead-in is "play it now" without Skim keeping a flag of its own.
public enum SkimStopRouting {
    /// What one press does.
    public enum Choice: Equatable, Sendable {
        /// Today's behavior: play the scene summary, then seek to the scene.
        case summary
        /// Go to this stop: seek straight to a chapter, or start a Margin's lead-in.
        case stop(SkimStops.Target)
        /// Nowhere to go from here.
        case unavailable

        /// The place the control's title and the Live Activity show: a chapter's start, or the Margin itself. The
        /// summary's own destination when it handles the press.
        public func destination(summaryDestination: Int?) -> Int? {
            switch self {
            case .summary: return summaryDestination
            case .stop(let target): return target.stop.position
            case .unavailable: return nil
            }
        }
    }

    /// - Parameters:
    ///   - stop: the next (or previous) chapter or Margin from `SkimStops`, nil when there is none.
    ///   - summaryDestination: where the scene summary's Skim would land from here, nil when it has no plan. In the
    ///     same unit as the stops.
    ///
    /// A Margin that comes before the summary's landing wins, so Skim never plays past a Margin; a chapter yields to
    /// the summary, which already ends at a scene start, so nothing that works today disappears (#460, Done when 6).
    public static func choose(direction: SkimDirection, stop: SkimStops.Target?, summaryDestination: Int?) -> Choice {
        guard let stop else { return summaryDestination == nil ? .unavailable : .summary }
        guard let summaryDestination else { return .stop(stop) }
        guard stop.stop.kind == .margin else { return .summary }
        // Where the listener lands: the lead-in start for a first press, the Margin itself for a second.
        let lands = stop.startPosition
        switch direction {
        case .forward: return lands <= summaryDestination ? .stop(stop) : .summary
        case .backward: return lands >= summaryDestination ? .stop(stop) : .summary
        }
    }

    /// A Margin moment that is already running, from the conductor's phase and where the source is.
    public enum MomentState: Equatable, Sendable {
        case none
        /// The source plays up to the Margin.
        case leadIn
        /// The Margin's voice has the floor.
        case voice
        /// A lead-in the listener has moved away from (a scrub or a chapter jump): it is over, not waiting on a press.
        case staleLeadIn

        /// - Parameter positionMs: the source's place in the moment's own clock (`MarginMomentSequence` counts media
        ///   milliseconds, or narration milliseconds for read-aloud text), nil when not known.
        public init(_ moment: MarginMomentSequence?, positionMs: Int?) {
            guard let moment else { self = .none; return }
            switch moment.phase {
            case .leadIn:
                // The seek to the lead-in's start can land a little short of it.
                let waiting = positionMs.map { $0 >= moment.startMediaTimeMs - Self.seekToleranceMs && $0 <= moment.target.mediaTimeMs } ?? true
                self = waiting ? .leadIn : .staleLeadIn
            case .playingMargin: self = .voice
            case .listening: self = .none
            }
        }

        static let seekToleranceMs = 2_000
    }

    /// How to start a Margin stop from where the listener is (#460).
    public enum StartAction: Equatable, Sendable {
        /// The playhead is before the Margin's lead-in: seek to the lead-in and let it run.
        case leadIn
        /// The playhead is already inside the lead-in window (the Margin is less than a lead-in ahead, or the stop
        /// before it is closer than that): play the Margin now. A forward press never seeks backwards, and never
        /// replays the Margin before it.
        case playNow
    }

    public static func startAction(playhead: Int, target: SkimStops.Target) -> StartAction {
        playhead >= target.startPosition && playhead < target.stop.position ? .playNow : .leadIn
    }

    /// What a press does about a running moment before it looks for a stop.
    public enum MomentPress: Equatable, Sendable {
        /// No moment is waiting on this press: look for the next stop.
        case navigate
        /// A second press during the lead-in: play the Margin now.
        case playMarginNow
        /// Forward during a Margin's voice: end the voice, and the source carries on.
        case skipVoice
        /// Back during a lead-in or a voice: end the moment, then go to the previous stop.
        case endMomentThenNavigate
    }

    public static func press(direction: SkimDirection, moment: MomentState) -> MomentPress {
        switch (direction, moment) {
        case (_, .none): return .navigate
        case (_, .staleLeadIn): return .endMomentThenNavigate
        case (.forward, .leadIn): return .playMarginNow
        case (.forward, .voice): return .skipVoice
        case (.backward, _): return .endMomentThenNavigate
        }
    }

    // MARK: Building the list

    /// The stops of one item: its chapters (text by character, media by millisecond) and the Margins that can play
    /// inline. The caller passes only Margins with a voice to play.
    public static func stops(
        textChapters: [Chapter],
        mediaChapters: [MediaTimelineChapter],
        ownMargins: [Interjection],
        sharedMargins: [ImportedCommentaryInterjection],
        unit: SkimStops.PositionUnit
    ) -> SkimStops {
        let chapters: [SkimStop]
        switch unit {
        case .milliseconds: chapters = mediaChapters.map(SkimStop.chapter)
        case .characters: chapters = textChapters.map(SkimStop.chapter)
        }
        let margins = ownMargins.compactMap { SkimStop.margin($0, unit: unit) }
            + sharedMargins.compactMap { SkimStop.margin($0, unit: unit) }
        return SkimStops(chapters: chapters, margins: margins, unit: unit)
    }
}
