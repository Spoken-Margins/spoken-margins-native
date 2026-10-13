#if canImport(AVFoundation) && os(iOS)
import AVFoundation
import SessionKit

extension InterruptionBackgroundHold.OtherAudioWatch {
    /// Reads the shared audio session for other apps' audio, and activates it before a resume (#1434).
    @MainActor
    public static var audioSession: Self {
        Self(
            probe: {
                let session = AVAudioSession.sharedInstance()
                return .init(
                    isPlaying: session.isOtherAudioPlaying,
                    secondaryShouldBeSilenced: session.secondaryAudioShouldBeSilencedHint
                )
            },
            activate: {
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                    return nil
                } catch {
                    return "\(error.localizedDescription) (\((error as NSError).code))"
                }
            }
        )
    }
}
#endif
