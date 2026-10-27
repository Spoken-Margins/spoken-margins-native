import Foundation

/// The last measured render headroom, kept with what it was measured under, for `RenderAheadPolicy.resumeMark` (#2703).
///
/// The client used to keep only the last measurable chunk's headroom, from either voice and in either app state, and
/// never cleared it. A foreground chunk, rendered unpaced, could mark headroom healthy; after backgrounding, the paced
/// and budgeted rate is much slower, yet the stale value still lowered the resume mark, so the chain refilled late. A
/// reading now counts only under the same voice, the same app state and the same generation (item, seek or hand-over)
/// it was measured in; anything else reads as unknown, which keeps the plain half-window mark. Matching on read, rather
/// than clearing at each change, means no path that backgrounds the app or changes the voice or item can forget it.
public struct RenderHeadroomMemory: Sendable {
    /// What a headroom reading depends on.
    public struct Context: Equatable, Sendable {
        /// The stand-in voice rendered (or will render), not the chosen one.
        public var isStandIn: Bool
        /// The app was in the background, where inference is paced and budgeted.
        public var isInBackground: Bool
        /// The client's generation: a new item, a seek or a hand-over starts a new one.
        public var generation: UUID

        public init(isStandIn: Bool, isInBackground: Bool, generation: UUID) {
            self.isStandIn = isStandIn
            self.isInBackground = isInBackground
            self.generation = generation
        }
    }

    private var last: (headroom: Double, context: Context)?

    public init() {}

    /// A measurable chunk rendered at `headroom` under `context`.
    public mutating func record(_ headroom: Double, in context: Context) {
        last = (headroom, context)
    }

    /// The last reading if it was measured under `context`; nil otherwise.
    public func headroom(in context: Context) -> Double? {
        guard let last, last.context == context else { return nil }
        return last.headroom
    }
}
