import Foundation

/// The playback bar's chapters and Margin marks (#428).
///
/// The track splits into one segment per chapter, with the current chapter's segment drawn slightly thicker.
/// Margins ride above the track as small diamonds; marks too close to tell apart on screen merge into one stack.
/// Positions are in the bar's own units (seconds for media, characters for text), so the same rules serve
/// podcasts and text sources. The view only draws what this returns.
public enum PlaybackBarLayout {
    /// Above this many chapters the gaps would eat the track, so chapter boundaries show as ticks instead.
    public static let maxGappedChapters = 20
    /// Marks whose on-screen distance from a stack's front mark is at most this many points join that stack.
    public static let crowdingDistance: Double = 6
    /// A stack of up to this many Margins shows each one as its own layer.
    public static let maxRealLayers = 5
    /// A larger stack shows this many ghost layers behind a front diamond carrying the count.
    public static let ghostLayerCount = 3

    public enum Boundary: Sendable, Equatable {
        /// One segment: nothing to divide.
        case none
        /// Small gaps between chapter segments.
        case gaps
        /// A continuous track with a tick at each chapter boundary.
        case ticks
    }

    /// One stretch of the track, as fractions of the whole bar.
    public struct Segment: Sendable, Equatable {
        public let start: Double
        public let end: Double
        public let isCurrent: Bool

        public init(start: Double, end: Double, isCurrent: Bool) {
            self.start = start
            self.end = end
            self.isCurrent = isCurrent
        }
    }

    public struct Track: Sendable, Equatable {
        public let segments: [Segment]
        public let boundary: Boundary

        public init(segments: [Segment], boundary: Boundary) {
            self.segments = segments
            self.boundary = boundary
        }
    }

    public enum MarkKind: Sendable, Equatable {
        /// The listener's own Margin: a solid diamond.
        case own
        /// A Margin shared with the listener: a hollow diamond.
        case shared
    }

    public struct Mark: Sendable, Equatable {
        public let id: String
        public let position: Double
        public let kind: MarkKind

        public init(id: String, position: Double, kind: MarkKind) {
            self.id = id
            self.position = position
            self.kind = kind
        }
    }

    /// Marks that share one spot on the bar. `members` is in bar order; the first is the front diamond.
    public struct Stack: Sendable, Equatable {
        /// The front diamond's distance from the track's leading edge, in points.
        public let x: Double
        public let members: [Mark]

        init(x: Double, members: [Mark]) {
            precondition(!members.isEmpty, "a stack holds at least one Margin")
            self.x = x
            self.members = members
        }

        public var front: Mark { members[0] }

        /// The diamonds drawn as real layers, front first. A crowded stack shows only its front diamond.
        public var layers: [MarkKind] {
            members.count > PlaybackBarLayout.maxRealLayers ? [front.kind] : members.map(\.kind)
        }

        /// Empty layers drawn behind a crowded stack's front diamond.
        public var ghostLayers: Int {
            members.count > PlaybackBarLayout.maxRealLayers ? PlaybackBarLayout.ghostLayerCount : 0
        }

        /// The number shown inside the front diamond, only when the layers can't show every Margin.
        public var countLabel: String? {
            members.count > PlaybackBarLayout.maxRealLayers ? "\(members.count)" : nil
        }

        /// What VoiceOver reads, given the stack's position already formatted (for example "9:22" or "40%").
        public func accessibilityLabel(at positionText: String) -> String {
            guard members.count > 1 else {
                return front.kind == .own ? "Your Margin at \(positionText)" : "Shared Margin at \(positionText)"
            }
            let shared = members.filter { $0.kind == .shared }.count
            let base = "\(members.count) Margins at \(positionText)"
            switch shared {
            case 0: return base
            case members.count: return "\(base), all shared"
            default: return "\(base), \(shared) shared"
            }
        }
    }

