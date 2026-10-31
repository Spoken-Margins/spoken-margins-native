import Foundation

/// One Margin heard in place: a bit of the source before it, the Margin, then what follows (#807).
///
/// The single owner of every lead-in. "Play this moment", a friend's cut and Listen Back all ask it the same
/// question: where does this moment's lead-in start, and what plays if the source isn't on the phone? The
/// lengths for each use sit side by side in `rule(for:)`.
///
/// A pure value: it plays nothing and keeps no state between moments. `MarginMomentConductor` and the
/// renderers do the playing.
public struct ListeningMoment: Sendable, Equatable {
    /// Why the moment is being played. Each use has one row in `rule(for:)`.
    public enum Use: String, Sendable, Equatable, CaseIterable {
        /// "Play this moment" on the listener's own Margin (#159), and Timeline jumps to a shared one (#158).
        case playThisMoment
        /// A moment in a cut a friend sent (docs/design/sharing-with-a-friend.md, 3.1).
        case friendsCut
        /// One Margin in a Listen Back episode (docs/design/getting-back-to-notes.md, 3.5).
        case listenBack
        /// Each shared Margin the listener hasn't heard, one after another (#474). Twenty seconds, the owner's call
        /// on #3059: ten gave no context for an episode the listener hadn't heard, and a minute would be too slow to skim.
        case reviewNewMargins
    }

    /// What plays after the Margin.
    public enum CarryOnRule: Sendable, Equatable {
        /// The source keeps playing until the listener stops it.
        case sourceContinues
        /// A short stretch of the source, then the moment ends.
        case fixed(ms: Int, fadesOut: Bool)
        /// The moment ends with the Margin.
        case none
    }

    /// What stands in for the lead-in when the source isn't on the phone.
    public enum Fallback: Sendable, Hashable {
        /// Play the lead-in from the stream. Media only.
        case stream
        /// Read aloud the context text saved with the Margin (the last sentence heard before it).
        case readContextText
        /// Read aloud the quote a shared packet carries from just before the Margin.
        case readPacketQuote
    }

    /// One use's lead-in, carry-on and fallbacks.
    public struct Rule: Sendable, Equatable {
        /// For media. Text sources lead in from the start of the sentence before the Margin's sentence instead.
        public let leadInMs: Int
        public let carryOn: CarryOnRule
        /// Tried in order when the source isn't on the phone. When none is offered, the lead-in is skipped.
        public let fallbacks: [Fallback]
    }

    /// The table. Every lead-in and carry-on length in the app is defined here.
    public static func rule(for use: Use) -> Rule {
        switch use {
        case .playThisMoment:
            // The owner's call on #1577 (option C): keep thirty seconds of run-up, and show the countdown.
            Rule(leadInMs: 30_000, carryOn: .sourceContinues, fallbacks: [.stream])
        case .friendsCut:
            Rule(leadInMs: 20_000, carryOn: .fixed(ms: 3_000, fadesOut: true), fallbacks: [.stream, .readPacketQuote])
        case .listenBack:
            // No carry-on: the Listen Back planner puts its own half-second gap before the next Margin.
            Rule(leadInMs: 8_000, carryOn: .none, fallbacks: [.readContextText])
        case .reviewNewMargins:
            // The source carries on from the Margin only until the next lead-in starts; the review owns that hop.
            Rule(leadInMs: 20_000, carryOn: .sourceContinues, fallbacks: [.stream])
        }
    }

    /// The Margin a moment is built around, at its position in the source's unit.
    public struct Margin: Sendable, Equatable {
        public let id: String
        /// Milliseconds for media, characters for text.
        public let position: Int

        public init(id: String, position: Int) {
            self.id = id
            self.position = max(0, position)
        }
    }

    /// What the source offers for this moment.
    public struct Source: Sendable, Equatable {
        public enum Timeline: Sendable, Equatable {
            /// Audio or video, in milliseconds. `durationMs` is nil when the length isn't known.
            case media(durationMs: Int?)
            /// An article, PDF or pasted text, in characters, with where each sentence starts.
            /// An empty list means the text is one sentence.
            case text(sentenceStarts: [Int])
        }

        public var timeline: Timeline
        /// The source itself is on the phone (downloaded audio, or the text).
        public var isOnPhone: Bool
        public var canStream: Bool
        public var hasContextText: Bool
        public var hasPacketQuote: Bool

        public init(
            timeline: Timeline,
            isOnPhone: Bool = true,
            canStream: Bool = false,
            hasContextText: Bool = false,
            hasPacketQuote: Bool = false
        ) {
            self.timeline = timeline
            self.isOnPhone = isOnPhone
            self.canStream = canStream
            self.hasContextText = hasContextText
            self.hasPacketQuote = hasPacketQuote
        }

        public static func media(
            durationMs: Int? = nil,
            isOnPhone: Bool = true,
            canStream: Bool = false,
            hasContextText: Bool = false,
            hasPacketQuote: Bool = false
        ) -> Source {
            Source(
                timeline: .media(durationMs: durationMs), isOnPhone: isOnPhone, canStream: canStream,
                hasContextText: hasContextText, hasPacketQuote: hasPacketQuote
            )
        }

