import AVFoundation
import MediaPlayer
import SessionKit
import SessionKitAudio

/// Temporarily owns system transport while the separate received-Margin player
/// is active. The source adapter must relinquish its handlers before install.
@MainActor
final class ImportedMarginRemoteControls {
    private static var metadataOwner: UUID?
    private let registrations = ImportedMarginRemoteRegistrations()
    private var targets: [(MPRemoteCommand, Any)] {
        get { registrations.targets }
        set { registrations.targets = newValue }
    }
    private var observers: [NSObjectProtocol] {
        get { registrations.observers }
        set { registrations.observers = newValue }
    }

    func install(handler: @escaping @MainActor (CompactControlCommand) -> Void) {
        end()
        Self.metadataOwner = registrations.id
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
        Self.metadataOwner = registrations.id
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: "Shared Margin",
            MPMediaItemPropertyArtist: sender,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyIsLiveStream: false
        ]
        if elapsed.isFinite { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, elapsed) }
        if duration.isFinite, duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        NowPlayingInfoOwnership.shared.write(info, as: .sharedMargin)
    }

    func end() {
        guard !targets.isEmpty || !observers.isEmpty else { return }
        for (command, target) in targets { command.removeTarget(target) }
        targets.removeAll()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        Self.releaseMetadata(owner: registrations.id)
    }

    fileprivate static func releaseMetadata(owner: UUID) {
        guard metadataOwner == owner else { return }
        metadataOwner = nil
        NowPlayingInfoOwnership.shared.clear(as: .sharedMargin)
    }
}

/// Avoid Swift's isolated-deinit back-deployment path on older iOS runtimes.
/// Normal transport teardown still calls end() synchronously. The fallback
/// removes only this owner's registrations, never a newer player's metadata.
private final class ImportedMarginRemoteRegistrations: @unchecked Sendable {
    let id = UUID()
    var targets: [(MPRemoteCommand, Any)] = []
    var observers: [NSObjectProtocol] = []

    deinit {
        let owner = id
        let targets = targets
        let observers = observers
        guard !targets.isEmpty || !observers.isEmpty else { return }
        DispatchQueue.main.async {
            for (command, target) in targets { command.removeTarget(target) }
            observers.forEach(NotificationCenter.default.removeObserver)
            ImportedMarginRemoteControls.releaseMetadata(owner: owner)
        }
    }
}
