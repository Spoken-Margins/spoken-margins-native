import Foundation

/// What iOS said when an audio-session interruption ended (#3180, #3032).
///
/// iOS reports the end of a call, Siri or an alarm with a set of option bits. The only bit the app reads is "audio may
/// start again". That reading used to be written out at each place that listened for the end (the AVPlayer client, the
/// Supertonic client, the Margin recorder, the Live Activity watcher), and the answer then travelled onward as a bare
/// `Bool` that each receiver could mistake for its own decision. It is parsed here once, at the edge, and the owners of
/// the decision (`SystemInterruptionResume`, `MarginCaptureResume`) and the card that follows the call
/// (`LiveActivityLifecycle`) receive this value. It records what iOS said and decides nothing: whether the source
/// resumes still depends on what the owner knows (was it playing, did the listener take over, did the route go).
public struct InterruptionEnd: Equatable, Sendable {
    /// The raw `AVAudioSession.InterruptionOptions` value from the notification. Kept so a log can show what iOS sent,
    /// including bits this build does not name.
    public let rawOptions: UInt

    /// `AVAudioSession.InterruptionOptions.shouldResume`, which SessionKit cannot import on every platform.
    static let audioMayStartBit: UInt = 1

    /// iOS says audio may start again. Unknown bits are ignored; a missing options value (`0`) says no.
    public var iosAllowsAudioToStart: Bool { rawOptions & Self.audioMayStartBit != 0 }

    public init(rawOptions: UInt) {
        self.rawOptions = rawOptions
    }

    /// The notification's `userInfo`. A missing or mistyped options entry reads as no options, as iOS sends none for
    /// an interruption that lets another app keep the audio.
    public init(userInfo: [AnyHashable: Any]?, optionsKey: String) {
        self.init(rawOptions: userInfo?[optionsKey] as? UInt ?? 0)
    }

    /// iOS said audio may start again.
    public static let audioMayStart = InterruptionEnd(rawOptions: audioMayStartBit)
    /// iOS did not say audio may start again (another app kept the audio).
    public static let audioStaysStopped = InterruptionEnd(rawOptions: 0)
}
