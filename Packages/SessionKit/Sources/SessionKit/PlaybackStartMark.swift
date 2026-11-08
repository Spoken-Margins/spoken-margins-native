import Foundation

/// What was sounding, or about to sound, at one moment: the listener's source session, a Margin's moment, a Skim
/// bridge, a shared Margin's voice, one of their own Margin voices (#3638).
///
/// A tap that reads off the main thread (`openItemFromTap`) takes a mark when it starts and asks the later mark
/// whether playback was started meanwhile. Asking the state, not each way of starting, is the point: a new way to
/// start playback is covered the day it exists, because it can't sound without changing one of these. Only a start
/// counts. Something ending (the item finishing, a pause, the mini player closed) or a position tick leaves a pending
/// open alone, so a tap with nothing else started still opens.
///
/// Two limits, accepted because the read is short (#3638). The mark cannot tell a listener's start from one the app
/// makes itself (the queue moving to the next item, a shared Margin playing as the source reaches it, the source
/// resuming after a Margin voice), so such a start also drops the open and the listener taps again. And it compares two
/// moments, so pausing and playing the same thing again inside one read is not seen; the open then lands as it did
/// before this check existed.
public struct PlaybackStartMark: Equatable, Sendable {
    public let sessionId: String?
    public let isActive: Bool
    public let momentId: String?
    public let skimBridgeId: String?
    public let sharedMarginId: String?
    public let ownMarginId: String?

    public init(snapshot: SessionSnapshot, momentId: String?, sharedMarginId: String?, ownMarginId: String?) {
        sessionId = snapshot.sessionId
        isActive = snapshot.status.isPlaybackActive
        self.momentId = momentId
        skimBridgeId = snapshot.skimBridgeState.map { "\($0.summaryAssetId)@\($0.destinationMediaTimeMs)" }
        self.sharedMarginId = sharedMarginId
        self.ownMarginId = ownMarginId
    }

    /// True when something is playing now that was not at `earlier`: another session, playback active that was not,
    /// or another Margin moment, Skim bridge or Margin voice.
    public func startedSince(_ earlier: PlaybackStartMark) -> Bool {
        Self.isNew(sessionId, since: earlier.sessionId)
            || (isActive && !earlier.isActive)
            || Self.isNew(momentId, since: earlier.momentId)
            || Self.isNew(skimBridgeId, since: earlier.skimBridgeId)
            || Self.isNew(sharedMarginId, since: earlier.sharedMarginId)
            || Self.isNew(ownMarginId, since: earlier.ownMarginId)
    }

    private static func isNew(_ now: String?, since before: String?) -> Bool {
        guard let now else { return false }
        return now != before
    }
}
