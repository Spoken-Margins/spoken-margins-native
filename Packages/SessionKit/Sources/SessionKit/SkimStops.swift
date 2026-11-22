import Foundation

/// A place Skim can go: a chapter start or a Margin (#182, #458).
public struct SkimStop: Sendable, Equatable {
    public enum Kind: Int, Sendable, Equatable, Comparable {
        // A chapter sorts before a Margin at the same position.
        case chapter = 0
        case margin = 1

        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let kind: Kind
    public let id: String
    /// In the item's playback unit: milliseconds for media, characters for spoken text.
    public let position: Int
    /// A friend's Margin that is never spoken (`SharedMarginAudio.canOffer` is false): Skim goes to its place and
    /// plays on, with no lead-in and no voice, as it does for a chapter (#4934). Its `kind` stays `.margin`, so it still
    /// beats the scene summary in `SkimStopRouting.choose`.
    public let isSilent: Bool

    public init(kind: Kind, id: String, position: Int, isSilent: Bool = false) {
        self.kind = kind
        self.id = id
        self.position = max(0, position)
        self.isSilent = isSilent
    }

    public static func chapter(_ chapter: Chapter) -> SkimStop {
        SkimStop(kind: .chapter, id: chapter.id, position: chapter.startChar)
    }

    public static func chapter(_ chapter: MediaTimelineChapter) -> SkimStop {
        SkimStop(kind: .chapter, id: chapter.id, position: chapter.startMs)
    }

    /// The listener's own Margin, or nil when it has no position in `unit`. A moved Margin with no saved place has
    /// none: its zeros are not a stop (#4233).
    public static func margin(_ margin: Interjection, unit: SkimStops.PositionUnit) -> SkimStop? {
        guard margin.hasPlace else { return nil }
        let position: Int?
        switch unit {
        case .milliseconds: position = margin.anchor.mediaTimeMs
        case .characters: position = margin.anchor.startChar
        }
        guard let position, position >= 0 else { return nil }
        return SkimStop(kind: .margin, id: margin.id, position: position)
    }

    /// A shared Margin at the best position the listener has (`SharedMarginPlaybackPosition`), or nil.
    public static func margin(_ margin: ImportedCommentaryInterjection, unit: SkimStops.PositionUnit) -> SkimStop? {
        let position: Int?
        switch unit {
        case .milliseconds: position = SharedMarginPlaybackPosition(margin)?.mediaTimeMs
        case .characters: position = margin.resolution.isAmbiguous ? nil : margin.resolution.localStartChar
        }
        guard let position, position >= 0 else { return nil }
        return SkimStop(kind: .margin, id: margin.id, position: position)
    }

    /// A friend's Margin that is never spoken, at the same place `margin(_:unit:)` gives it, or nil with none (#4934).
    public static func silentMargin(_ margin: ImportedCommentaryInterjection, unit: SkimStops.PositionUnit) -> SkimStop? {
        Self.margin(margin, unit: unit).map { SkimStop(kind: .margin, id: $0.id, position: $0.position, isSilent: true) }
    }
}

/// Where Skim goes next or back to, and where a Margin's lead-in starts (#458).
///
/// One answer for the Skim control, its label and the playback bar. Pure: the app passes the
/// playhead and, after a Skim, the stop it went to.
public struct SkimStops: Sendable, Equatable {
    public static let minimumLeadInMs = 30_000
    public static let maximumLeadInMs = 120_000

    public enum PositionUnit: Sendable, Equatable {
        case milliseconds
        /// Spoken text, where positions are characters; converts the lead-in's length.
        case characters(perSecond: Double)

        /// `ms` of source time in this unit, with no clamp: the same conversion as `SkimStops.leadInLength(ms:)`
        /// without its 30 s to 2 min limits, for a window shorter than a lead-in (#4934).
        public func positions(forMs ms: Int) -> Int {
            switch self {
            case .milliseconds: return ms
            case .characters(let perSecond):
                let rate = perSecond.isFinite ? min(max(0, perSecond), 1_000_000) : 0
                return Int((Double(ms) / 1_000 * rate).rounded())
            }
        }
    }

    public enum LeadInClamp: Sendable, Equatable {
        case itemStart
        case previousStop(SkimStop)
    }

    public struct Target: Sendable, Equatable {
        public let stop: SkimStop
        /// Where a Margin's lead-in starts. Nil for a chapter, or for a second press during the
        /// lead-in, which goes straight to the Margin.
        public let leadInStart: Int?
        /// Set when the full lead-in didn't fit before the item's start or the previous stop.
        public let leadInClamp: LeadInClamp?

