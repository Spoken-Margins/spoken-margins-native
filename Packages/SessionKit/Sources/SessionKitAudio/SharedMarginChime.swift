#if canImport(AVFoundation)
import AVFoundation
import Foundation
import SessionKit

/// Plays the two-note chime that announces another listener's Margin. The automatic prompt and the Margin
/// moment (#932) share it, so their voice always arrives the same way.
public enum SharedMarginChime {
    public static let defaultVolume: Float = 0.65

    /// Starts the chime. The caller keeps the returned player alive while the chime plays.
    public static func play(volume: Float = defaultVolume) throws -> AVAudioPlayer {
        let player = try AVAudioPlayer(data: SharedMarginCue.doubleChimeWAVData())
        player.volume = volume
        player.play()
        return player
    }
}
#endif