        public static func text(
            sentenceStarts: [Int],
            isOnPhone: Bool = true,
            hasContextText: Bool = false,
            hasPacketQuote: Bool = false
        ) -> Source {
            Source(
                timeline: .text(sentenceStarts: sentenceStarts), isOnPhone: isOnPhone,
                hasContextText: hasContextText, hasPacketQuote: hasPacketQuote
            )
        }

        fileprivate var offers: Set<Fallback> {
            var offers: Set<Fallback> = []
            if canStream, case .media = timeline { offers.insert(.stream) }
            if hasContextText { offers.insert(.readContextText) }
            if hasPacketQuote { offers.insert(.readPacketQuote) }
            return offers
        }
    }

    /// A stretch of the source, `start` inclusive to `end` exclusive, in the source's unit.
    public struct Span: Sendable, Equatable {
        public let start: Int
        public let end: Int
    }

    public enum LeadIn: Sendable, Equatable {
        /// Play this stretch from the copy on the phone.
        case onPhone(Span)
        /// Play this stretch from the stream.
        case stream(Span)
        case readContextText
        case readPacketQuote
        /// Nothing to lead in with; go straight to the Margin.
        case skip

        /// The stretch of source to play, when the lead-in is source audio or text.
        public var span: Span? {
            switch self {
            case let .onPhone(span), let .stream(span): span
            case .readContextText, .readPacketQuote, .skip: nil
            }
        }
    }

    public enum CarryOn: Sendable, Equatable {
        case sourceContinues
        case play(Span, fadesOut: Bool)
        case none
    }

    /// Why the lead-in is shorter than the use asks for.
    public enum LeadInClamp: Sendable, Equatable {
        /// It reached the start of the source, or the Margin is in the text's first sentence.
        case sourceStart
        /// It reached the previous Margin in the same plan, so it doesn't replay that Margin's lead-in.
        case previousMargin(String)
    }

    public let use: Use
    public let margin: Margin
    public let leadIn: LeadIn
    public let carryOn: CarryOn
    /// Set when the lead-in's stretch didn't fit. Nil when it fit, or when a fallback stands in for it.
    public let leadInClamp: LeadInClamp?

    public var isLeadInClamped: Bool { leadInClamp != nil }

    /// Where playback of the source starts: the lead-in's start, else the Margin.
    public var sourceStartPosition: Int { leadIn.span?.start ?? margin.position }

    /// - Parameters:
    ///   - previousMargin: the Margin before this one in the same plan and source; the lead-in never starts before it.
    ///   - leadInMs: overrides the use's media lead-in, for a lead-in the sender trimmed. Ignored for text.
    public init(
        use: Use,
        margin: Margin,
        source: Source,
        previousMargin: Margin? = nil,
        leadInMs: Int? = nil
    ) {
        let rule = Self.rule(for: use)
        self.use = use
        self.margin = margin

        // Where the lead-in would start with nothing in the way, and whether the source itself cut it short.
        let wanted: Int
        var clamp: LeadInClamp?
        switch source.timeline {
        case .media:
            let length = max(0, leadInMs ?? rule.leadInMs)
            wanted = max(0, margin.position - length)
            if margin.position - length < 0 { clamp = .sourceStart }
        case let .text(sentenceStarts):
            let started = Set(sentenceStarts.filter { $0 <= margin.position }).sorted()
            if started.count >= 2 {
                wanted = started[started.count - 2]
            } else {
                wanted = max(0, started.first ?? 0)
                clamp = .sourceStart
            }
        }
        var start = wanted
        if let previousMargin, previousMargin.position <= margin.position, previousMargin.position > wanted {
            start = previousMargin.position
            clamp = .previousMargin(previousMargin.id)
        }
        let span = Span(start: start, end: margin.position)

        let offers = source.offers
        if source.isOnPhone {
            leadIn = .onPhone(span)
        } else {
            switch rule.fallbacks.first(where: { offers.contains($0) }) {
            case .stream: leadIn = .stream(span)
            case .readContextText: leadIn = .readContextText
            case .readPacketQuote: leadIn = .readPacketQuote
            case nil: leadIn = .skip
            }
        }
        leadInClamp = leadIn.span == nil ? nil : clamp

        // The carry-on comes from wherever the source is playing; a read-aloud or skipped lead-in has none.
        guard leadIn.span != nil else {
            carryOn = .none
            return
        }
        switch (rule.carryOn, source.timeline) {
        case (.sourceContinues, _):
            carryOn = .sourceContinues
        case let (.fixed(ms, fadesOut), .media(durationMs)):
            var end = margin.position + max(0, ms)
            if let durationMs { end = min(end, durationMs) }
            carryOn = end > margin.position ? .play(Span(start: margin.position, end: end), fadesOut: fadesOut) : .none
        case (.fixed, .text):
            // A carry-on length in seconds has no meaning for text.
            carryOn = .none
        case (.none, _):
            carryOn = .none
        }
    }

    /// Moments for several Margins in one source, in playback order. Each lead-in stops at the Margin
    /// before it, so two close Margins don't replay each other's lead-in.
    public static func plan(use: Use, margins: [Margin], source: Source) -> [ListeningMoment] {
        let ordered = margins.sorted { lhs, rhs in
            lhs.position == rhs.position ? lhs.id < rhs.id : lhs.position < rhs.position
        }
        return ordered.indices.map { index in
            ListeningMoment(
                use: use, margin: ordered[index], source: source,
                previousMargin: index > 0 ? ordered[index - 1] : nil
            )
        }
    }
}