        /// Where playback should start.
        public var startPosition: Int { leadInStart ?? stop.position }
        public var isLeadInClamped: Bool { leadInClamp != nil }
    }

    /// In playback order: position, then chapter before Margin, then id.
    public let stops: [SkimStop]
    public let unit: PositionUnit

    public init(chapters: [SkimStop], margins: [SkimStop], unit: PositionUnit = .milliseconds) {
        self.unit = unit
        let sorted = (chapters + margins).sorted { lhs, rhs in
            if lhs.position != rhs.position { return lhs.position < rhs.position }
            if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            return lhs.id < rhs.id
        }
        // A stop listed twice (the same chapter, or one Margin passed as own and shared) is visited
        // once, at its earliest position; a repeat would make "next" return it forever.
        var seen = Set<String>()
        stops = sorted.filter { seen.insert("\($0.kind.rawValue):\($0.id)").inserted }
    }

    /// The next stop after the playhead. A stop at the playhead itself is not next, unless it
    /// comes after `current` (the stop the last Skim went to) at the same position.
    public func next(playhead: Int, current: SkimStop? = nil, leadInMs: Int = minimumLeadInMs) -> Target? {
        let index: Int?
        if let currentIndex = anchoredIndex(of: current, playhead: playhead, leadInMs: leadInMs, untilNextPosition: true) {
            if playhead < stops[currentIndex].position {
                // A second press during the lead-in goes straight to the Margin.
                return Target(stop: stops[currentIndex], leadInStart: nil, leadInClamp: nil)
            }
            index = currentIndex + 1
        } else {
            index = stops.firstIndex { $0.position > playhead }
        }
        guard let index, stops.indices.contains(index) else { return nil }
        return target(at: index, leadInMs: leadInMs)
    }

    /// The last stop before the playhead, or before `current` when the playhead is at it or in its lead-in.
    public func previous(playhead: Int, current: SkimStop? = nil, leadInMs: Int = minimumLeadInMs) -> Target? {
        let index: Int?
        if let currentIndex = anchoredIndex(of: current, playhead: playhead, leadInMs: leadInMs, untilNextPosition: false) {
            index = currentIndex - 1
        } else {
            index = stops.lastIndex { $0.position < playhead }
        }
        guard let index, stops.indices.contains(index) else { return nil }
        return target(at: index, leadInMs: leadInMs)
    }

    /// Lead-in length in the item's unit, after clamping the requested time to 30 s through 2 min.
    public func leadInLength(ms: Int) -> Int {
        unit.positions(forMs: min(max(ms, Self.minimumLeadInMs), Self.maximumLeadInMs))
    }

    // MARK: Private

    /// `current`'s index when the playhead is in its lead-in or at it, else nil. Going forward it
    /// stays current while playback continues past it, until the next position with a stop, so a
    /// stop sharing its position is still visited.
    private func anchoredIndex(of current: SkimStop?, playhead: Int, leadInMs: Int, untilNextPosition: Bool) -> Int? {
        guard let current, let index = stops.firstIndex(of: current) else { return nil }
        guard playhead >= target(at: index, leadInMs: leadInMs).startPosition else { return nil }
        guard untilNextPosition else { return playhead <= current.position ? index : nil }
        guard let following = stops[index...].first(where: { $0.position > current.position }) else { return index }
        return playhead < following.position ? index : nil
    }

    /// The furthest back a lead-in for `stops[index]` may start: the previous stop, else the item's start.
    private func lowerBound(before index: Int) -> (position: Int, clamp: LeadInClamp) {
        index > 0 ? (stops[index - 1].position, .previousStop(stops[index - 1])) : (0, .itemStart)
    }

    private func target(at index: Int, leadInMs: Int) -> Target {
        let stop = stops[index]
        // A chapter, or a Margin that is never spoken, has no lead-in: there is no voice for it to lead into (#4934).
        guard stop.kind == .margin, !stop.isSilent else { return Target(stop: stop, leadInStart: nil, leadInClamp: nil) }
        let wanted = stop.position - leadInLength(ms: leadInMs)
        let bound = lowerBound(before: index)
        let start = max(wanted, bound.position)
        return Target(stop: stop, leadInStart: start, leadInClamp: wanted < bound.position ? bound.clamp : nil)
    }
}