    /// Splits a bar of `length` at each chapter start. `position` marks the current chapter.
    ///
    /// Starts outside the bar and repeats are dropped. A stretch before the first chapter becomes its own segment.
    public static func track(chapterStarts: [Double], length: Double, position: Double?) -> Track {
        guard length.isFinite, length > 0 else { return Track(segments: [], boundary: .none) }
        var starts = Set(chapterStarts.filter { $0.isFinite && $0 > 0 && $0 < length }).sorted()
        starts.insert(0, at: 0)
        guard starts.count > 1 else {
            return Track(segments: [Segment(start: 0, end: 1, isCurrent: false)], boundary: .none)
        }
        let current = position.flatMap { position in
            position.isFinite ? starts.lastIndex { $0 <= max(0, position) } : nil
        }
        let segments = starts.indices.map { index in
            let end = index + 1 < starts.count ? starts[index + 1] : length
            return Segment(start: starts[index] / length, end: end / length, isCurrent: index == current)
        }
        return Track(segments: segments, boundary: segments.count > maxGappedChapters ? .ticks : .gaps)
    }

    /// Places Margin marks on a track `width` points wide and merges marks too close to tell apart.
    ///
    /// A mark joins the current stack when it is within `crowdingDistance` of that stack's front mark, so one stack
    /// never spreads further than that along the bar. Marks with no usable position are left out.
    public static func stacks(marks: [Mark], length: Double, width: Double) -> [Stack] {
        guard length.isFinite, length > 0, width.isFinite, width > 0 else { return [] }
        func x(_ mark: Mark) -> Double {
            let clamped = min(max(mark.position, 0), length)
            return clamped / length * width
        }
        let placed = marks
            .filter { $0.position.isFinite }
            .sorted { x($0) == x($1) ? $0.id < $1.id : x($0) < x($1) }
        var stacks: [Stack] = []
        for mark in placed {
            let markX = x(mark)
            if let last = stacks.last, markX - last.x <= crowdingDistance {
                stacks[stacks.count - 1] = Stack(x: last.x, members: last.members + [mark])
            } else {
                stacks.append(Stack(x: markX, members: [mark]))
            }
        }
        return stacks
    }
}

extension PlaybackBarLayout.Mark {
    /// The listener's own Margin on a podcast bar measured in seconds. Uses the recorded time, else the rough
    /// percent, as the Timeline does. Margins on a summary or assistant turn aren't on the source's bar.
    public static func media(_ interjection: Interjection, durationSeconds: Double) -> Self? {
        guard interjection.targetType == .item else { return nil }
        let seconds = interjection.anchor.mediaTimeMs.map { Double(max(0, $0)) / 1_000 }
            ?? Double(interjection.roughPercent) / 100 * durationSeconds
        return Self(id: interjection.id, position: seconds, kind: .own)
    }

    /// A shared Margin on a podcast bar measured in seconds, where the Timeline lists it: the time matched in the
    /// listener's copy, else the sender's rough percent of this copy. A Margin with neither has no honest place on
    /// the bar (the Timeline lists it last only to sort it).
    public static func media(_ interjection: ImportedCommentaryInterjection, durationSeconds: Double) -> Self? {
        let seconds: Double
        if let local = interjection.resolution.localMediaTimeMs {
            seconds = Double(max(0, local)) / 1_000
        } else if let percent = interjection.anchorEvidence.roughPercent {
            seconds = Double(percent) / 100 * durationSeconds
        } else {
            return nil
        }
        return Self(id: interjection.id, position: seconds, kind: .shared)
    }

    /// The listener's own Margin on a text bar measured in characters.
    public static func text(_ interjection: Interjection) -> Self? {
        guard interjection.targetType == .item else { return nil }
        return Self(id: interjection.id, position: Double(max(0, interjection.anchor.startChar)), kind: .own)
    }

    /// A shared Margin on a text bar measured in characters, where the Timeline lists it: the sender's rough percent.
    public static func text(_ interjection: ImportedCommentaryInterjection, textLength: Int) -> Self? {
        guard let percent = interjection.anchorEvidence.roughPercent else { return nil }
        return Self(id: interjection.id, position: Double(percent) / 100 * Double(textLength), kind: .shared)
    }
}
