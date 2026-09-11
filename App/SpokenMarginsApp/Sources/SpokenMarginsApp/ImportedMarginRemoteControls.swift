import AVFoundation
import MediaPlayer
import SessionKit

/// Temporarily owns system transport while the separate received-Margin player
/// is active. The source adapter must relinquish its handlers before install.
@MainActor
final class ImportedMarginRemoteControls {
    private var targets: [(MPRemoteCommand, Any)] = []
    private var observers: [NSObjectProtocol] = []

    isolated deinit { end() }

    func install(handler: @escaping @MainActor (CompactControlCommand) -> Void) {
        end()
        let center = MPRemoteCommandCenter.shared()
        for (remote, command) in [(center.playCommand, CompactControlCommand.play),
                                  (center.pauseCommand, .pause),
                                  (center.togglePlayPauseCommand, .togglePlayPause)] {
            remote.isEnabled = true
            let target = remote.addTarget { _ in
                Task { @MainActor in handler(command) }
                return .success
            }
            targets.append((remote, target))
        }
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.changePlaybackPositionCommand.isEnabled = false
        center.changePlaybackRateCommand.isEnabled = false
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            Task { @MainActor in handler(.pause) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { notification in
            guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            Task { @MainActor in handler(.pause) }
        })
    }

    func publish(sender: String, elapsed: Double, duration: Double, rate: Double) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: "Shared Margin",
            MPMediaItemPropertyArtist: sender,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyIsLiveStream: false
        ]
        if elapsed.isFinite { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, elapsed) }
        if duration.isFinite, duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func end() {
        guard !targets.isEmpty || !observers.isEmpty else { return }
        for (command, target) in targets { command.removeTarget(target) }
        targets.removeAll()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
