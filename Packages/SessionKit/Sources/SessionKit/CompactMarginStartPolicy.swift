import Foundation

/// Whether a Margin started from a compact control (headphone double press, Live Activity, widget, URL) may switch the
/// audio session for recording off the main thread first (#2511).
///
/// The on-screen Add a Margin does this since #3069: on Bluetooth headphones the switch to `playAndRecord` moves them to
/// the hands-free profile, and the call waits about a second for that. Run on the main thread it freezes the screen.
/// The compact path never prepared, so the owner's headphone start still froze (2026-11-09 report). The switch can run
/// ahead only when nothing is sounding and nothing else needs the old order, so the cases below keep the order the
/// start always had.
public enum CompactMarginStartPolicy {
    /// What the start is like when the compact command arrives.
    public struct Situation: Equatable, Sendable {
        /// The app is in front. A start from the background keeps the old order: running the switch ahead from there is unchecked.
        public var appInForeground: Bool
        /// A Margin's voice (own, shared or a moment's) plays, is held for the recording, or has the transport. The
        /// hand-off to the recording pauses and holds it, which has to happen first.
        public var marginVoiceInvolved: Bool
        /// A scene summary (Skim) is playing, or a Margin already records or is being asked for twice.
        public var skimOrRecordingActive: Bool
        /// The recorder can prepare the session ahead (the watch's and tests' recorders can't).
        public var recorderCanPrepare: Bool

        public init(appInForeground: Bool, marginVoiceInvolved: Bool, skimOrRecordingActive: Bool, recorderCanPrepare: Bool) {
            self.appInForeground = appInForeground
            self.marginVoiceInvolved = marginVoiceInvolved
            self.skimOrRecordingActive = skimOrRecordingActive
            self.recorderCanPrepare = recorderCanPrepare
        }
    }

    /// True when the start should pause the source and switch the session off the main thread before the recorder starts.
    /// Whether the source is quiet after the pause is checked by the caller: speech the engine pauses itself keeps the old order.
    public static func preparesSessionAhead(_ situation: Situation) -> Bool {
        situation.appInForeground
            && situation.recorderCanPrepare
            && !situation.marginVoiceInvolved
            && !situation.skimOrRecordingActive
    }
}
