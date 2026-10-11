import Foundation

/// Decides when narration owes the listener a cue for a change of voice (#934). When the on-device voice hands a
/// passage to the iOS voice (the output guard of #708, or any other stand-in), one short chime plays before the
/// first stand-in passage, so the change sounds intentional. Passages that follow it in the same run get none, and
/// neither does narration that never falls back.
///
/// The cue is played outside the narration: the passage's own audio starts after the cue, so the passage's clock,
/// and the text offsets Margins anchor to, don't move by the cue's length.
public struct NarrationVoiceChangeCue: Equatable, Sendable {
    /// The cue is the start chime; the passage waits for it plus a short gap.
    public static let leadIn: TimeInterval = PlaybackStartChime.notes.map(\.seconds).reduce(0, +) + 0.1

    /// Whether the passage that played last was a stand-in; nil before any passage.
    private var previousWasStandIn: Bool?

    public init() {}

    /// Call once as each passage is about to play, in playing order. Returns how long the passage must wait for the
    /// cue, or 0 when there is none.
    public mutating func leadIn(forStandIn isStandIn: Bool) -> TimeInterval {
        defer { previousWasStandIn = isStandIn }
        return isStandIn && previousWasStandIn == false ? Self.leadIn : 0
    }
}
